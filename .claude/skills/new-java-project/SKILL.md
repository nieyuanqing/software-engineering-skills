---
name: new-java-project
description: 为 Java/Spring Boot 工程生成完整的标准化部署配置：deploy.sh、apply-ssl.sh、nginx 站点配置（dev/test/prod 三套）、三套键集对齐的 .env、Spring Boot 配置与健康检查端点、specs/deployment.md、标准 .gitignore（含 env 与 SQL 文件忽略）、sql 目录。supervisord 配置由 deploy.sh 部署时 inline 生成。所有产物遵循共享主机部署通用规范（统一目录、健康检查、日志格式、supervisord 安全操作规范）。当用户要求"初始化部署"、"创建部署脚本"、"配置 nginx/supervisor"、"新建 Java 工程部署"时触发。支持 /new-java-project -h 查看帮助。
---

# new-java-project

为新工程生成完整的标准化部署配置，包括部署脚本、nginx 站点配置、环境变量模板、Spring Boot 配置与
健康检查端点、部署规范文档和 `.gitignore`。所有产物严格遵循本 skill 目录下
`specs/deployment-common.md` 的共享主机部署通用规范，不包含任何硬编码的项目信息。

**触发条件**：用户要求为某工程创建部署配置、部署脚本、nginx/supervisor 配置，或说"初始化部署"。

**与 `/new-nginx-conf` 的分工**：`deploy-conf/nginx/` 这棵目录树由两个 skill 共同拥有——
主机级基础配置（`nginx.conf`、`subconf/`、`mime.types`、错误页）归 `/new-nginx-conf`，
本 skill 只生成**本站点**的 `<SERVICE_NAME>.{dev,test,prod}.conf` 三份配置，不生成、不覆盖主机级文件。
目标主机上缺 `nginx.conf` 不影响部署：`deploy.sh` 只同步站点配置，遇到主配置缺失会跳过并打警告。

---

## 零、参数处理

**如果用户传入 `-h` 或 `--help`**，不执行任何文件操作，直接把下面的帮助信息**原样输出在本次回复正文里**后结束（斜杠命令把 SKILL.md 注入我的上下文不等于已展示给用户，正文里只回一句"已输出"就是没输出）。`-h` 与其它参数或说明文字同时出现时，一律**只出帮助、忽略其余参数**：本轮不猜附加要求，需要同时执行就把 `-h` 去掉分两次调用：

---

