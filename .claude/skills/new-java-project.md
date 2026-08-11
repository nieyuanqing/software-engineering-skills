---
name: new-java-project
description: 为 Java/Spring Boot 工程生成完整的标准化部署配置：deploy.sh、apply-ssl.sh、nginx vhost（dev/test/prod 三套）、supervisord 配置、env.example、specs/deployment.md。所有产物遵循共享主机部署通用规范（统一目录、健康检查、日志格式、supervisord 安全操作规范）。当用户要求"初始化部署"、"创建部署脚本"、"配置 nginx/supervisor"、"新建 Java 工程部署"时触发。支持 /new-java-project -h 查看帮助。
---

# new-java-project

为新工程生成完整的标准化部署配置，包括部署脚本、nginx vhost、supervisord 配置、环境变量模板和部署规范文档。所有产物严格遵循 `specs/deployment-common.md` 的共享主机部署通用规范，不包含任何硬编码的项目信息。

**触发条件**：用户要求为某工程创建部署配置、部署脚本、nginx/supervisor 配置，或说"初始化部署"。

---

## 零、参数处理

**如果用户传入 `-h` 或 `--help`**，不执行任何文件操作，直接输出以下帮助信息后结束：

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
  --has-web=true|false    是否有前端静态资源（如 --has-web=false）
  --web-path=PATH         前端路径前缀，默认 /web/（如 --web-path=/admin/）
  --api-prefix=PREFIX     API 路径前缀，默认 /api/（如 --api-prefix=/v1/）
  --jdk-version=N         JDK 基线版本，默认 21（如 --jdk-version=21）
  --pg-version=N          PostgreSQL 基线版本，默认 17（如 --pg-version=17）
  -h, --help              显示本帮助

功能
  为 Java/Spring Boot 工程生成完整的标准化部署配置，包括：
    - scripts/deploy.sh                    部署脚本（Maven 构建、supervisord 管理、健康检查、远程部署、nginx 同步）
    - scripts/apply-ssl.sh                 SSL 证书申请脚本（Let's Encrypt + acme.sh）
    - deploy-conf/nginx/vhosts/<name>.dev.conf    nginx vhost（dev 环境，HTTP/IP+端口）
    - deploy-conf/nginx/vhosts/<name>.test.conf   nginx vhost（test 环境，HTTPS/域名）
    - deploy-conf/nginx/vhosts/<name>.prod.conf   nginx vhost（prod 环境，HTTPS/域名）
    - deploy-conf/env.dev             环境变量模板（dev 环境，含 SPRING_PROFILES_ACTIVE=dev）
    - deploy-conf/env.test            环境变量模板（test 环境，含 SPRING_PROFILES_ACTIVE=test）
    - deploy-conf/env.prod            环境变量模板（prod 环境，含 SPRING_PROFILES_ACTIVE=prod）
    - src/backend/<name>/src/main/resources/application.yml          Spring Boot 公共配置（端口、数据源、Actuator 健康检查端点）
    - src/backend/<name>/src/main/resources/application-dev.yml      dev profile（show-sql=true，DEBUG 日志，Swagger 开启）
    - src/backend/<name>/src/main/resources/application-test.yml     test profile（INFO 日志，Swagger 开启）
    - src/backend/<name>/src/main/resources/application-prod.yml     prod profile（WARN 日志，Swagger 关闭）
    - specs/deployment.md                  本工程专属部署规范文档
    - specs/baseline-versions.md           基线版本规范（JDK、PostgreSQL、Spring Boot 等）

  所有产物遵循 specs/deployment-common.md 的跨项目通用规范：
    - 统一目录约定：/opt/soft/apps/<name>/、/data/logs/apps/<name>/
    - 健康检查端点：/api/<name>/health（Spring Boot Actuator，startsecs=10，健康检查最长等待 420s）
    - 部署日志格式：[YYYY-MM-DD HH:MM:SS] [deploy.sh] <message>，阶段日志：Phase N/M
    - supervisord 配置由 deploy.sh 在部署时 inline 生成（不从静态 ini 文件复制）
    - 支持 --remote USER@HOST 远程部署（本地构建，rsync 上传，SSH 远程重启）
    - 后端部署后自动同步 nginx 站点配置；完整 nginx 安装走 --target ssl

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
  在 specs/deployment-common.md 的端口登记表中追加新端口行（如该文件存在）

