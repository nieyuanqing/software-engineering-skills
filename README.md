# software-engineering-skills

软件工程 Skill 集合，为 Java/Spring Boot 工程与共享主机 nginx 基础设施提供标准化的配置生成能力。

---

## Skills 列表

| Skill | 说明 |
|---|---|
| [`/new-java-project`](#new-java-project) | 为 Java/Spring Boot 工程生成完整的标准化部署配置（deploy.sh、nginx vhost、supervisord、env、specs 文档） |
| [`/new-nginx-conf`](#new-nginx-conf) | 在当前目录生成标准、通用的 nginx 主机级基础配置 `deploy-conf/nginx/`，不含任何具体项目的定制内容 |
| [`/common-rules`](#common-rules) | 激活通用行为规范（任务摘要、v0 文档只读保护、禁止硬编码敏感信息） |

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
│   │   ├── deploy.sh             部署脚本模板（backend/web/all 三个 target，含健康检查）
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
│   │   ├── supervisor/
│   │   │   ├── service.dev.ini   supervisord 程序配置模板（dev，--spring.profiles.active=dev）
│   │   │   ├── service.test.ini  supervisord 程序配置模板（test）
│   │   │   └── service.prod.ini  supervisord 程序配置模板（prod）
│   │   ├── env.dev.example       环境变量模板（dev，JWT 可用占位符）
│   │   ├── env.test.example      环境变量模板（test，建议随机 JWT）
│   │   └── env.prod.example      环境变量模板（prod，JWT 必须真实值）
│   └── src/main/resources/
│       ├── application.yml       Spring Boot 公共配置（端口、数据源、Actuator 健康检查端点）
│       ├── application-dev.yml   dev profile（show-sql=true，DEBUG 日志，Swagger 开启）
│       ├── application-test.yml  test profile（INFO 日志，Swagger 开启）
│       └── application-prod.yml  prod profile（WARN 日志，Swagger 关闭）
└── .claude/
    └── skills/
        ├── new-java-project.md   Claude Code skill 定义（为 Java/Spring Boot 工程生成部署配置）
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
| `scripts/deploy.sh` | 部署脚本（构建 jar、supervisord 管理、健康检查轮询、nginx 安装） |
| `scripts/apply-ssl.sh` | SSL 证书申请（Let's Encrypt + acme.sh，HTTP-01 webroot 验证） |
| `deploy-conf/nginx/vhosts/<name>.dev.conf` | nginx vhost — dev 环境（HTTP，无域名） |
| `deploy-conf/nginx/vhosts/<name>.test.conf` | nginx vhost — test 环境（HTTPS，绑定测试域名） |
| `deploy-conf/nginx/vhosts/<name>.prod.conf` | nginx vhost — prod 环境（HTTPS，绑定生产域名） |
| `deploy-conf/supervisor/<name>.{dev,test,prod}.ini` | supervisord 程序配置三套（`--spring.profiles.active` 各自对应环境） |
| `deploy-conf/env.{dev,test,prod}.example` | 环境变量模板三套（JWT 要求强度依次递增），复制为 `.env` 后填入真实值 |
| `src/backend/<name>/src/main/resources/application.yml` | Spring Boot 公共配置（端口、数据源、Actuator 健康检查端点） |
| `src/backend/<name>/src/main/resources/application-{dev,test,prod}.yml` | Spring Boot profile 配置三套（日志级别、SQL 调试、Swagger 开关） |
| `specs/deployment.md` | 本工程专属部署规范文档 |
| `specs/baseline-versions.md` | 基线版本规范（JDK、PostgreSQL、Spring Boot 等） |

**所有产物遵循的通用规范**（见 `specs/deployment-common.md`）：
- 目录约定：`/opt/soft/apps/<name>/`、`/data/logs/apps/<name>/`
- 健康检查端点：`/api/<name>/health`（Spring Boot Actuator，`startsecs=3`）
- 部署日志格式：`[YYYY-MM-DD HH:MM:SS] ===== <模块名> =====`
- 共享主机安全规范：不自动 `systemctl start supervisor`，不随意改动其他项目配置

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

# /new-nginx-conf
mkdir -p ~/.claude/skills/new-nginx-conf
ln -sf ~/software-engineering-skills/.claude/skills/new-nginx-conf.md \
       ~/.claude/skills/new-nginx-conf/SKILL.md

# /common-rules
mkdir -p ~/.claude/skills/common-rules
ln -sf ~/software-engineering-skills/.claude/skills/common-rules.md \
       ~/.claude/skills/common-rules/SKILL.md
```