```
用法: /new-java-project [SERVICE_NAME] [选项]

  SERVICE_NAME    可选位置参数，直接指定服务名。
                  不传时提示采用当前目录名称作为默认值。

选项（通过命令行传入的参数直接使用，不再交互询问）
  --nginx-port=N          nginx 对外监听端口（如 --nginx-port=50000）
  --app-port=N            Spring Boot 内部端口（如 --app-port=50001）
  --db-port=N             PostgreSQL 端口（如 --db-port=5432）
  --db-name=NAME          数据库名（如 --db-name=my-service）
  --test-domain=DOMAIN    test 环境域名（如 --test-domain=svc.test.example.com）
  --prod-domain=DOMAIN    prod 环境域名（如 --prod-domain=svc.example.com）
  --has-web=true|false    是否有前端静态资源，默认 true（如 --has-web=false）
  --web-path=PATH         前端路径前缀，默认 /<SERVICE_NAME>/web，不带结尾斜杠（如 --web-path=/admin）
  --api-prefix=PREFIX     API 路径前缀，默认 /<SERVICE_NAME>/api，不带结尾斜杠（如 --api-prefix=/v1）
  --base-package=PKG      Java 根包名，默认 com.<SERVICE_NAME 去掉连字符>，
                          用于 application-<profile>.yml 的日志级别键与 RootController 的 package
                          （如 --base-package=com.example.myservice）
  --jdk-version=N         JDK 基线版本，默认 21（如 --jdk-version=21）
  --pg-version=N          PostgreSQL 基线版本，默认 17（如 --pg-version=17）
  -h, --help              显示本帮助（出现即忽略其它参数，只出帮助）

功能
  为 Java/Spring Boot 工程生成完整的标准化部署配置，包括：
    - scripts/deploy.sh                    部署脚本（Maven 构建、supervisord 管理、健康检查、
                                           远程部署、多微服务/多前端、nginx 站点自动同步、数据库同步）
    - scripts/apply-ssl.sh                 SSL 证书申请脚本（Let's Encrypt + acme.sh，
                                           证书按域名装到 /etc/nginx/ssl/<域名>.{pem,key}）
    - deploy-conf/nginx/<name>.dev.conf    nginx 站点配置（dev，HTTP/IP+端口）
    - deploy-conf/nginx/<name>.test.conf   nginx 站点配置（test，HTTPS/域名）
    - deploy-conf/nginx/<name>.prod.conf   nginx 站点配置（prod，HTTPS/域名）
    - src/backend/<name>/.env              环境变量（dev，同时是键集基准）
    - src/backend/<name>/.env.test         环境变量（test），键集与 .env 一致
    - src/backend/<name>/.env.prod         环境变量（prod），键集与 .env 一致
    - src/backend/<name>/src/main/resources/application.yml       公共配置（端口/地址、时区、
                                           上传上限、JPA、Flyway、Actuator、Swagger 开关）
    - src/backend/<name>/src/main/resources/application-dev.yml   dev profile（数据源、show-sql、DEBUG）
    - src/backend/<name>/src/main/resources/application-test.yml  test profile（数据源、INFO）
    - src/backend/<name>/src/main/resources/application-prod.yml  prod profile（数据源、WARN）
    - src/backend/<name>/src/main/java/<包>/config/RootController.java
                                           健康检查端点 /api/<name>/health + 服务说明端点
    - sql/README.md + sql/backup/ + sql/update/   数据库备份与更新 SQL 目录（backup 不入库，update 入库）
    - specs/deployment.md                  本工程专属部署规范文档
    - specs/baseline-versions.md           基线版本规范（JDK、PostgreSQL、Spring Boot 等）
    - .gitignore                           标准忽略清单（env/SQL/证书/构建产物）

  所有产物遵循随本 skill 分发的 specs/deployment-common.md 跨项目通用规范：
    - 统一目录约定：/opt/soft/apps/<name>/、/data/logs/apps/<name>/
    - 健康检查端点：应用内 /api/<name>/health，经 nginx 为 /<name>/api/health
      （startsecs=10 只防立即崩溃；就绪与否由健康检查判定，最长等待 420s，每 5s 一轮）
    - 部署日志格式：[YYYY-MM-DD HH:MM:SS] [deploy.sh] <message>，阶段日志 Phase N/M，
      结尾 [STATUS] OK|ERROR - <结论> 供 CI/agent 机器读取
    - supervisord 配置由 deploy.sh 在部署时 inline 生成（不从静态 ini 文件复制）
    - JAR 版本化落盘（<name>-<版本>.jar）+ 稳定软链（<name>.jar），回滚只改软链
    - 支持 --remote USER@HOST 远程部署（本地构建，rsync 上传，SSH 远程重启）
    - 后端部署后自动同步 nginx 站点配置；完整 nginx 安装走 --target ssl
    - 跨域在 nginx 层用 map $http_origin 白名单处理；访问日志里 Bearer 令牌只记前 8 位
    - 三套 .env 键集必须一致，deploy.sh 部署前比对并告警缺失的键

示例
  /new-java-project
      交互式向导，以当前目录名为默认服务名，逐步询问所有参数

  /new-java-project my-service
      指定服务名，其余参数交互询问

  /new-java-project my-service --nginx-port=50000 --app-port=50001 --db-port=5432
      指定服务名和端口，其余参数（域名、HAS_WEB 等）仍交互询问

  /new-java-project my-service --nginx-port=50000 --app-port=50001 --db-port=5432 \
      --db-name=my-service --test-domain=svc.test.example.com \
      --prod-domain=svc.example.com --has-web=false
      所有参数均通过命令行指定，直接回显确认后生成文件，不需要任何交互

  /new-java-project -h
      显示本帮助

生成后自动执行
  chmod +x scripts/deploy.sh scripts/apply-ssl.sh
  替换完成后校验：bash -n scripts/deploy.sh（应为替换后的真实值，不再含 <占位符>）
  在目标工程 specs/deployment-common.md 的端口登记表中追加新端口行
  （如该文件不存在，询问用户是否用本 skill 自带副本初始化后再登记）

注意
  - 如目标文件已存在，会展示差异并询问是否覆盖，不会静默覆盖
  - .env / .env.test / .env.prod 里的密码保持占位符 changeme，不会写入真实凭证；
    这三份文件被 .gitignore 忽略，不入库
  - 不会自动创建 CLAUDE.md，但如已存在会在其中追加 specs/deployment.md 引用
```