注意
  - 如目标文件已存在，会展示差异并询问是否覆盖，不会静默覆盖
  - env.example 中的密码保持占位符 changeme，不会写入真实凭证
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
| `--has-web=true\|false` | `HAS_WEB` |
| `--web-path=PATH` | `WEB_PATH`（默认 `/web/`） |
| `--api-prefix=PREFIX` | `API_PATH_PREFIX`（默认 `/api/`） |
| `--jdk-version=N` | `JDK_VERSION`（默认 `21`） |
| `--pg-version=N` | `PG_VERSION`（默认 `17`） |

### 1.2 SERVICE_NAME 确定（优先级从高到低）

1. **命令行位置参数**（如 `/new-java-project my-service`）：直接使用，不再询问。
2. **无位置参数**：读取当前工作目录名，转为小写、空格替换为连字符，作为建议默认值，提示：
   > `SERVICE_NAME 未指定，建议使用当前目录名 "<目录名>" 作为服务名，直接回车确认或输入新名称：`
3. **用户手动输入**：用户输入其他名称则使用输入值。

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
| `HAS_WEB` | 是否有前端静态资源（`true`/`false`） | `false` |
| `WEB_PATH` | 前端路径前缀（`HAS_WEB=true` 时有效） | `/web/` |
| `API_PATH_PREFIX` | nginx 反代 API 路径前缀 | `/api/` |
| `JDK_VERSION` | JDK 基线版本 | `21` |
| `PG_VERSION` | PostgreSQL 基线版本 | `17` |

所有参数确定后，**向用户回显完整参数列表**，确认无误后再生成文件。

---

## 二、生成文件清单

以下文件全部在**目标工程根目录**下生成（即用户当前在操作的工程，不是 software-engineering-skills 仓库本身）。
`deploy-conf/nginx/vhosts/` 之外的 `deploy-conf/nginx/`（`nginx.conf`、`subconf/` 等主机级基础配置）
属于 `/new-nginx-conf` skill，本 skill 不生成、不覆盖：

```
scripts/deploy.sh
scripts/apply-ssl.sh
deploy-conf/nginx/vhosts/<SERVICE_NAME>.dev.conf
deploy-conf/nginx/vhosts/<SERVICE_NAME>.test.conf
deploy-conf/nginx/vhosts/<SERVICE_NAME>.prod.conf
deploy-conf/env.dev
deploy-conf/env.test
deploy-conf/env.prod
src/backend/<SERVICE_NAME>/src/main/resources/application.yml
src/backend/<SERVICE_NAME>/src/main/resources/application-dev.yml
src/backend/<SERVICE_NAME>/src/main/resources/application-test.yml
src/backend/<SERVICE_NAME>/src/main/resources/application-prod.yml
specs/deployment.md
specs/baseline-versions.md
```

---

## 三、生成规则

每个文件的内容来自 `software-engineering-skills` 仓库的对应模板文件，将所有占位符替换为实际参数值。

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
| `<JDK_VERSION>` | `JDK_VERSION` 参数值（默认 `21`） |
| `<PG_VERSION>` | `PG_VERSION` 参数值（默认 `17`） |
| `<CREATE_DATE>` | 当前日期，格式 `YYYY-MM-DD` |

### 各文件来源

| 目标文件 | 模板来源 |
|---|---|
| `scripts/deploy.sh` | `software-engineering-skills/templates/scripts/deploy.sh` |
| `scripts/apply-ssl.sh` | `software-engineering-skills/templates/scripts/apply-ssl.sh` |
| `deploy-conf/nginx/vhosts/<SERVICE_NAME>.dev.conf` | `software-engineering-skills/templates/deploy-conf/nginx/vhosts/service.dev.conf` |
| `deploy-conf/nginx/vhosts/<SERVICE_NAME>.test.conf` | `software-engineering-skills/templates/deploy-conf/nginx/vhosts/service.test.conf` |
| `deploy-conf/nginx/vhosts/<SERVICE_NAME>.prod.conf` | `software-engineering-skills/templates/deploy-conf/nginx/vhosts/service.prod.conf` |
| `deploy-conf/env.dev` | `software-engineering-skills/templates/deploy-conf/env.dev` |
| `deploy-conf/env.test` | `software-engineering-skills/templates/deploy-conf/env.test` |
| `deploy-conf/env.prod` | `software-engineering-skills/templates/deploy-conf/env.prod` |
| `src/backend/<SERVICE_NAME>/src/main/resources/application.yml` | `software-engineering-skills/templates/src/main/resources/application.yml` |
| `src/backend/<SERVICE_NAME>/src/main/resources/application-dev.yml` | `software-engineering-skills/templates/src/main/resources/application-dev.yml` |
| `src/backend/<SERVICE_NAME>/src/main/resources/application-test.yml` | `software-engineering-skills/templates/src/main/resources/application-test.yml` |
| `src/backend/<SERVICE_NAME>/src/main/resources/application-prod.yml` | `software-engineering-skills/templates/src/main/resources/application-prod.yml` |
| `specs/deployment.md` | `software-engineering-skills/specs/deployment-template.md` |
| `specs/baseline-versions.md` | `software-engineering-skills/specs/baseline-versions-template.md` |

