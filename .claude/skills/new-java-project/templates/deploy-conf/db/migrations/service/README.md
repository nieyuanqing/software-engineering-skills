# 数据库迁移（`<DB_NAME>` 库）

本服务的表结构变更一律写成本目录下的 `V<n>__<主题>.sql`，由 `scripts/db-migrate.sh` 现问目标库、
按版本号升序增量执行。应用侧 **Flyway 默认关闭**（`spring.flyway.enabled: ${FLYWAY_ENABLED:false}`）、
`jpa.hibernate.ddl-auto: validate` 只校验不建表——schema 只有这一条写入路径，不让"应用启动迁移"和
"脚本迁移"两套记账并存。

> 多微服务工程：每个服务一个同名子目录（`migrations/<服务>/`），各连自己 `.env` 里的库。
> `scripts/deploy.sh`、`scripts/db-migrate.sh`、`scripts/db-sql.sh` 顶部的 `SERVICES` 表要同步加。

## 〇、目录形状

```
本目录/
├── V0__baseline.sql     ← 结构基线：首次建库用，判 manual（脚本不代跑）
├── V1__….sql …          ← 此后新增的增量，从 V1 起编号
└── history/             ← 可选：rebase 后把老增量归档到这里，脚本通配不递归，归档项不参与判定
```

**空库怎么来的**（新库第一次落结构，二选一）：

1. 把已有开发库的结构导出成基线：
   `pg_dump --schema-only --no-owner --no-privileges -h 127.0.0.1 -U <DB_NAME> <DB_NAME> > V0__baseline.sql`
   然后照下面第三节给它补上 `@probe` 行（用基线里任意一张表的存在性即可）。
2. 还没有任何库：临时把 `application-dev.yml` 的 `ddl-auto` 改成 `create`（或设 `FLYWAY_ENABLED=true`
   并把结构脚本放进 `classpath:db/migration`）跑一次让 JPA 生成表 → 按 1 导出基线 → 改回 `validate`。
   基线导出后，**这条生成路径就作废**，此后结构只由本目录的 V 文件决定。

基线只用于空库 bootstrap：对已有表的库跑它会在第一个 `CREATE TABLE` 上失败，这是有意的
（基线不是增量，跑通它的前提就是"这个库还不存在"）。所以它判 `manual`，`db-migrate.sh` 永不代跑。

## 一、执行入口（增量只有两种：① 批量、② 单文件；③ 是全量重建，不是升级）

> **两层分工**：① `scripts/db-migrate.sh` 是**迁移层**——只认 `V<n>__*.sql` 与文件头 `-- @probe:`，
> 负责判「已应用／待应用／需人工」、写 `deploy-conf/db/migrate-records/<env>.md` 留痕、按版本序决定跑哪些；
> **它自己不连库**，每次问库与写库都回调 ② `scripts/db-sql.sh`（**执行层**）——取连接参数、拼 ssh、
> 起 psql 只此一处实现。读写只有一个轴：**执行层不加 `--apply` 就是只读**（数据库侧强制
> `default_transaction_read_only=on`），写必须显式 `--apply`；`-q` 只是**迁移层**的模式位。

### ① 推荐：`scripts/db-migrate.sh`（只做增量）

```bash
bash scripts/db-migrate.sh -q                                   # 只读：逐文件判定 + 差集汇总（本机 dev 库）
bash scripts/db-migrate.sh                                      # 本地 dev 增量升级（交互确认）
bash scripts/db-migrate.sh -q -s <服务> --only V0               # 只读看某一条会不会跑（差集在报告末尾单列）
bash scripts/db-migrate.sh -e test -r <user@host> -q            # 查 test 库差集（只读，读远端 .env，不需 --yes）
bash scripts/db-migrate.sh -e test -r <user@host> --yes         # 升 test 库
bash scripts/db-migrate.sh -e prod -r <user@host> --yes --confirm-prod   # prod 双确认
bash scripts/db-migrate.sh --list-services                      # 服务→迁移目录→env 文件 映射
bash scripts/db-migrate.sh -h                                   # 全部参数与判定口径
```

