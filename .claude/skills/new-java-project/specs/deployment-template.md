# 部署规范（<SERVICE_NAME> 专属）

> 定位：本工程（<SERVICE_NAME>）的部署约定与操作细节。
> **主机层面、跨项目通用的规则（目录/命名约定、端口登记总表、共享 supervisord/nginx 的操作规范、
> 故障案例）都在 [共享主机部署通用规范](./deployment-common.md) 里，本文档不重复，只写
> <SERVICE_NAME> 自己的部分**。执行任何部署操作前，先确认已经读过那份通用规范。
> 适用范围：`scripts/deploy.sh`（含 `scripts/apply-ssl.sh`）、`scripts/db-migrate.sh` 与
> `scripts/db-sql.sh`（数据库迁移两层）等部署脚本，以及 `deploy-conf/` 下的部署配置。
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

### 7.1 结构变更只有一条路径：文件式增量迁移

| 项 | 约定 |
|---|---|
| 结构定义 | `deploy-conf/db/migrations/<服务>/V<n>__<主题>.sql`，**入库**（与代码同版本演进） |
| 执行入口 | `scripts/db-migrate.sh`（迁移层：判已应用/待应用、按版本序增量执行、写留痕） |
| 连库执行 | `scripts/db-sql.sh`（执行层：取连接参数、拼 ssh、起 psql，唯一连库处） |
| 应用侧 | `spring.flyway.enabled: ${FLYWAY_ENABLED:false}`（默认关）、`jpa.hibernate.ddl-auto: validate`（只校验不建表） |
| 运行留痕 | `deploy-conf/db/migrate-records/<env>.md`，**不入库**（本机每次问答的历史，不是结构定义） |

**已应用与否不建记账表**：每个迁移文件头部写 `-- @probe:` 探测语句，脚本拿它现问目标库，答出
「已应用／待应用／需人工／重复执行／未标注／探测出错」六态。约定与理由见
`deploy-conf/db/migrations/<服务>/README.md`。

**为什么 Flyway 默认关**：两套迁移机制同时开＝两条记账路径，同一个变更会有两个互相矛盾的答案
（脚本说待应用、Flyway 说已在 `flyway_schema_history` 里）。要用 Flyway 接管，先把迁移脚本放进
`locations` 并对已有库 baseline，再把默认值翻成 `true`——不能两套并行。

### 7.2 常用命令

```bash
bash scripts/db-migrate.sh -q                                    # 本机 dev 还差哪些增量（只读）
bash scripts/db-migrate.sh                                       # 本机 dev 增量升级（跑前确认）
bash scripts/db-migrate.sh -e test -r <user@host> -q             # 现问 test 库差集（只读，不需 --yes）
bash scripts/db-migrate.sh -e test -r <user@host> --yes          # 升 test 库
bash scripts/db-migrate.sh -e prod -r <user@host> --yes --confirm-prod    # prod 双确认
bash scripts/db-sql.sh -e dev -s <SERVICE_NAME> --apply -f <文件>          # 手工跑单个文件 / manual 类迁移
```

硬护栏（脚本内置，不要绕过）：

- `-e test|prod` 的库不在本机，**必须显式 `-r`**；不给 `-r` 时查询走离线答复（照录本地留痕）、
  升级在连库前直接拒绝。理由：本机 `.env.test` 里的 `DB_HOST=127.0.0.1` 指的是 test 那台机自己，
  照它连就连到 dev 库，报告与 dev 一字不差——那是假绿。
- 远端写操作必须带 `--yes`；prod 增量执行必须 `--yes` 与 `--confirm-prod` 同时给（双确认锁只在
  迁移层判一次，执行层认调用方转来的 `--prod-approved`）。
- `需人工`／`未标注`／`探测出错` 三类文件永不自动执行；`-q` 全程只读（连执行函数都带一道
  "查询模式不得执行"的自我保护）。
- 永不 DROP、永不重建、永不从备份恢复——那是 `deploy.sh --target db` 的动作。

### 7.3 `--target db`：全量重建，不是升级

`--target db` 是**破坏性**操作：pg_dump 本地 dev 库 → 上传 → 远端断开连接、
`dropdb` + `createdb` + 恢复。默认要输入 `yes` 二次确认，`-y` 跳过。
它把远端库里比本地新的数据一起冲掉，**已明确执行过某条迁移的环境绝不要用它"补迁移"**。

首次建库：

```bash
sudo -u postgres createuser -P <DB_NAME>
sudo -u postgres createdb -O <DB_NAME> <DB_NAME>
```

---

## 八、部署前检查清单

```bash
supervisorctl status                                    # supervisord daemon 是否在跑
ls src/backend/<SERVICE_NAME>/.env                      # 三份 env 是否齐、键集是否对齐
ss -tln | grep -E ':(<NGINX_PORT>|<APP_PORT>)\b'         # 本机部署时目标端口是否空闲
nginx -t                                                # nginx 配置当前是否健康（基线状态）
bash scripts/db-migrate.sh -q                           # 有没有还没升的增量（只读）
```

**先升库、再部代码**：新代码往往依赖新列/新索引，库没跟上就让应用启动时的 `ddl-auto: validate`
直接失败（这是它该干的活）。所以 `-q` 报出的 `待应用` 必须在部署前用 `db-migrate.sh --yes` 清零。

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
2. `scripts/db-migrate.sh` 与 `scripts/db-sql.sh` 顶部的 `SERVICES` 表：与 deploy.sh 保持同一份名单
   （三份不齐 = 迁移脚本认不出这个服务，或反过来把迁移动作指向一个不存在的服务目录）
3. `deploy-conf/db/migrations/<新服务>/`：新服务的迁移目录（自己一套 `V<n>__*.sql` + `README.md`，
   新库先按该 README 第〇节落 `V0` 基线）
4. `deploy-conf/nginx/<SERVICE_NAME>.{dev,test,prod}.conf`：为新服务加 `upstream` +
   `location`（按路径前缀分流）
5. `src/backend/<新服务>/.env{,.test,.prod}`：三份键集对齐的环境变量
6. 前端如按端拆分（如管理台 / 门店端两套），把 `deploy.sh` 的 `WEB_APPS` 改成多项并填齐
   `WEB_APP_SOURCE` / `WEB_APP_DEPLOY` / `WEB_APP_BASE_PATH` / `WEB_APP_PROJECT_ID` 四张表，
   `basePath` 必须与 nginx 里的 location 前缀一致

> 多服务共用一个站点、但各连自己的库：`db-migrate.sh` 会逐服务解析连接、逐服务报库身份指纹，
> 两个库的 `V<n>` 号互不相干（同号只是巧合），要只升其中一个用 `--only <服务>/V<n>`。