### `HAS_WEB=false` 时的处理

如果 `HAS_WEB=false`：
1. 在生成的三份 nginx 配置（dev/test/prod）中删除 `# ── 前端静态资源` 注释块及其下方的整个 `location /web/` 块。
2. 在 `deploy.sh` 的 `parse_deploy_args()` 中把 `DEPLOY_WEB` 的初始值改为 `false`，并在 usage 说明中注明"本服务无前端，--target web 和 --target all 不适用"。

### 自定义 API 路径前缀

如果 `API_PATH_PREFIX` 不是 `/api/`，在三份 nginx 配置的 `location /api/` 块和 `proxy_pass` 行中统一替换为指定路径前缀。

---

## 四、生成后处理

### 设置文件权限

```bash
chmod +x scripts/deploy.sh scripts/apply-ssl.sh
```

### 更新 specs/deployment-common.md 端口登记（如工程中有此文件）

在 `specs/deployment-common.md` 的「端口分配总表」中追加一行：
```
| `<NGINX_PORT>-<APP_PORT>` | <SERVICE_NAME>（见 [deployment.md](./deployment.md) 第三节） |
```

如果工程没有 `specs/deployment-common.md`，跳过此步骤，但告知用户："请在共享主机的端口分配总表（deployment-common.md）中登记这两个端口，防止其他服务端口冲突。"

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

2. 准备数据库（如尚未创建）：
   sudo -u postgres createuser -P <DB_NAME>
   sudo -u postgres createdb -O <DB_NAME> <DB_NAME>

3. 配置 dev 环境变量：
   cp deploy-conf/env.dev src/backend/<SERVICE_NAME>/.env
   vim src/backend/<SERVICE_NAME>/.env   # 填入真实凭证

4. 执行部署：
   bash scripts/deploy.sh

### 首次部署（dev 环境，远程服务器）

1. 配置远程服务器的 dev 环境变量：
   rsync deploy-conf/env.dev root@<HOST>:/tmp/env.dev
   ssh root@<HOST> "cp /tmp/env.dev /path/.env && vim /path/.env"

2. 执行远程部署：
   bash scripts/deploy.sh --remote root@<HOST>

### 首次部署（test/prod 环境）

在对应机器上：
1. 确认域名已解析到这台机器
2. 申请 SSL 证书：bash scripts/apply-ssl.sh test  （或 prod）
3. 配置环境变量：cp deploy-conf/env.test src/backend/<SERVICE_NAME>/.env.test  并填入真实凭证
4. 执行部署：
   bash scripts/deploy.sh --env test --remote root@<HOST>
   bash scripts/deploy.sh --target ssl --env test --remote root@<HOST>
```

---

## 六、注意事项

- **不要修改 `specs/deployment-common.md`** 中的通用规范内容，只更新端口登记表。
- 生成的文件如果目标路径已存在，**先展示差异，询问用户是否覆盖**，不要直接覆盖。
- `deploy-conf/env.*.example` 里的密码值保持占位符 `changeme`，不要填入任何真实凭证。
- **supervisord 配置不再生成静态 ini 文件**：deploy.sh 在部署时 inline 生成 `/etc/supervisor/conf.d/<SERVICE_NAME>.conf`，无需在版本库中维护三份 supervisor ini 文件。
- Spring 环境（dev/test/prod）通过 env 文件中的 `SPRING_PROFILES_ACTIVE` 传递给 JVM，supervisord 命令行不再写死 `--spring.profiles.active`。
- 如果目标工程的 `CLAUDE.md` 已存在，在其中追加一条说明，指向 `specs/deployment.md`；如果不存在，跳过（不自动创建 CLAUDE.md）。