---

## 一、收集参数

### 1.1 解析命令行参数

按以下规则从用户输入中提取参数，已提取到的参数跳过后续交互询问：

| 命令行写法 | 对应参数 |
|---|---|
| 第一个非 `--`/`-` 开头的词 | `SERVICE_NAME` |
| `--nginx-port=N` | `NGINX_PORT` |
| `--app-port=N` | `APP_PORT` |
| `--db-port=N` | `DB_PORT` |
| `--db-name=NAME` | `DB_NAME` |
| `--test-domain=DOMAIN` | `TEST_DOMAIN` |
| `--prod-domain=DOMAIN` | `PROD_DOMAIN` |
| `--has-web=true\|false` | `HAS_WEB`（默认 `true`） |
| `--web-path=PATH` | `WEB_PATH`（默认 `/<SERVICE_NAME>/web`，**去掉结尾斜杠**） |
| `--api-prefix=PREFIX` | `API_PATH_PREFIX`（默认 `/<SERVICE_NAME>/api`，**去掉结尾斜杠**） |
| `--base-package=PKG` | `BASE_PACKAGE`（默认 `com.` + `SERVICE_NAME` 去掉 `-`/`_`/空格） |
| `--jdk-version=N` | `JDK_VERSION`（默认 `21`） |
| `--pg-version=N` | `PG_VERSION`（默认 `17`） |

用户传入带结尾斜杠的 `--web-path` / `--api-prefix` 时，**去掉结尾斜杠**再替换进模板
（模板里所有引用处都自己补 `/`，见第三节占位符说明）。

### 1.2 SERVICE_NAME 确定（优先级从高到低）

1. **命令行位置参数**（如 `/new-java-project my-service`）：直接使用，不再询问。
2. **无位置参数**：读取当前工作目录名，转为小写、空格替换为连字符，作为建议默认值，提示：
   > `SERVICE_NAME 未指定，建议使用当前目录名 "<目录名>" 作为服务名，直接回车确认或输入新名称：`
3. **用户手动输入**：用户输入其他名称则使用输入值。

`SERVICE_NAME` 会同时用作 Maven `artifactId`、`spring.application.name`、supervisord 程序名、
数据库名与用户名（通用规范第一节要求全同名）。含连字符的名称在 Java 包名与 `upstream` 名称里
不合法，因此 `BASE_PACKAGE` 默认值与 nginx 的 `map`/`log_format`/`upstream` 名称会把连字符换成下划线。

### 1.3 交互询问缺失参数

`SERVICE_NAME` 确定后，**将所有未通过命令行提供的必填参数一次性列出**，统一询问（不要一个一个问）：

| 参数 | 说明 | 默认值 |
|---|---|---|
| `NGINX_PORT` | nginx 对外监听端口，需通过 `ss -tln` 确认未被占用 | 无 |
| `APP_PORT` | Spring Boot 内部端口（只绑 127.0.0.1），通常 `NGINX_PORT + 1` | 无 |
| `DB_PORT` | PostgreSQL 端口 | `5432` |
| `DB_NAME` | 数据库名 | 与 `SERVICE_NAME` 相同 |
| `TEST_DOMAIN` | test 环境域名 | 无 |
| `PROD_DOMAIN` | prod 环境域名 | 无 |
| `HAS_WEB` | 是否有前端静态资源（`true`/`false`） | `true` |
| `WEB_PATH` | 前端路径前缀（`HAS_WEB=true` 时有效），不带结尾斜杠 | `/<SERVICE_NAME>/web` |
| `API_PATH_PREFIX` | nginx 反代 API 路径前缀，不带结尾斜杠 | `/<SERVICE_NAME>/api` |
| `BASE_PACKAGE` | Java 根包名（日志级别键 + RootController 的 package） | `com.<SERVICE_NAME 去连字符>` |
| `JDK_VERSION` | JDK 基线版本 | `21` |
| `PG_VERSION` | PostgreSQL 基线版本 | `17` |

