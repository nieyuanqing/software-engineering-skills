# 外部框架与依赖基线版本

> 定位：锁定本工程各层实现所依赖的外部框架/运行时基线版本，保证团队协作与环境的一致性、可复现性。
> 变更方式：基线版本变更需团队评审后更新本文档，禁止各模块自行选择版本。

---

## 一、基线版本管理原则

- 本文档定义的是**下限基线**（Minimum Baseline），即允许使用的最低版本；具体锁定的精确版本号在各模块的依赖锁定文件中维护（如 Maven 父 POM 的 `<dependencyManagement>`）
- 升级基线版本需评估兼容性影响，走第五节的升级流程，不允许个人开发环境单方面使用低于基线的版本
- 新增外部框架依赖前，先在本文档登记基线版本要求，再引入代码库

---

## 二、后端（`src/backend`）

| 依赖 | 基线版本 | 说明 |
|---|---|---|
| Java | ≥ <JDK_VERSION>（LTS） | 启用虚拟线程等现代特性 |
| Spring Boot | ≥ 3.x | 应用框架，对外 API 层、依赖注入、配置管理的基础 |
| Spring Data JPA | ≥ 3.x | 数据访问层，配合 PostgreSQL 使用 |
| Spring Boot Actuator | ≥ 3.x | 依赖连通性深检走默认 `/actuator/health`（`show-details=never`，只对本机）；规范要求的健康检查端点 `/api/<SERVICE_NAME>/health` 由 `config/RootController.java` 提供，不用 `management.endpoints.web.base-path` 改写 Actuator 路径；对外只暴露 `health,info` |
| Flyway | 最新稳定版 | **schema 迁移的唯一机制**：脚本放 `src/main/resources/db/migration/V<n>__*.sql`，
  随 jar 打包、应用启动时自动迁移（`spring.flyway.enabled: ${FLYWAY_ENABLED:true}`），版本记账在目标库的
  `flyway_schema_history`。禁止用 Hibernate 自动建表替代（`ddl-auto` 只允许 `validate`）。\n  **必须在 pom 显式声明** `org.flywaydb:flyway-core`（PostgreSQL 另加 `flyway-database-postgresql`）：\n  starter-data-jpa 不带 Flyway，缺依赖时 `spring.flyway.*` 被静默忽略、一次迁移都不跑 |
| Maven | 最新稳定版 | 依赖与构建管理 |

> 具体次版本号变化较快，以父 POM 中锁定的实际版本为准，本表仅约束下限。

---

## 三、数据层

| 依赖 | 基线版本 | 说明 |
|---|---|---|
| PostgreSQL | <PG_VERSION> | 主数据存储 |

**约束**：
- 数据库名、角色名与服务名保持一致：`<SERVICE_NAME>` / `<SERVICE_NAME>`
- Schema 变更一律写成 `src/main/resources/db/migration/V<n>__<主题>.sql`，由 Flyway 在应用启动时迁移，
  进度以目标库的 `flyway_schema_history` 为唯一记账；已应用过的脚本不得改动（Flyway 校验会拒绝启动），
  要修就新开一个 V 文件；禁止手工建表，也禁止 Hibernate `ddl-auto=create/update`
  （`validate` 是运行前置检查，不是建表手段）
- 临时查询与数据订正走 `scripts/db-sql.sh`（默认只读、写要 `--apply`），它不承担结构变更
- 三套环境变量文件 `src/backend/<SERVICE_NAME>/.env`、`.env.test`、`.env.prod` 键集必须一致，
  全部不入库；生产凭证只存在于目标机器的 `/opt/soft/apps/<SERVICE_NAME>/.env`

---

## 四、部署端口约定

| 用途 | 端口 | 说明 |
|---|---|---|
| nginx 对外反向代理 | `<NGINX_PORT>` | 唯一对外入口，见 `deploy-conf/nginx/<SERVICE_NAME>.*.conf` |
| Spring Boot 应用内部监听 | `<APP_PORT>` | 只绑定 `127.0.0.1`，不直接对外暴露，必须经 nginx 访问（见 `application.yml` 的 `server.address`） |

这两个端口是固定值，变更需先确认目标机器端口占用情况，走第五节升级流程更新本表，不允许部署时临时改动而不回写文档。

---

## 五、基线版本升级流程

1. 提出方说明升级理由（安全漏洞、关键特性依赖、官方停止维护旧版本等）
2. 评估对现有代码的兼容性影响，必要时在隔离分支验证
3. 团队评审通过后更新本文档对应条目，并同步更新各模块的依赖锁定文件
4. 升级记录（版本、日期、原因）追加在下方变更记录中

---

## 变更记录

| 日期 | 变更内容 | 说明 |
|---|---|---|
| <CREATE_DATE> | 初始建立基线：Java <JDK_VERSION>、PostgreSQL <PG_VERSION>、Spring Boot 3.x | v1.0 |
