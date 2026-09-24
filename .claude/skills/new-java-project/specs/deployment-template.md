# 部署规范（<SERVICE_NAME> 专属）

> 定位：本工程（<SERVICE_NAME>）的部署约定与操作细节。
> **主机层面、跨项目通用的规则（目录/命名约定、端口登记总表、共享 supervisord/nginx 的操作规范、
> 故障案例）都在 [共享主机部署通用规范](./deployment-common.md) 里，本文档不重复，只写
> <SERVICE_NAME> 自己的部分**。执行任何部署操作前，先确认已经读过那份通用规范。
> 适用范围：`scripts/deploy.sh`（含 `scripts/apply-ssl.sh`）、`scripts/db-sql.sh`（手工连库入口）
> 等部署脚本，`deploy-conf/` 下的部署配置，以及 `src/main/resources/db/migration/` 下的 Flyway 迁移脚本。
> 生成日期：<CREATE_DATE>

---

## 目录

1. [部署架构](#一部署架构)
2. [部署环境（dev/test/prod）](#二部署环境devtestprod)
3. [目录与端口分配](#三目录与端口分配)
4. [环境变量（.env 三套）](#四环境变量env-三套)
5. [部署流程](#五部署流程)
6. [deploy.sh 用法](#六-deploysh-用法)
7. [数据库部署约定](#七数据库部署约定)
8. [部署前检查清单](#八部署前检查清单)
9. [回滚与停止](#九回滚与停止)
10. [微服务扩展](#十微服务扩展新增第二个服务)

---

## 一、部署架构

```
用户请求
   │
   ▼
nginx（对外监听 <NGINX_PORT>，站点配置 /etc/nginx/conf.d/<SERVICE_NAME>.conf）
   │  反向代理 <API_PATH_PREFIX>；<WEB_PATH>/ 直接从磁盘提供静态资源（如有前端）
   ▼
Spring Boot 应用（127.0.0.1:<APP_PORT>，只绑定本机地址，不直接对外）
   │
   ▼
PostgreSQL <DB_PORT>（本机私有实例）
```

- 应用进程由 **supervisord** 管理（`autostart`/`autorestart`，进程异常退出后自动拉起）
- 对外访问**必须**经过 nginx，应用端口不对外暴露——这是架构约束，不是可选项。
  应用侧 `server.address` 默认 `127.0.0.1`（可由 `SERVER_ADDRESS` 覆盖），不要改成 `0.0.0.0`
- dev 环境下 supervisord 与 nginx 是主机上多个项目共用的基础设施，操作规范见
  [共享主机部署通用规范](./deployment-common.md) 第三节
- 跨域（CORS）统一在 nginx 层用 `map $http_origin` 白名单处理，后端不参与；
  访问日志里 Authorization 只记 Bearer 前 8 位（同见站点配置文件头注释）

---

## 二、部署环境（dev/test/prod）

三套环境是**三台完全独立的机器**，不是同一台机器跑三份：

| 环境 | 机器 | 域名 / 协议 | 用途 |
|---|---|---|---|
| `dev`（默认） | 与其他项目共用的主机 | 无域名，HTTP，直接用 IP+端口访问 | 日常开发验证 |
| `test` | 独立机器 | `<TEST_DOMAIN>`，HTTPS | 集成测试/验收 |
| `prod` | 独立机器 | `<PROD_DOMAIN>`，HTTPS | 生产 |

对应的 nginx 站点配置是提前生成好的静态文件（一个服务一份，多微服务共用同一份站点配置）：
- `deploy-conf/nginx/<SERVICE_NAME>.dev.conf`
- `deploy-conf/nginx/<SERVICE_NAME>.test.conf`（`server_name <TEST_DOMAIN>`）
- `deploy-conf/nginx/<SERVICE_NAME>.prod.conf`（`server_name <PROD_DOMAIN>`）

`deploy-conf/nginx/` 下除本服务这三份 `<SERVICE_NAME>.*.conf` 之外的其余内容
（`nginx.conf`、`subconf/`、`mime.types` 等）是主机级共享 nginx 基础配置，由 `/new-nginx-conf`
生成，通常整台主机只需要生成一次，不随每个服务重复生成。缺 `nginx.conf` 不影响部署：
`deploy.sh` 只同步站点配置，会跳过主配置安装并打警告。

首次在 test/prod 机器上部署：
1. 确认域名已经解析到这台机器
2. 在目标机器上执行 `bash scripts/apply-ssl.sh test`（或 `prod`）申请证书
   （80 端口需公网可达；三套站点配置里都保留了 `/.well-known/acme-challenge/` 入口）
3. 证书就位后再执行 `bash scripts/deploy.sh --target ssl --env test`（或 `prod`）

证书缺失时 `deploy.sh` 不会失败，而是**降级部署 dev（HTTP）配置并打警告**——
这个降级是为了不让一次漏签证书把整条部署链路卡死，但看到警告必须补签，
否则 test/prod 环境实际跑的是明文 HTTP。

---

## 三、目录与端口分配

按 [共享主机部署通用规范](./deployment-common.md) 第一节的目录模板：

| 用途 | 路径 |
|---|---|
| 应用部署目录（版本化 JAR + `.env`） | `/opt/soft/apps/<SERVICE_NAME>/` |
| JAR 实际文件 / 稳定入口软链 | `<SERVICE_NAME>-<版本>.jar` / `<SERVICE_NAME>.jar` |
| 应用日志 | `/data/logs/apps/<SERVICE_NAME>/supervisord.log` |
| supervisord 程序配置（部署产物，由 deploy.sh 写入） | `/etc/supervisor/conf.d/<SERVICE_NAME>.<后缀>`，后缀按目标主机 `[include] files=` 解析（apt 默认 `.conf`，本机历史上是 `.ini`） |
| nginx 站点配置（部署产物） | `/etc/nginx/conf.d/<SERVICE_NAME>.conf` |
| nginx 访问日志 | `/data/logs/nginx/<SERVICE_NAME>-access.log` |
| SSL 证书（test/prod，按域名命名） | `/etc/nginx/ssl/<域名>.pem` / `<域名>.key` |
| 前端静态资源目录（如有） | `/opt/soft/apps/<SERVICE_NAME>/web/` |
| 部署中间产物（Maven 日志、db dump） | `runtime/`（不入库） |

端口分配（dev/test/prod 三台机器上都一样）：

| 用途 | 端口 |
|---|---|
| nginx 对外反向代理 | `<NGINX_PORT>` |
| Spring Boot 应用内部监听（仅 `127.0.0.1`） | `<APP_PORT>` |
| PostgreSQL | `<DB_PORT>` |

---

## 四、环境变量（.env 三套）

每个后端服务维护三份环境变量文件，**键集必须完全一致**：

| 环境 | 文件 | 用途 |
|---|---|---|
| dev | `src/backend/<SERVICE_NAME>/.env` | 本地开发，同时是键集基准 |
| test | `src/backend/<SERVICE_NAME>/.env.test` | `deploy.sh --env test` 使用 |
| prod | `src/backend/<SERVICE_NAME>/.env.prod` | `deploy.sh --env prod` 使用 |

三份文件都被 `.gitignore` 忽略，不入库；真值只存在各自机器上。

**强制约定**

1. **新增/删除任何环境变量，三套文件必须同步改**（只改值不改键）。
   环境模板缺键 = 部署后远端缺该项配置，而且往往**静默失效**而不是启动报错——
   跨服务调用的令牌、开关类配置最容易这样丢。
2. `deploy.sh` 部署每个服务前会比对 `.env` 与 `.env.<环境>` 的键集并打警告
   （`缺少 dev .env 中的键: ...`）。看到这条警告要么补键，要么确认该项在该环境确实不需要并写明理由。
3. **敏感值按环境独立生成**：数据库口令、JWT 密钥等在 prod 必须单独生成，
   禁止复用 dev/test 的值；`application*.yml` 是被跟踪文件，里面只允许
   `${VAR:}` 形式的空默认值，不允许出现任何真值。
4. 部署时选中的文件会被覆盖到远端 `<app目录>/.env`，supervisord 启动命令加载它，
   因此远端永远只有一个 `.env`，环境差异在部署时就已决定。

**环境文件解析规则**（`deploy.sh` 的 `resolve_env_file`）：
`--env dev` → `.env`；`--env test` → `.env.test`；`--env prod` → `.env.prod`；
仅当对应环境文件**不存在**时才回退 `.env`（回退会打警告）。

部署前手工比对键集（与脚本内置检查等价，用于 CI 或提交前自查）：

```bash
for f in .env .env.test .env.prod; do
  grep -oE '^[A-Z_]+=' src/backend/<SERVICE_NAME>/$f | tr -d '=' | sort > /tmp/k_$f.txt
done
comm -3 /tmp/k_.env.txt /tmp/k_.env.test.txt   # 无输出 = 键集对齐
comm -3 /tmp/k_.env.txt /tmp/k_.env.prod.txt
```

---

## 五、部署流程

```bash
# 1. 准备环境变量（首次部署）：三份文件按键集对齐填好真实值
vim src/backend/<SERVICE_NAME>/.env

# 2.（仅 test/prod 需要）在目标机器上申请 SSL 证书
bash scripts/apply-ssl.sh test    # 或 prod

# 3. 执行部署
bash scripts/deploy.sh                                  # 本机 dev：后端 + 前端
bash scripts/deploy.sh --env test --remote root@<HOST>  # 构建后推到 test 机器
bash scripts/deploy.sh --target ssl --env prod --remote root@<HOST>
```

`deploy.sh` 一次后端部署做的事：
`mvn package` → JAR 按 `<服务>-<版本>.jar` 落盘并更新 `<服务>.jar` 软链 →
按 `--env` 选中 env 文件覆盖远端 `.env`（并做键集比对）→ inline 写
`/etc/supervisor/conf.d/<服务>.conf` → `supervisorctl reread/update/restart` →
**健康检查通过**后 → 自动同步 nginx 站点配置（`nginx -t` 通过才 reload）。

- nginx 未安装时跳过站点配置同步并打日志（完整安装走 `--target ssl`）
- 脚本必须在工程根目录执行（会校验 `pwd` 与 `scripts/` 的相对位置）
- 结尾输出 `[STATUS] OK|ERROR - ...` 供 CI/agent 机器读取，后面是访问地址与产物位置摘要

**健康检查**：
- 端点：`http://127.0.0.1:<APP_PORT>/api/<SERVICE_NAME>/health`
  （由 `config/RootController.java` 提供，无外部依赖、恒 200；
  含数据库连通性的深检看本机 `http://127.0.0.1:<APP_PORT>/actuator/health`）
- 启动/重启后每 5 秒轮询一次，最长等待 420 秒（`SERVICE_READY_TIMEOUT` 可调）
- 超时未探活成功 → 部署以非零退出码中止并输出 `[STATUS] ERROR`，
  同时打印 `supervisorctl status` 与日志最后 120 行

---

## 六、`deploy.sh` 用法

```bash
bash scripts/deploy.sh -h                      # 完整帮助
bash scripts/deploy.sh --target backend        # 只部后端（可 -s 指定服务）
bash scripts/deploy.sh -t backend,web          # 逗号多值叠加
bash scripts/deploy.sh --target web            # 只构建并部署前端
bash scripts/deploy.sh --target ssl --env test # 装 nginx + 证书对应的站点配置
bash scripts/deploy.sh --target android        # 构建 APK（无 SDK 时回退源码包）
bash scripts/deploy.sh --target db --remote root@<HOST>   # 只同步数据库（破坏性）
bash scripts/deploy.sh --target backend --db --remote root@<HOST>  # 部代码 + 同步库
```

| 变量（环境变量形式覆盖） | 默认值 | 用途 |
|---|---|---|
| `APP_ROOT` | `/opt/soft/apps` | 应用部署根目录 |
| `LOG_ROOT` | `/data/logs/apps` | 应用日志根目录 |
| `SUPERVISOR_CONF` | `/etc/supervisor/supervisord.conf` | supervisord 主配置 |
| `SUPERVISOR_CONF_DIR` | `/etc/supervisor/conf.d` | supervisord 程序配置目录 |
| `SUPERVISOR_CONF_SUFFIX` | 按主机 `[include]` 自动解析 | 强制指定程序配置后缀（`conf`/`ini`），一般不用设 |
| `NGINX_CONF_DIR` | `/etc/nginx/conf.d` | 站点配置落地目录 |
| `NGINX_SSL_DIR` | `/etc/nginx/ssl` | 证书目录（与 apply-ssl.sh 的 `CERT_DIR` 一致） |
| `SERVICE_READY_TIMEOUT` | `420` | 健康检查最长等待秒数 |
| `WEB_DEPLOY_PATH` | `/opt/soft/apps/<SERVICE_NAME>/web` | 前端部署目录 |
| `PUBLIC_IP` | 自动探测 | 摘要里显示的访问地址 |

---

## 七、数据库部署约定

- 数据库名、角色名与服务名保持一致：`<DB_NAME>` / `<DB_NAME>`
- 生产凭证只存在于目标机器的 `/opt/soft/apps/<SERVICE_NAME>/.env`，不进代码库
- dev/test/prod 三台机器各自独立的 PostgreSQL 实例，互不共享数据

### 7.1 结构变更只有一条路径：Flyway

| 项 | 约定 |
|---|---|
| 迁移脚本 | `src/backend/<服务>/src/main/resources/db/migration/V<n>__<主题>.sql`，随 jar 打包、**入库** |
| 执行时机 | 应用启动时自动迁移到最新版本（dev/test/prod 三套都一样） |
| 记账 | 目标库自己的 `flyway_schema_history` 表（Flyway 自动建、自动写） |
| 应用侧 | `spring.flyway.enabled: ${FLYWAY_ENABLED:true}`、`jpa.hibernate.ddl-auto: validate`（只校验不建表） |
| 手工连库 | `scripts/db-sql.sh`：临时查询、数据订正、排障 —— **不改结构**（见 7.3） |
| Maven 依赖 | 工程 `pom.xml` 必须显式含 `org.flywaydb:flyway-core`（PostgreSQL 另加 `flyway-database-postgresql`）；`spring-boot-starter-data-jpa` 不带 Flyway，缺依赖时 `spring.flyway.*` 整段被静默忽略、一次迁移都不跑 |

**迁移失败怎么暴露**：Flyway 跑挂 → 应用启动失败 → `deploy.sh` 的健康检查（420s 内轮询
`/api/<SERVICE_NAME>/health`）拿不到 200 → 本次部署判失败并以非零码中止。所以结构变更与代码是
**同一次原子落地**：不存在"代码上了、迁移忘跑"，也不会带着半套结构接流量。这就是 prod 也自动迁移的
理由 —— 把迁移挂到部署这个受控动作上，比"人记得去跑一次"可靠。

**接管已有结构的库**：库里已有表但没有 `flyway_schema_history` 时，`baseline-on-migrate: true` 会让
Flyway 先补一条基线记录再往下迁移；`baseline-version: 0`（Flyway 默认是 1）是为了让库里已有的
`V1__` 脚本照常参与判定，不然 V1 会被当成"基线之前"跳过。

### 7.2 新增一个结构变更

1. 在本模块 `src/main/resources/db/migration/` 下新建 `V<n>__<主题>.sql`，编号接现有最大号往后，
   **不复用、不重排**已存在的编号：`flyway_schema_history` 按版本号记账，重号会让"V7 已应用"这类
   记录自相矛盾；改动一个已应用过的脚本会让 Flyway 校验失败并拒绝启动 —— 这是特性不是故障，
   要修就新开一个 V 文件。
2. SQL 写成幂等（`ADD COLUMN IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS` / 带 `WHERE` 的订正），
   三套环境执行同一份。
3. 本地起一次应用就完成 dev 迁移；确认落到哪一版：

   ```bash
   echo "select installed_rank,version,description,installed_on,success \
         from flyway_schema_history order by installed_rank desc limit 5" \
     | bash scripts/db-sql.sh -e dev -s <SERVICE_NAME>
   ```

4. test/prod **没有额外步骤** —— 部署（重启进程）本身就是迁移，见第五节部署流程。

### 7.3 手工 SQL 入口 `scripts/db-sql.sh`（只碰数据，不碰结构）

```bash
bash scripts/db-sql.sh -e dev  -s <SERVICE_NAME> -f check.sql                 # 只读（默认）
bash scripts/db-sql.sh -e test -r <user@host> -s <SERVICE_NAME> -f fix.sql    # test 库只读
bash scripts/db-sql.sh -e test -r <user@host> --apply -f fix.sql              # 放开写：数据订正
bash scripts/db-sql.sh -e prod -r <user@host> --apply --prod-approved -f ...  # prod 手工写要两把锁
```

硬护栏（脚本内置，不要绕过）：

- **默认只读**：连上即数据库侧强制 `default_transaction_read_only=on`，没写 `--apply` 就物理上写不进去
- `-e test|prod` 的库不在本机，**必须显式 `-r`**，脚本内不登记任何目标机。理由：本机 `.env.test` 里的
  `DB_HOST=127.0.0.1` 指的是 test 那台机自己，在 dev 机器上照它连到的是 dev 库
- prod 手工写必须 `-e prod` 与 `--prod-approved` 同时给（后者是"人在场并确认"的第二把锁；
  应用启动时的 Flyway 迁移不经本脚本，不需要人放行）
- 凭据从目标机的 `.env` 现取，只进那一次进程的环境变量，不落盘、不回显；SQL 经 ssh 标准输入流式执行，
  目标机上不留任何文件

### 7.4 `--target db`：全量重建，不是升级

`--target db` 是**破坏性**操作：pg_dump 本地 dev 库 → 上传 → 远端断开连接、
`dropdb` + `createdb` + 恢复。默认要输入 `yes` 二次确认，`-y` 跳过。
它把远端库里比本地新的数据一起冲掉，**已经 Flyway 迁移过的环境绝不要用它"补结构"** ——
那会把远端的 `flyway_schema_history` 一起换成源库的版本，两边记账从此对不上。

首次建库（只需要空库 + 一个有建表权限的角色，表由 Flyway 在应用第一次启动时建出来）：

```bash
sudo -u postgres createuser -P <DB_NAME>
sudo -u postgres createdb -O <DB_NAME> <DB_NAME>
bash scripts/deploy.sh            # 启动时 Flyway 建 flyway_schema_history 并跑完 db/migration/ 下所有脚本
```

---

## 八、部署前检查清单

```bash
supervisorctl status                                    # supervisord daemon 是否在跑
ls src/backend/<SERVICE_NAME>/.env                      # 三份 env 是否齐、键集是否对齐
ss -tln | grep -E ':(<NGINX_PORT>|<APP_PORT>)\b'         # 本机部署时目标端口是否空闲
nginx -t                                                # nginx 配置当前是否健康（基线状态）
# 目标库当前落在 Flyway 的哪一版（只读，先知道起点）：
echo 'select installed_rank,version,description,success from flyway_schema_history order by installed_rank desc limit 3' \
  | bash scripts/db-sql.sh -e dev -s <SERVICE_NAME>
```

**结构变更不需要"先升库"这一步**：Flyway 在应用启动时把库带到本次代码要求的版本，迁移与代码同一次
部署落地。迁移失败会让应用起不来 → 健康检查超时 → 部署中止（不会带着半套结构接流量），此时看
`/data/logs/apps/<SERVICE_NAME>/supervisord.log` 里的 Flyway 报错。

**回滚代码不等于回滚结构**：Flyway 只做前滚，不会因为 jar 换回旧版就把表改回去。要退结构就再提交一个
`V<n+1>__revert_*.sql` 把它改回来 —— 因此每个迁移脚本都要写成"能被下一个脚本反向修正"的形态，
不要在迁移脚本里做不可逆的数据销毁。

test/prod 额外确认（按域名命名，不是按服务名）：
```bash
ls /etc/nginx/ssl/<TEST_DOMAIN>.pem /etc/nginx/ssl/<TEST_DOMAIN>.key
```

全部确认后再执行 `scripts/deploy.sh`。

---

## 九、回滚与停止

```bash
# 停止服务（不删除部署文件，可随时重启）
supervisorctl stop <SERVICE_NAME>

# 回滚到上一个版本 JAR：软链指回旧文件即可（历史版本 JAR 不会被新部署删除）
cd /opt/soft/apps/<SERVICE_NAME> && ls -1 <SERVICE_NAME>-*.jar    # 挑一个
ln -sfn <SERVICE_NAME>-<旧版本>.jar <SERVICE_NAME>.jar
supervisorctl restart <SERVICE_NAME>

# 完全移除（谨慎，仅在确定不再需要时执行）
supervisorctl stop <SERVICE_NAME>
rm /etc/supervisor/conf.d/<SERVICE_NAME>.<后缀>   # 后缀以主机 [include] 为准，见第三节
supervisorctl reread && supervisorctl update
rm /etc/nginx/conf.d/<SERVICE_NAME>.conf
nginx -t && nginx -s reload
```

`deploy.sh` 只写自己服务的 `.conf`，不删除、不改动同主机其他项目的 supervisord 程序或
nginx 站点配置（见通用规范第三节规则 3、4）。

---

## 十、微服务扩展（新增第二个服务）

本工程按单服务生成。后续往同一站点加第二个微服务时，需要同时改六处：

1. `scripts/deploy.sh` 顶部服务表：`SERVICES`、`SERVICE_PORTS`、`SERVICE_HEALTH_PATHS`、
   `SERVICE_DBS` 各追加一条（新服务用独立端口，登记到通用规范端口总表）
2. `scripts/db-sql.sh` 顶部的 `SERVICES` 表：与 deploy.sh 保持同一份名单（不齐就会出现
   "deploy.sh 能部、db-sql.sh 说这服务不在册"的裂口）
3. `src/backend/<新服务>/src/main/resources/db/migration/`：新服务自己的 Flyway 迁移目录
   （独立库就独立一套 `flyway_schema_history`，两个服务的版本号互不相干）
4. `deploy-conf/nginx/<SERVICE_NAME>.{dev,test,prod}.conf`：为新服务加 `upstream` +
   `location`（按路径前缀分流）
5. `src/backend/<新服务>/.env{,.test,.prod}`：三份键集对齐的环境变量
6. 前端如按端拆分（如管理台 / 门店端两套），把 `deploy.sh` 的 `WEB_APPS` 改成多项并填齐
   `WEB_APP_SOURCE` / `WEB_APP_DEPLOY` / `WEB_APP_BASE_PATH` / `WEB_APP_PROJECT_ID` 四张表，
   `basePath` 必须与 nginx 里的 location 前缀一致

> 每个服务连自己的库、各自跑自己的 Flyway：部署时哪个进程起来就迁移哪个库，
> 不需要跨服务的迁移顺序协调。
> `db-sql.sh -s <服务>` 决定的是"用哪份 .env 的连接参数"，多服务时务必显式指定，别默认连到第一项。
