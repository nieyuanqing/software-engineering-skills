---
name: new-deploy
description: 为 Java/Spring Boot 工程生成 scripts/deploy.sh 和 scripts/apply-ssl.sh。deploy.sh 支持本地/远程部署（--remote）、三套环境（dev/test/prod）、backend/web/ssl 目标、inline supervisord 配置、nginx 自动同步、numbered phase 日志、[STATUS] 机器可读输出。当用户要求"生成部署脚本"、"更新 deploy.sh"、"初始化 deploy"时触发。支持 /new-deploy -h 查看帮助。
---

# new-deploy

为工程生成标准化的 `scripts/deploy.sh` 和 `scripts/apply-ssl.sh`。

**触发条件**：用户要求为某工程创建或更新部署脚本（deploy.sh），或单独需要部署脚本而不需要完整的 `/new-java-project` 配置套件。

---

## 零、参数处理

**如果用户传入 `-h` 或 `--help`**，不执行任何文件操作，直接输出以下帮助信息后结束：

---

```
用法: /new-deploy [SERVICE_NAME] [选项]

  SERVICE_NAME    可选位置参数，直接指定服务名。
                  不传时提示采用当前目录名称作为默认值。

选项（通过命令行传入的参数直接使用，不再交互询问）
  --app-port=N            Spring Boot 内部端口（如 --app-port=50001）
  --nginx-port=N          nginx 对外监听端口（如 --nginx-port=50000）
  --test-domain=DOMAIN    test 环境域名（如 --test-domain=svc.test.example.com）
  --prod-domain=DOMAIN    prod 环境域名（如 --prod-domain=svc.example.com）
  --has-web=true|false    是否有前端静态资源，影响 deploy.sh 默认 target（默认 false）
  -h, --help              显示本帮助

生成文件
  scripts/deploy.sh       部署脚本（Maven 构建、supervisord 管理、健康检查、远程部署、nginx 同步）
  scripts/apply-ssl.sh    SSL 证书申请脚本（Let's Encrypt + acme.sh），deploy.sh 初始化目录时一并上传

deploy.sh 主要能力
  目标: -t/--target all|backend|web|ssl（默认 all；--has-web=false 时默认 backend）
  环境: -e/--env dev|test|prod（默认 dev）
  远程: -r/--remote USER@HOST（本地 Maven 构建，rsync 上传 JAR，SSH 远程重启）
  ssl:  --target ssl --env test|prod 安装 nginx（apt）+ 主配置 + 站点配置
  健康检查: http://127.0.0.1:<APP_PORT>/api/<SERVICE_NAME>/health，最长等待 420s
  supervisord 配置: 部署时 inline 生成，不依赖静态 ini 文件
  env 文件: 按环境选择 .env / .env.test / .env.prod（来自 src/backend/<SERVICE_NAME>/）
  日志格式: [YYYY-MM-DD HH:MM:SS] [deploy.sh] ... + Phase N/M 阶段编号
  状态输出: [STATUS] OK / [STATUS] ERROR 机器可读行

示例
  /new-deploy
      交互式，以当前目录名为默认服务名

  /new-deploy my-service --app-port=8080 --nginx-port=9090
      指定服务名和端口，其余交互询问

  /new-deploy my-service --app-port=8080 --nginx-port=9090 \
      --test-domain=svc.test.example.com --prod-domain=svc.example.com
      全参数命令行指定，直接生成

  /new-deploy -h
      显示本帮助
```

---

## 一、收集参数

### 1.1 解析命令行参数

| 命令行写法 | 对应参数 |
|---|---|
| 第一个非 `--`/`-` 开头的词 | `SERVICE_NAME` |
| `--app-port=N` | `APP_PORT` |
| `--nginx-port=N` | `NGINX_PORT` |
| `--test-domain=DOMAIN` | `TEST_DOMAIN` |
| `--prod-domain=DOMAIN` | `PROD_DOMAIN` |
| `--has-web=true\|false` | `HAS_WEB`（默认 `false`） |

### 1.2 SERVICE_NAME 确定（优先级从高到低）

1. **命令行位置参数**：直接使用，不再询问。
2. **无位置参数**：读取当前工作目录名，转为小写、空格替换为连字符，作为建议默认值，提示：
   > `SERVICE_NAME 未指定，建议使用当前目录名 "<目录名>" 作为服务名，直接回车确认或输入新名称：`