所有参数确定后，**向用户回显完整参数列表**，确认无误后再生成文件。

---

## 二、生成文件清单

以下文件全部在**目标工程根目录**下生成（即用户当前在操作的工程，不是 skill 安装目录本身）。
`deploy-conf/nginx/` 下的主机级基础配置（`nginx.conf`、`subconf/` 等）属于 `/new-nginx-conf` skill，
本 skill 不生成、不覆盖，只写本站点的三份 `<SERVICE_NAME>.*.conf`：

```
scripts/deploy.sh
scripts/apply-ssl.sh
.gitignore
deploy-conf/nginx/<SERVICE_NAME>.dev.conf
deploy-conf/nginx/<SERVICE_NAME>.test.conf
deploy-conf/nginx/<SERVICE_NAME>.prod.conf
src/backend/<SERVICE_NAME>/.env
src/backend/<SERVICE_NAME>/.env.test
src/backend/<SERVICE_NAME>/.env.prod
src/backend/<SERVICE_NAME>/src/main/resources/application.yml
src/backend/<SERVICE_NAME>/src/main/resources/application-dev.yml
src/backend/<SERVICE_NAME>/src/main/resources/application-test.yml
src/backend/<SERVICE_NAME>/src/main/resources/application-prod.yml
src/backend/<SERVICE_NAME>/src/main/java/<BASE_PACKAGE 的路径段>/config/RootController.java
sql/README.md
sql/update/.gitkeep
specs/deployment.md
specs/baseline-versions.md
```

> `sql/backup/` 同时创建（空目录，整体被 .gitignore 忽略，不需要占位文件）；
> `sql/update/.gitkeep` 为空占位文件，保证空目录可入库。

---

## 三、生成规则

每个文件的内容来自**本 skill 目录**下的对应模板文件（随 skill 一起分发，不依赖任何仓库克隆或本地工程），
将所有占位符替换为实际参数值。

### 占位符替换表

| 占位符 | 替换为 |
|---|---|
| `<SERVICE_NAME>` | `SERVICE_NAME` 参数值 |
| `<NGINX_PORT>` | `NGINX_PORT` 参数值 |
| `<APP_PORT>` | `APP_PORT` 参数值 |
| `<DB_PORT>` | `DB_PORT` 参数值 |
| `<DB_NAME>` | `DB_NAME` 参数值 |
| `<TEST_DOMAIN>` | `TEST_DOMAIN` 参数值 |
| `<PROD_DOMAIN>` | `PROD_DOMAIN` 参数值 |
| `<API_PATH_PREFIX>` | `API_PATH_PREFIX` 参数值，**不带结尾斜杠**（如 `/my-service/api`） |
| `<WEB_PATH>` | `WEB_PATH` 参数值，**不带结尾斜杠**（如 `/my-service/web`） |
| `<BASE_PACKAGE>` | `BASE_PACKAGE` 参数值（如 `com.example.myservice`） |
| `<JDK_VERSION>` | `JDK_VERSION` 参数值（默认 `21`） |
| `<PG_VERSION>` | `PG_VERSION` 参数值（默认 `17`） |
| `<CREATE_DATE>` | 当前日期，格式 `YYYY-MM-DD` |

模板里的引用处一律自己补 `/`（`location <API_PATH_PREFIX>/ {`、`<API_PATH_PREFIX>/health`、
`try_files ... <WEB_PATH>/index.html`），所以**替换值带结尾斜杠会生成双斜杠路径**。
`nginx` 站点配置里 `map`/`log_format`/`upstream` 的名称写作 `<SERVICE_NAME>_xxx`，
含连字符的服务名要换成下划线（Java 标识符与 nginx 变量名都不接受 `-`）。

### 各文件来源

以下"模板来源"路径均相对于**本 skill 目录**（安装后通常为 `~/.qoder/skills/new-java-project/`）。