脚本不查任何记账表，**「这条迁移在目标库执行过没有」由本文件头部的 `-- @probe:` 探测语句现问现答**
（约定见第三节）。它按版本号升序逐文件 `psql -v ON_ERROR_STOP=1`，任一出错即中止，
**永不 DROP、永不重建、永不从备份恢复**。完整参数以 `-h` 为准。

**`-e` 决定的是"问哪个库"，不是"读哪份文件"，且脚本绝不自己连远端**：本机 `.env.test` / `.env.prod` 里的
`DB_HOST` 都是 `127.0.0.1`，那个地址指的是**被部署过去的那台机自己**。在本机照它连，连的是 dev 库——
报告与 dev 一字不差，那是假绿。所以远端只认显式 `-r`；缺 `-r` 时 `-q` 走**离线答复**（照录本地留痕的
最后一节并标明快照时刻，不连库、不写留痕），增量执行模式则在连库前直接拒绝。

**多服务工程的同号版本**：不同库可以有同号 `V<n>`（各自的基线都是 `V0`）。裸写 `--only V9` 会同时命中
多个服务并打 `WARN`（列出命中的「服务/文件」）；只跑一个服务要写 `--only <服务>/V9`。

**`-q` 全程只读，不写库、不建任何东西**：执行函数 `run_file` 还带一道运行时自我保护，一旦发现在查询模式下
被调到就立刻中止，免得将来有人改动调用顺序把只读模式变成写模式。报告收尾会把**待应用文件单独过滤出来**
成一块清单，所以脚本**没有 `--dry-run`**——两份实现给同一件事只会互相漂移。

### ② 执行层 `scripts/db-sql.sh`（跑单个文件、人工订正、`@probe: manual` 的迁移）

```bash
# 只读预检（不加 --apply 就是默认只读）
bash scripts/db-sql.sh -e test -r <user@host> -f deploy-conf/db/migrations/<服务>/check-something.sql
# 放开写、执行本目录某个 V 文件（远端必须显式 -r；SQL 经 ssh 标准输入流式执行，目标机不落文件）
bash scripts/db-sql.sh -e test -r <user@host> --apply -f deploy-conf/db/migrations/<服务>/V2__....sql
```

连接参数由脚本从**目标机**的 `src/backend/<服务>/.env`（远端为 `/opt/soft/apps/<服务>/.env`）现取，
口令只进那次进程的环境变量，**不进 shell 历史、不落盘、不回显**。
`db-migrate.sh` 判为 `manual`（永不自动跑）的文件、以及一次性数据订正，都走这里；prod 写不经本脚本代跑。

连 `db-sql.sh` 都用不上的场合（例如没有该机的 ssh 权限）才退回裸 psql，自己保证口令不进历史：

```bash
( set -a; . src/backend/<服务>/.env; set +a
  PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USERNAME" -d "$DB_NAME" \
      -v ON_ERROR_STOP=1 -f deploy-conf/db/migrations/<服务>/V2__....sql )
```

手工执行没有差集概念，**执行前自己确认目标库处在哪一版**（可用 `db-migrate.sh -q` 只读问一遍）。
不要把口令写进命令行历史里长期留存，也不要把 `.env` 的值贴进任何被跟踪文件。

### ③ `deploy.sh --target db`：**全量重建，不是增量**

```bash
bash scripts/deploy.sh --target db --remote <user@host> --yes
```

它会停服务 → **DROP 目标库** → 重建 → 从本地 `pg_dump` 恢复。用途是"把本地库整体搬到远端"，
**不能**当升级用：跑一次就把远端库里比本地新的数据冲掉。已明确执行过某条迁移的环境，
绝不要用这个方式"补迁移"。

## 二、新增迁移的规矩

1. 文件名 `V<n>__<主题>.sql`，编号接在本目录现有最大号之后，**不复用、不重排**已存在的编号
   （`migrate-records/` 与文档里大量按 `V<n>` 引用历史文件，重号会让"V7 已应用"这类记录自相矛盾；
   重编号会让已执行库里的对象与文件名对不上）。同版本多文件脚本按文件名稳定序执行并 WARN 一次，不重编号。
