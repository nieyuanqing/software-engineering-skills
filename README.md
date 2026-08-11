# software-engineering-skills

软件工程 Skill 集合，为 Java/Spring Boot 工程与共享主机 nginx 基础设施提供标准化的配置生成能力。

---

## Skills 列表

| Skill | 说明 |
|:------------------------------------------------------|---|
| <nobr>[`/new-java-project`](#new-java-project)</nobr> | 为 Java/Spring Boot 工程生成完整的标准化部署配置（deploy.sh、nginx vhost、env、Spring Boot yml、specs 文档） |
| <nobr>[`/new-deploy`](#new-deploy)</nobr> | 单独为已有工程生成或更新 `scripts/deploy.sh` 和 `scripts/apply-ssl.sh` |
| <nobr>[`/new-nginx-conf`](#new-nginx-conf)</nobr> | 在当前目录生成标准、通用的 nginx 主机级基础配置 `deploy-conf/nginx/`，不含任何具体项目的定制内容 |
| <nobr>[`/common-rules`](#common-rules)</nobr> | 激活通用行为规范（任务摘要、v0 文档只读保护、禁止硬编码敏感信息） |

逐个 skill 的详细用法见下方对应章节。

---

## 目录结构

```
software-engineering-skills/
├── specs/
│   ├── deployment-common.md           跨项目通用的共享主机部署规范（目录约定、端口登记、
│   │                                  supervisord/nginx 操作安全规范、健康检查强制规则）
│   ├── deployment-template.md         项目专属 specs/deployment.md 的填空模板
│   └── baseline-versions-template.md  项目专属 specs/baseline-versions.md 的填空模板
│                                      （JDK、PostgreSQL、Spring Boot 等基线版本）
├── templates/
│   ├── scripts/
│   │   ├── deploy.sh             部署脚本模板（backend/web/ssl 三个 target；本地/远程部署；
│   │   │                         inline supervisord 配置；nginx 自动同步；Phase N/M 日志；
│   │   │                         [STATUS] 机器可读输出；420s 健康检查；部署摘要）
│   │   └── apply-ssl.sh          SSL 证书申请脚本模板（Let's Encrypt + acme.sh）
│   ├── deploy-conf/
│   │   ├── nginx/                 nginx 配置目录（/new-nginx-conf 与 /new-java-project 共用）
│   │   │   ├── nginx.conf          主配置（/new-nginx-conf 所属，worker/事件/http 层通用参数 + include 链）
│   │   │   ├── mime.types          标准 MIME 类型表（/new-nginx-conf 所属）
│   │   │   ├── subconf/            global/log/ssl/cross_domain/geo/error_pages 六个通用片段（/new-nginx-conf 所属）
│   │   │   ├── upstream/upstream.conf  upstream 扩展点，默认空（/new-nginx-conf 所属）
│   │   │   ├── cert/README.md      说明 SSL 证书应放在这里，不纳入版本管理（/new-nginx-conf 所属）
│   │   │   ├── html/               通用错误页 404/405/500/502/503/504，无项目品牌信息（/new-nginx-conf 所属）
│   │   │   └── vhosts/             各服务 vhost 配置目录
│   │   │       ├── README.md         说明本目录用途（/new-nginx-conf 所属，只落地一次）
│   │   │       ├── service.dev.conf  nginx vhost 模板（/new-java-project 所属，dev 环境，HTTP/IP+端口）
│   │   │       ├── service.test.conf nginx vhost 模板（/new-java-project 所属，test 环境，HTTPS/域名）
│   │   │       └── service.prod.conf nginx vhost 模板（/new-java-project 所属，prod 环境，HTTPS/域名）
│   │   ├── supervisor/             （参考模板，不再由 skill 生成；supervisord 配置现由 deploy.sh 在部署时 inline 生成）
│   │   │   ├── service.dev.ini
│   │   │   ├── service.test.ini
│   │   │   └── service.prod.ini
│   │   ├── env.dev.example       环境变量模板（dev，含 SPRING_PROFILES_ACTIVE=dev）
│   │   ├── env.test.example      环境变量模板（test，含 SPRING_PROFILES_ACTIVE=test）
│   │   └── env.prod.example      环境变量模板（prod，含 SPRING_PROFILES_ACTIVE=prod）
│   └── src/main/resources/
│       ├── application.yml       Spring Boot 公共配置（端口、数据源、Actuator 健康检查端点）
│       ├── application-dev.yml   dev profile（show-sql=true，DEBUG 日志，Swagger 开启）
│       ├── application-test.yml  test profile（INFO 日志，Swagger 开启）
│       └── application-prod.yml  prod profile（WARN 日志，Swagger 关闭）
└── .claude/
    └── skills/
        ├── new-java-project.md   Claude Code skill 定义（为 Java/Spring Boot 工程生成完整部署配置）
        ├── new-deploy.md         Claude Code skill 定义（单独生成/更新 deploy.sh 和 apply-ssl.sh）
        ├── new-nginx-conf.md     Claude Code skill 定义（生成标准通用的 nginx 主配置目录）
        └── common-rules.md       Claude Code skill 定义（通用行为规范：任务摘要、v0 文档保护、禁止硬编码）
```

---

## 已安装的 Skills

### `/new-java-project`

为 Java/Spring Boot 工程一键生成完整的标准化部署配置。

**用法**

```bash
/new-java-project                          # 交互式向导，以当前目录名为默认服务名
/new-java-project my-service               # 直接指定服务名
/new-java-project my-service \
  --nginx-port=50000 --app-port=50001 \
  --db-port=5432 --db-name=my-service \
  --test-domain=svc.test.example.com \
  --prod-domain=svc.example.com \
  --has-web=false                          # 全参数指定，无需交互
/new-java-project -h                       # 查看帮助
```

**生成产物**

| 文件 | 说明 |
|---|---|
| `scripts/deploy.sh` | 部署脚本（见下方"deploy.sh 能力"） |
| `scripts/apply-ssl.sh` | SSL 证书申请（Let's Encrypt + acme.sh，HTTP-01 webroot 验证） |
| `deploy-conf/nginx/vhosts/<name>.dev.conf` | nginx vhost — dev 环境（HTTP，无域名） |
| `deploy-conf/nginx/vhosts/<name>.test.conf` | nginx vhost — test 环境（HTTPS，绑定测试域名） |
| `deploy-conf/nginx/vhosts/<name>.prod.conf` | nginx vhost — prod 环境（HTTPS，绑定生产域名） |
| `deploy-conf/env.{dev,test,prod}.example` | 环境变量模板三套（含 `SPRING_PROFILES_ACTIVE`，复制为 `.env` 后填入真实值） |
| `src/backend/<name>/src/main/resources/application.yml` | Spring Boot 公共配置（端口、数据源、Actuator 健康检查端点） |
| `src/backend/<name>/src/main/resources/application-{dev,test,prod}.yml` | Spring Boot profile 配置三套（日志级别、SQL 调试、Swagger 开关） |
| `specs/deployment.md` | 本工程专属部署规范文档 |
| `specs/baseline-versions.md` | 基线版本规范（JDK、PostgreSQL、Spring Boot 等） |

**deploy.sh 能力**（见下方 [`/new-deploy`](#new-deploy) 节的详细说明）：
- `-t/--target all|backend|web|ssl`，`-e/--env dev|test|prod`
- `-r/--remote USER@HOST` 远程部署（本地构建，rsync 上传，SSH 重启）
- `--target ssl` 安装 nginx（apt）+ SSL 证书配置
- supervisord 配置在部署时 inline 生成，Spring 环境通过 `.env` 中的 `SPRING_PROFILES_ACTIVE` 传递
- Phase N/M 阶段日志，`[STATUS] OK/ERROR` 机器可读输出，420s 健康检查

**所有产物遵循的通用规范**（见 `specs/deployment-common.md`）：
- 目录约定：`/opt/soft/apps/<name>/`、`/data/logs/apps/<name>/`
- 健康检查端点：`/api/<name>/health`（Spring Boot Actuator，`startsecs=10`，最长等待 420s）
- 部署日志格式：`[YYYY-MM-DD HH:MM:SS] [deploy.sh] ...`，阶段编号：`Phase N/M`
- 共享主机安全规范：不自动 `systemctl start supervisor`，不随意改动其他项目配置

---

### `/new-deploy`

单独为已有工程生成或更新 `scripts/deploy.sh` 和 `scripts/apply-ssl.sh`。适用于只需要更新部署脚本、不需要重新生成完整配置套件的场景。

**用法**

```bash
/new-deploy                                # 交互式，以当前目录名为默认服务名
/new-deploy my-service                     # 直接指定服务名
/new-deploy my-service \
  --app-port=8080 --nginx-port=9090 \
  --test-domain=svc.test.example.com \
  --prod-domain=svc.example.com \
  --has-web=false                          # 全参数指定，无需交互
/new-deploy -h                             # 查看帮助
```

**生成产物**

| 文件 | 说明 |
|---|---|
| `scripts/deploy.sh` | 部署脚本 |
| `scripts/apply-ssl.sh` | SSL 证书申请脚本（deploy.sh 初始化目录时一并上传到服务器） |

**deploy.sh 主要能力**

| 能力 | 说明 |
|---|---|
| `--target all\|backend\|web\|ssl` | 部署目标（`-t` 简写） |
| `--env dev\|test\|prod` | 目标环境（`-e` 简写），默认 `dev` |
| `--remote USER@HOST` | 远程部署（`-r` 简写）：本地 Maven 构建，rsync 上传 JAR，SSH 远程重启 |
| `--target ssl` | 完整 nginx 安装（apt）+ 主配置 + 站点配置；仅支持 `test\|prod` |
| 自动 nginx 同步 | backend 部署后自动同步站点配置并 reload（目标已装 nginx 时） |
| inline supervisord 配置 | 部署时写入 `/etc/supervisor/conf.d/<name>.conf`，不依赖静态 ini 文件 |
| env 文件按环境选择 | 自动选取 `.env` / `.env.test` / `.env.prod`（来自 `src/backend/<name>/`） |
| Phase N/M 日志 | 编号阶段日志，`[STATUS] OK/ERROR` 机器可读输出行 |
| 健康检查 | `http://127.0.0.1:<APP_PORT>/api/<name>/health`，最长等待 420s |
| 版本化 JAR + 软链接 | `<name>-<version>.jar` + `<name>.jar` 软链接，支持手动回滚 |
| 部署摘要 | 自动探测公网 IP，输出三套环境的访问地址和产物位置 |

---

### `/new-nginx-conf`

在当前目录生成标准、通用的 nginx 主机级基础配置到 `deploy-conf/nginx/`，内容取自本仓库的
`templates/deploy-conf/nginx/`——该模板从一台已在生产环境跑过的主机的 `/opt/soft/nginx/conf`
提炼而来，已剔除该主机上所有具体项目的定制内容（项目域名、证书私钥、专属业务请求头、专属 API
门户页面等）。

`deploy-conf/nginx/` 这棵目录树由 `/new-nginx-conf` 与 `/new-java-project` 共同拥有，但各自只处理
自己负责的文件：`/new-nginx-conf` 生成主机级的 nginx 本身（`nginx.conf`、`subconf/`、`upstream/`、
`cert/README.md`、`html/`、`vhosts/README.md`），一台主机通常只需要执行一次；`/new-java-project`
生成单个服务的 vhost 片段（`vhosts/<name>.{dev,test,prod}.conf`），每接入一个新服务执行一次。两者
互不覆盖对方的产物。

**用法**

```bash
/new-nginx-conf       # 在当前目录生成 deploy-conf/nginx/
/new-nginx-conf -h    # 查看帮助
```

**生成产物**

| 文件 | 说明 |
|---|---|
| `deploy-conf/nginx/nginx.conf` | 主配置（worker/事件/http 层通用参数 + include 链） |
| `deploy-conf/nginx/mime.types` | 标准 MIME 类型表 |
| `deploy-conf/nginx/subconf/log.conf` | 通用访问日志格式，不含任何项目专属请求头字段 |
| `deploy-conf/nginx/subconf/ssl.conf` | 通用 SSL 参数（ciphers/协议/session 缓存），证书路径为占位符 `<DOMAIN>` |
| `deploy-conf/nginx/subconf/cross_domain.conf` | 通用 CORS 片段，不含项目专属请求头 |
| `deploy-conf/nginx/subconf/{global,geo,error_pages}.conf` | 扩展点 / IP 名单 / 统一错误页映射 |
| `deploy-conf/nginx/upstream/upstream.conf` | upstream 扩展点（默认空，按需声明负载均衡组） |
| `deploy-conf/nginx/vhosts/README.md` | 说明各服务 vhost 配置放在这里（`<name>.*.conf` 由 `/new-java-project` 生成） |
| `deploy-conf/nginx/cert/README.md` | 说明 SSL 证书应放在这里（不纳入版本管理） |
| `deploy-conf/nginx/html/{404,405,500,502,503,504}.html` | 通用错误页，无项目品牌信息 |

**注意**：本 skill 只生成配置文件，不会自动安装 nginx、不会执行 `nginx -t` / `nginx -s reload`——
是否覆盖主机上现有的 `/opt/soft/nginx/conf` 需要用户自行确认后操作（见
`specs/deployment-common.md` 第三节共享基础设施操作规范）。

---

### `/common-rules`

通用行为规范，调用后对当前会话的所有任务生效：

- **任务摘要**：每次任务完成后输出结果清单、影响范围（新增/修改/删除文件）、开始和结束时间
- **v0 文档保护**：禁止修改路径或文件名含 `v0` 的原始产品设计文档，只读
- **禁止硬编码**：密码、密钥、Token 等敏感信息必须通过环境变量或占位符处理

**用法**

```bash
/common-rules    # 激活通用规范，对后续所有任务生效
```

---

## 安装

在新机器上克隆仓库后安装所有 skills：

```bash
git clone https://github.com/nieyuanqing/software-engineering-skills.git ~/software-engineering-skills

# /new-java-project
mkdir -p ~/.claude/skills/new-java-project
ln -sf ~/software-engineering-skills/.claude/skills/new-java-project.md \
       ~/.claude/skills/new-java-project/SKILL.md

# /new-deploy
mkdir -p ~/.claude/skills/new-deploy
ln -sf ~/software-engineering-skills/.claude/skills/new-deploy.md \
       ~/.claude/skills/new-deploy/SKILL.md

# /new-nginx-conf
mkdir -p ~/.claude/skills/new-nginx-conf
ln -sf ~/software-engineering-skills/.claude/skills/new-nginx-conf.md \
       ~/.claude/skills/new-nginx-conf/SKILL.md

# /common-rules
mkdir -p ~/.claude/skills/common-rules
ln -sf ~/software-engineering-skills/.claude/skills/common-rules.md \
       ~/.claude/skills/common-rules/SKILL.md
```