| 目标文件 | 模板来源 |
|---|---|
| `scripts/deploy.sh` | `templates/scripts/deploy.sh` |
| `scripts/apply-ssl.sh` | `templates/scripts/apply-ssl.sh` |
| `.gitignore` | `templates/gitignore` |
| `deploy-conf/nginx/<SERVICE_NAME>.dev.conf` | `templates/deploy-conf/nginx/service.dev.conf` |
| `deploy-conf/nginx/<SERVICE_NAME>.test.conf` | `templates/deploy-conf/nginx/service.test.conf` |
| `deploy-conf/nginx/<SERVICE_NAME>.prod.conf` | `templates/deploy-conf/nginx/service.prod.conf` |
| `src/backend/<SERVICE_NAME>/.env` | `templates/src/backend/service/.env` |
| `src/backend/<SERVICE_NAME>/.env.test` | `templates/src/backend/service/.env.test` |
| `src/backend/<SERVICE_NAME>/.env.prod` | `templates/src/backend/service/.env.prod` |
| `.../src/main/resources/application.yml` | `templates/src/backend/service/src/main/resources/application.yml` |
| `.../src/main/resources/application-dev.yml` | `templates/src/backend/service/src/main/resources/application-dev.yml` |
| `.../src/main/resources/application-test.yml` | `templates/src/backend/service/src/main/resources/application-test.yml` |
| `.../src/main/resources/application-prod.yml` | `templates/src/backend/service/src/main/resources/application-prod.yml` |
| `.../src/main/java/<包路径>/config/RootController.java` | `templates/src/backend/service/src/main/java/config/RootController.java`（`<BASE_PACKAGE>` 按 `.` 拆成目录） |
| `sql/README.md` | `templates/sql/README.md` |
| `sql/update/.gitkeep` | `templates/sql/update/.gitkeep`（空占位文件，原样复制） |
| `specs/deployment.md` | `specs/deployment-template.md` |
| `specs/baseline-versions.md` | `specs/baseline-versions-template.md` |

### `.gitignore` 生成规则

- 目标工程**没有** `.gitignore` → 按 `templates/gitignore` 模板整体生成（含 Java/Maven、IDE、日志、
  **env 环境变量文件**、**SSL 证书与私钥**、**SQL/数据库文件**、前端与构建产物、Android 签名与 SDK 路径等条目）。
- 目标工程**已有** `.gitignore` → 不覆盖，仅将模板中缺失的条目合并追加（重点确保：
  `.env` / `.env.*` / `*.env` / `application-local.yml`，`deploy-conf/nginx/cert/*.pem|*.key`，
  `*.sql` / `*.dump` / `*.sqlite` / `*.db` 配合 `sql/backup/` 忽略与 `!sql/update/*.sql` 入库例外，
  `runtime/` / `web-tars/` / `mobile-apps/`），已存在的条目不重复添加。
- 注意：`src/backend/**/.env*` 三份环境变量文件**必须被忽略**（含真实凭证）；
  `application*.yml` 是被跟踪文件，里面只允许 `${VAR:}` 形式的空默认值。

### `HAS_WEB=false` 时的处理

如果 `HAS_WEB=false`：
1. 在生成的三份 nginx 配置中删除 `# ── 前端静态资源` 注释块及其下方到块尾的
   `location <WEB_PATH>/ { ... }` 与 `location ^~ <WEB_PATH>/_next/static/ { ... }` 两块。
2. 把 `scripts/deploy.sh` 顶部的 `HAS_WEB=true` 改为 `HAS_WEB=false`，并把 `WEB_APPS=("<SERVICE_NAME>")`
   置为 `WEB_APPS=()`（四张 `WEB_APP_*` 表保留但不会被用到）。改完后 `--target web` 与 `all`
   会明确报错"本服务无前端"，而不是静默什么也不做。

### 多微服务与多前端

本 skill 一次只为**一个服务**生成配置。目标工程已有微服务时（`src/backend/` 下不止一个模块），
询问用户是把新服务**并入已有 deploy.sh 的服务表**还是新生成一份脚本，默认并入：

