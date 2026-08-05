# software-engineering-skills

软件工程 Skill 集合，为 Java/Spring Boot 工程提供标准化的部署配置生成能力。

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
│   │   ├── nginx/
│   │   │   ├── service.dev.conf  nginx vhost 模板（dev 环境，HTTP/IP+端口）
│   │   │   ├── service.test.conf nginx vhost 模板（test 环境，HTTPS/域名）
│   │   │   └── service.prod.conf nginx vhost 模板（prod 环境，HTTPS/域名）
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
        └── new-java-project.md   Claude Code skill 定义
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
| `deploy-conf/nginx/<name>.dev.conf` | nginx vhost — dev 环境（HTTP，无域名） |
| `deploy-conf/nginx/<name>.test.conf` | nginx vhost — test 环境（HTTPS，绑定测试域名） |
| `deploy-conf/nginx/<name>.prod.conf` | nginx vhost — prod 环境（HTTPS，绑定生产域名） |
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

---

## 安装

在新机器上克隆仓库后安装：

```bash
git clone https://github.com/nieyuanqing/software-engineering-skills.git ~/software-engineering-skills
mkdir -p ~/.claude/skills/new-java-project
ln -sf ~/software-engineering-skills/.claude/skills/new-java-project.md \
       ~/.claude/skills/new-java-project/SKILL.md
```