### 1.3 交互询问缺失参数

`SERVICE_NAME` 确定后，**将所有未通过命令行提供的必填参数一次性列出**，统一询问：

| 参数 | 说明 | 默认值 |
|---|---|---|
| `APP_PORT` | Spring Boot 内部端口（只绑 127.0.0.1） | 无 |
| `NGINX_PORT` | nginx 对外监听端口 | 无 |
| `TEST_DOMAIN` | test 环境域名 | 无 |
| `PROD_DOMAIN` | prod 环境域名 | 无 |
| `HAS_WEB` | 是否有前端静态资源（`true`/`false`） | `false` |

所有参数确定后，**向用户回显完整参数列表**，确认无误后再生成文件。

---

## 二、生成文件清单

以下文件全部在**目标工程根目录**下生成：

```
scripts/deploy.sh
scripts/apply-ssl.sh
```

---

## 三、生成规则

### 模板来源

| 目标文件 | 模板来源 |
|---|---|
| `scripts/deploy.sh` | `software-engineering-skills/templates/scripts/deploy.sh` |
| `scripts/apply-ssl.sh` | `software-engineering-skills/templates/scripts/apply-ssl.sh` |

### 占位符替换表

| 占位符 | 替换为 |
|---|---|
| `<SERVICE_NAME>` | `SERVICE_NAME` 参数值 |
| `<APP_PORT>` | `APP_PORT` 参数值 |
| `<NGINX_PORT>` | `NGINX_PORT` 参数值 |
| `<TEST_DOMAIN>` | `TEST_DOMAIN` 参数值 |
| `<PROD_DOMAIN>` | `PROD_DOMAIN` 参数值 |

### `HAS_WEB=false` 时的处理

在生成的 `deploy.sh` 中，将 `parse_deploy_args()` 里 `DEPLOY_WEB` 的初始值从 `true` 改为 `false`，并在 `usage()` 的目标说明处注明"本服务无前端，--target web 和 --target all 不适用"。

---

## 四、生成后处理

```bash
chmod +x scripts/deploy.sh scripts/apply-ssl.sh
```

---

## 五、完成提示

生成完成后，向用户输出以下内容：

1. **已生成文件列表**（逐行列出路径）
2. **下一步操作**（用实际参数值填入，不要复制粘贴占位符）：

```
## 下一步操作

### 首次部署（dev 环境，本机）

1. 确认 supervisord daemon 正在运行，且端口 <NGINX_PORT>/<APP_PORT> 空闲：
   supervisorctl status
   ss -tln | grep -E ':(<NGINX_PORT>|<APP_PORT>)\b'

2. 配置 dev 环境变量（deploy.sh 从 src/backend/<SERVICE_NAME>/.env 读取）：
   cp deploy-conf/env.dev src/backend/<SERVICE_NAME>/.env
   vim src/backend/<SERVICE_NAME>/.env

3. 执行部署：
   bash scripts/deploy.sh

### 首次部署（远程服务器）

   bash scripts/deploy.sh --remote root@<HOST>

### test / prod 环境

   # 先申请证书
   bash scripts/apply-ssl.sh test   # 或 prod
   # 部署（本机或远程）
   bash scripts/deploy.sh --env test --remote root@<HOST>
   bash scripts/deploy.sh --target ssl --env test --remote root@<HOST>
```

---

## 六、注意事项

- 生成的文件如果目标路径已存在，**先展示差异，询问用户是否覆盖**，不要直接覆盖。
- deploy.sh 要求在**项目根目录**执行（`bash scripts/deploy.sh`），脚本内部会校验 `pwd` 是否等于 `$PROJECT_DIR`。
- supervisord 配置由 deploy.sh 在部署时 inline 生成到 `/etc/supervisor/conf.d/<SERVICE_NAME>.conf`，无需在版本库中维护静态 ini 文件。
- Spring 环境（dev/test/prod）通过 env 文件中的 `SPRING_PROFILES_ACTIVE` 传递，deploy.sh 不硬编码 `--spring.profiles.active`。
- nginx 路径约定：`/etc/nginx/conf.d/<SERVICE_NAME>.conf`，SSL 证书放在 `/etc/nginx/ssl/<DOMAIN>.pem`。