- 在 `scripts/deploy.sh` 顶部服务表追加一条：`SERVICES`、`SERVICE_PORTS`、`SERVICE_HEALTH_PATHS`、
  `SERVICE_DBS` 各加一项（新服务用独立端口，并登记到端口总表）
- 在 `deploy-conf/nginx/<站点名>.{dev,test,prod}.conf` 里为该服务追加 `upstream` + `location`
  （按路径前缀分流），站点配置本身是一个站点一份，多微服务共用
- 新服务自己的 `src/backend/<新服务>/.env*` 三份文件照常生成

前端按端拆分（如管理台 + 门店端）时，把 `WEB_APPS` 改成多项并填齐 `WEB_APP_SOURCE` /
`WEB_APP_DEPLOY` / `WEB_APP_BASE_PATH` / `WEB_APP_PROJECT_ID` 四张表；只往 `WEB_APPS` 加名字时，
脚本会按 `src/web/<名字>`、`web-<名字>`、`/<名字>` 的目录约定兜底补全。
`WEB_APP_BASE_PATH` 必须与 nginx 里对应的 location 前缀一致，否则静态资源 404。

### 目标工程已有配置文件时

`application.yml` 与 `.env*` 属于工程自身可能已经存在的文件。逐个比对：
- 不存在 → 按模板生成
- 已存在 → 展示差异并询问；用户选择保留时，只需确认已有文件里
  `server.port`、`server.address`、健康检查路径与 `.env` 键集与本次生成的部署配置口径一致，
  不一致要指出，不能各留一套

---

## 四、生成后处理

### 设置文件权限并校验替换结果

```bash
chmod +x scripts/deploy.sh scripts/apply-ssl.sh
bash -n scripts/deploy.sh && bash -n scripts/apply-ssl.sh   # 有残留 <占位符> 会在这里暴露
grep -rn '<[A-Z_]\{3,\}>' scripts/deploy.sh scripts/apply-ssl.sh \
    deploy-conf/nginx/ src/backend/<SERVICE_NAME>/          # 应无输出
```

`bash -n` 在**模板原文件**上必然失败（`NGINX_PORT=<NGINX_PORT>` 不是合法 bash），
只有替换成真实值之后才用它来验证替换是否完整。

### 校验三份 env 键集一致

生成后立刻比对一次，作为交付质量检查（键集不齐会让后面每次部署都打警告）：

```bash
for f in .env .env.test .env.prod; do
  grep -oE '^[A-Z_]+=' src/backend/<SERVICE_NAME>/$f | tr -d '=' | sort > /tmp/k_$f.txt
done
comm -3 /tmp/k_.env.txt /tmp/k_.env.test.txt && comm -3 /tmp/k_.env.txt /tmp/k_.env.prod.txt   # 应无输出
```

### 更新目标工程 specs/deployment-common.md 端口登记

在**目标工程**的 `specs/deployment-common.md`「端口分配总表」中追加一行：
```
| `<NGINX_PORT>-<APP_PORT>` | <SERVICE_NAME>（见 [deployment.md](./deployment.md) 第三节） |
```

如果目标工程没有 `specs/deployment-common.md`：
1. 询问用户：`目标工程没有 specs/deployment-common.md（共享主机端口登记表）。是否用本 skill 自带的通用规范副本初始化该文件后再登记端口？（若这台主机上其他工程已有该文件，建议改为登记到那份文件）`
2. 用户同意 → 将本 skill 目录下 `specs/deployment-common.md` 复制为目标工程 `specs/deployment-common.md`，然后追加端口行。
3. 用户拒绝 → 跳过，但告知用户："请在共享主机的端口分配总表（deployment-common.md）中登记这两个端口，防止其他服务端口冲突。"

---

## 五、完成提示

生成完成后，向用户输出以下内容：

1. **已生成文件列表**（逐行列出路径）
2. **下一步操作**（根据实际情况生成，不要直接复制粘贴，而是用实际参数值）：