2. SQL 必须**幂等**（`IF NOT EXISTS` / `ADD COLUMN IF NOT EXISTS` / `ON CONFLICT DO NOTHING` /
   带 `WHERE` 的数据订正），三套环境（dev/test/prod）可直接执行同一份。
3. 头部第一行标题（`-- V7: 主题`）下面**必须紧跟 `-- @probe:` 行**，缺行的文件判「未标注」，
   `db-migrate.sh` 默认拒绝执行。写法见下一节。
4. **本目录的 `V*.sql` 入库**（`.gitignore` 里有 `!deploy-conf/db/migrations/**/*.sql` 例外）：
   结构与代码同版本演进，换机器、建新环境时先 `git pull` 再 `-q` 现问库。
   `deploy-conf/db/migrate-records/`（运行留痕）不入库——它是本机每次问答的历史，不是结构定义。

## 三、`-- @probe:` 探测行约定

写在文件头部注释里，与标题同处，随文件一起被带到任何机器——**改 DDL 时同一屏就能看到探测对不对**，
不在脚本里维护第二份"文件→状态"表（那必然漂移）。

| 写法 | 语义 | 用在什么场合 |
|---|---|---|
| `-- @probe: <单行 SELECT>` | 返回值 >0 即判「已应用」；一个文件写多条则**全部命中**才算已应用（AND） | 建表、加列、建索引、加约束等一切结构变更 |
| `-- @probe: idempotent` | 每次执行都跑（文件自带 `IF NOT EXISTS` / `NOT EXISTS` 预检，重复安全） | **不涉资金**的数据订正 |
| `-- @probe: manual` | **永不自动执行**，只在报告里显示「需人工」 | 空库基线、踢连接/改库名、批量清数据、涉资金回补 |
| 不写 | 判「未标注」，apply 拒绝（`--include-unprobed` 才跑） | 兜底：宁可漏跑也不猜 |

**一条红线**：`idempotent` 的判据不是"文件自带预检"，而是"重复跑它顶多做无用的对账"。凡会产生**资金动作**
的回补（退款、补单、给账户回充）即使重复安全，也一律判 `manual`——"每次执行"意味着一次普通增量升级就会
顺手把钱退出去。

探测语句只用**对象存在性**（`information_schema.tables` / `information_schema.columns` /
`pg_indexes` / `pg_constraint`），不要写"数据看起来跑过没有"——数据订正类走 `idempotent` 或 `manual`。
唯一例外是种子数据迁移，它的"对象"就是那行数据本身。

一条探测只占一行（脚本按整行取 SQL，不做跨行续写），长也没关系。

文件头部照这个形状写（一个文件多条探测 ⇒ AND，全部命中才判「已应用」）：

```sql
-- V2: orders 表加「渠道来源」列并建索引
-- @probe: SELECT count(*) FROM information_schema.columns WHERE table_name='orders' AND column_name='channel'
-- @probe: SELECT count(*) FROM pg_indexes WHERE tablename='orders' AND indexname='idx_orders_channel'
-- 背景：为什么加这一列、口径怎么定的（写在文件里，才随文件一起到达任何机器）
-- 幂等：ADD COLUMN IF NOT EXISTS + CREATE INDEX IF NOT EXISTS，重复执行为 0 变更。

ALTER TABLE orders ADD COLUMN IF NOT EXISTS channel varchar(32);
CREATE INDEX IF NOT EXISTS idx_orders_channel ON orders (channel);
```

## 四、跑完之后

```bash
bash scripts/db-migrate.sh -q      # 应显示「待应用 0」；仍报待应用说明探测写错了或文件没执行成功
```

报告里出现 `未标注` / `需人工` / `探测出错` 三类中的任何一条，都不算"升级完成"，
按提示补探测行或人工执行。**新工程的固定例外**：`V0__baseline.sql` 判 `manual`，会**永久**占一条
`需人工`——那是刻意的（对非空库跑它就是半应用），不是待办。所以"升级完成"的判据是
**`待应用 0` 且 `需人工` 只剩 V0 基线**；多出任何一条 `需人工` 都要单独看。