```
## 下一步操作

### 首次部署（dev 环境，本机）

1. 确认 supervisord daemon 正在运行，且端口 <NGINX_PORT>/<APP_PORT> 空闲：
   supervisorctl status
   ss -tln | grep -E ':(<NGINX_PORT>|<APP_PORT>)\b'   # 应为空输出
   nginx -t                                           # 应为通过（先拿到基线状态）

2. 准备数据库（如尚未创建）：
   sudo -u postgres createuser -P <DB_NAME>
   sudo -u postgres createdb -O <DB_NAME> <DB_NAME>

3. 填入真实凭证（三份 env 已在生成时写好，键集必须保持齐）：
   vim src/backend/<SERVICE_NAME>/.env      # DB_PASSWORD 等
   # 模板只包含生成的代码真正读取的键；业务自己新增的密钥（如 JWT_SECRET、第三方 API Key）
   # 按需追加，但必须三份同步加，否则 deploy.sh 会在部署时告警

4. 执行部署：
   bash scripts/deploy.sh

### 首次部署（dev 环境，远程服务器）

1. 把 dev 环境变量送到远程机器并填真实值：
   rsync src/backend/<SERVICE_NAME>/.env root@<HOST>:/opt/soft/apps/<SERVICE_NAME>/.env
   ssh root@<HOST> "vim /opt/soft/apps/<SERVICE_NAME>/.env"

2. 执行远程部署（本地构建 → rsync 上传 → 远程重启）：
   bash scripts/deploy.sh --remote root@<HOST>

### 首次部署（test/prod 环境）

在对应机器上：
1. 确认域名已解析到这台机器
2. 填入该环境的真实凭证（键集与 dev 对齐，密钥单独生成、不复用 dev 的值）：
   vim src/backend/<SERVICE_NAME>/.env.test     # 或 .env.prod
3. 申请 SSL 证书（80 端口需公网可达）：
   bash scripts/apply-ssl.sh test               # 或 prod
4. 执行部署（--target ssl 会安装 nginx 主配置 + 该环境的 HTTPS 站点配置）：
   bash scripts/deploy.sh --env test --remote root@<HOST>
   bash scripts/deploy.sh --target ssl --env test --remote root@<HOST>
5. 看到"降级使用 dev 配置（HTTP）"告警说明第 3 步的证书没到位，补签后重跑第 4 步

### 验证

curl -s http://127.0.0.1:<APP_PORT>/api/<SERVICE_NAME>/health          # 应用内
curl -s http://<本机IP>:<NGINX_PORT>/<SERVICE_NAME>/api/health         # 经 nginx
```

---

## 六、注意事项

- **不要修改目标工程 `specs/deployment-common.md`** 中的通用规范内容，只更新端口登记表。
- 生成的文件如果目标路径已存在，**先展示差异，询问用户是否覆盖**，不要直接覆盖。
- `.env` / `.env.test` / `.env.prod` 里的密码值保持占位符 `changeme`，不要填入任何真实凭证；
  `application*.yml` 里敏感项一律 `${VAR:}` 空默认。
- **supervisord 配置不生成静态 ini 文件**：deploy.sh 在部署时 inline 生成
  `/etc/supervisor/conf.d/<SERVICE_NAME>.conf`，无需在版本库中维护 supervisor 配置文件。
- Spring 环境（dev/test/prod）通过 env 文件中的 `SPRING_PROFILES_ACTIVE` 传递给 JVM，
  supervisord 命令行不写死 `--spring.profiles.active`。
- 健康检查端点由生成的 `RootController.java` 提供，路径必须是 `/api/<SERVICE_NAME>/health`
  （deploy.sh 的服务表、nginx 站点配置、`specs/deployment.md` 三处都按它对接）。
  不要改成 Actuator 默认 `/actuator/health`，那会让部署脚本探不到就绪状态。
- 应用端口必须只绑 `127.0.0.1`（`SERVER_ADDRESS` 默认值），对外一律经 nginx。
- 本 skill 的 `deploy.sh`/`apply-ssl.sh` 与 `/new-deploy` skill 是同一份副本，
  改动本 skill 下这两个文件时必须同步 `/new-deploy` 那份并用 `md5sum` 校验一致。
- 如果目标工程的 `CLAUDE.md` 已存在，在其中追加一条说明，指向 `specs/deployment.md`；
  如果不存在，跳过（不自动创建 CLAUDE.md）。
