---
name: common-rules
description: 通用行为规范，适用于所有任务：每次任务完成后输出中文结果清单、影响范围（含数据库变更维度）和开始/结束时间（摘要必须采用中文）；禁止修改工程根目录 v0/ 下的原始产品设计文档（只读，src/web/v0 代码目录除外）；禁止在代码、配置、脚本中硬编码任何敏感信息；git commit message 必须使用结构化格式；CORS 必须在 nginx 配置中实现，禁止在 Java 后端处理；dev/test/prod 三套配置文件（env、nginx、application）的配置项必须保持自动对齐。
---

# common-rules

**如果用户传入 `-h` 或 `--help`**，不激活任何规范，直接输出以下帮助信息后结束：

---

```
用法: /common-rules [-h]

功能
  激活通用行为规范，对当前会话的所有后续任务生效。
  包含以下六条强制规范，不受其他指令覆盖，不可被单次要求临时豁免：
  全局时间规范：所有时间一律按东八区（UTC+8，Asia/Shanghai）处理，
  默认格式 YYYY-MM-DD HH:MM:SS（如 2026-08-29 14:30:05）；适用于任务摘要、
  产物文件（测试报告、用例元信息、日志、SQL 注释等）中的全部时间字段。

规范一：任务完成后输出摘要
  每次涉及文件操作或系统变更的任务完成后，自动输出：
    - 开始时间：YYYY-MM-DD HH:MM:SS / 结束时间：YYYY-MM-DD HH:MM:SS / 消耗时间：?秒
    - 任务结果：逐条列出本次完成的操作
    - 影响范围：新增 / 修改 / 删除的文件、数据库变更（表结构与数据订正，无则写"无"）、
      需人工跟进事项
  摘要内容必须采用中文输出。
  纯对话 / 查询类请求不输出摘要。

规范二：v0 原始产品设计文档只读保护
  v0 指的是工程根目录下的 v0/ 目录，存放产品提交的原始设计文档。
  注意：src/web/v0/ 是 AI 生成的代码目录，不属于保护范围，可以正常修改。
  识别条件（满足任意一条即视为 v0 文档）：
    - 位于工程根目录下的 v0/ 目录（含 design/v0/、docs/v0/ 等设计文档路径）
    - 文件名含 v0（如 product-v0.md、spec-v0.pdf）
    - 文件内部标注了"v0"、"原始设计"、"初稿"等字样
  例外：src/web/v0/ 下的代码文件不受本规范约束。
  约束：
    - 允许：读取、引用、基于内容提建议
    - 禁止：任何写入、修改、格式调整、追加注释
    - 若任务要求修改 v0 文档，必须拒绝并建议新建版本文件（如 product-v1.md）

规范三：禁止硬编码敏感信息
  禁止在代码、配置、脚本、文档、提交记录中出现明文形式的：
    - 密码（数据库密码、系统账户密码等）
    - 密钥 / Token / Secret（JWT Secret、API Key、Access Token、Private Key）
    - 含凭证的内网连接字符串
  正确做法：
    - 运行时配置使用环境变量：${DB_PASSWORD}、${JWT_SECRET}
    - 模板 / 示例文件使用语义占位符：changeme、<YOUR_API_KEY>
    - 发现存量硬编码时立即告知用户，不继续扩展，建议替换为环境变量

规范四：git commit message 结构化格式
  每次 git 提交前，必须按以下结构组织 commit message，禁止使用无意义的单行描述：

  <类型>: <简短描述>（不超过 72 字符）

  [可选正文：说明做了什么、为什么这样做，每行不超过 72 字符]

  类型取值：
    feat     新功能
    fix      Bug 修复
    refactor 重构（不新增功能、不修复 Bug）
    docs     文档变更
    style    格式调整（不影响逻辑）
    test     测试相关
    chore    构建/工具/依赖等杂项

  示例（正确）：
    feat: 新增 /new-deploy skill，单独生成 deploy.sh
    fix: 修正 nginx SSL 证书路径，改为 /etc/nginx/ssl/
    docs: 更新 README，补充 deploy.sh 能力说明

  示例（禁止）：
    update
    fix bug
    修改了一些东西

规范五：CORS 在 nginx 配置中实现
  禁止在 Java 后端（Spring Boot / Filter / WebMvcConfigurer / @CrossOrigin 等）处理跨域。
  CORS 响应头统一由 nginx 配置写入，后端不感知跨域逻辑。
  若发现已有后端 CORS 代码，立即告知用户，建议迁移到 nginx，不在后端继续扩展。

规范六：dev / test / prod 三套配置文件自动对齐
  三类按环境成对维护的配置文件必须保持配置项集合对齐：
    - env：deploy-conf/env.dev|test|prod、src/backend/<服务名>/.env|.env.test|.env.prod
    - nginx：deploy-conf/nginx/vhosts/<服务名>.dev|test|prod.conf
    - 应用配置：src/main/resources/application-dev|-test|-prod.yml
  要求：
    - 新增 / 删除 / 更名配置项：三套环境文件同步变更，禁止只改其中一套
    - 三套文件只允许值不同（域名、证书、日志级别等环境差异），
      结构性配置块（location 块、数据源、健康检查等）不允许只存在于单一环境
    - 发现存量不对齐时立即告知用户，并一次性补齐对齐

示例
  /common-rules         激活规范，对后续所有任务生效
  /common-rules -h      显示本帮助
```

---

以下规范对**所有任务**生效，不受其他指令覆盖，不可被用户单次要求临时豁免。

**全局时间规范**：所有时间一律按**东八区（UTC+8，Asia/Shanghai）**处理，默认格式 **`YYYY-MM-DD HH:MM:SS`**（如 `2026-08-29 14:30:05`）。适用于任务摘要的开始/结束时间，以及所有产物文件（测试报告、用例元信息、日志、SQL 注释等）中的时间字段；取值时统一用 `TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S'`，不受本机时区影响。

---

## 一、任务时间记录与结果摘要

**开始任务时**：用 Bash 工具执行 `TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S'` 记录开始时间（同时记录秒级时间戳用于计算消耗时间）。

**任务完成后**：再次执行 `TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S'` 记录结束时间，计算消耗秒数，然后输出以下摘要（时间一律为东八区）：

```
## 任务摘要

开始时间：YYYY-MM-DD HH:MM:SS　结束时间：YYYY-MM-DD HH:MM:SS　消耗时间：?秒

### 任务结果
- （逐条列出本次完成的操作，一条一行，使用动词开头，如"新增 / 修改 / 删除 / 配置"）

### 影响范围
- 新增文件：（逐条列出）
- 修改文件：（逐条列出）
- 删除文件：（逐条列出，如无则省略该行）
- 数据库变更：（逐条列出表结构变更（新增/修改/删除表、字段、索引）与数据订正，
  附对应 SQL 文件或执行方式；无变更则写"无"）
- 需人工跟进：（如需重启服务、重新安装依赖、更新环境变量、手动执行 SQL 等，如无则省略）
```

摘要内容（包括标题、列表项、说明文字）**必须采用中文**输出，禁止使用英文或混用语言。

对于纯对话/查询类请求（不涉及文件操作或系统变更），省略摘要输出。

---

## 二、v0 原始产品设计文档保护

**v0 的定义**：v0 指的是**工程根目录下的 `v0/` 目录**，存放产品提交的原始设计文档，只读不可修改。

**明确排除**：`src/web/v0/` 是 **AI 生成的代码目录**，不属于保护范围，可以正常读写和修改。

**识别规则**——符合以下任意条件视为 v0 文档（`src/web/v0/` 除外）：
- 位于工程根目录下的 `v0/` 目录（含 `design/v0/`、`docs/v0/` 等设计文档路径）
- 文件名含 `v0`（如 `product-v0.md`、`spec-v0.pdf`）
- 文件内部标注了 `v0`、`原始设计`、`初稿` 等字样

**强制约束**：
- **可以**：读取、引用、基于其内容提建议
- **禁止**：任何形式的写入、修改、格式调整、追加注释
- 若任务要求修改 v0 文档，**必须拒绝**，说明原因，并建议新建版本文件（如 `product-v1.md`）

---

## 三、禁止硬编码敏感信息

**禁止**在代码、配置文件、脚本、文档、提交记录中出现以下内容的明文形式：

| 类型 | 示例 |
|---|---|
| 密码 | 数据库密码、操作系统账户密码 |
| 密钥 / Token / Secret | JWT Secret、API Key、Access Token、Private Key |
| 内网凭证 | 含用户名密码的数据库连接字符串 |

**正确做法**：
- 运行时配置：通过环境变量引用，如 `${DB_PASSWORD}`、`${JWT_SECRET}`
- 模板 / 示例文件：使用语义明确的占位符，如 `changeme`、`<YOUR_API_KEY>`
- 若发现现有代码已有硬编码敏感信息：立即告知用户，不在此基础上继续扩展，建议用环境变量替换

---

## 四、git commit message 结构化格式

每次执行 git 提交前，**必须**按以下格式组织 commit message：

```
<类型>: <简短描述>（不超过 72 字符）

[可选正文：说明做了什么、为什么这样做，每行不超过 72 字符]
```

**类型取值**：

| 类型 | 适用场景 |
|---|---|
| `feat` | 新功能 |
| `fix` | Bug 修复 |
| `refactor` | 重构（不新增功能、不修复 Bug） |
| `docs` | 文档变更 |
| `style` | 格式调整（不影响逻辑） |
| `test` | 测试相关 |
| `chore` | 构建 / 工具 / 依赖等杂项 |

**正确示例**：
```
feat: 新增 /new-deploy skill，单独生成 deploy.sh
fix: 修正 nginx SSL 证书路径，改为 /etc/nginx/ssl/
docs: 更新 README，补充 deploy.sh 能力说明
```

**禁止**使用无意义描述，如：`update`、`fix bug`、`修改了一些东西`。

---

## 五、CORS 在 nginx 配置中实现

**禁止**在 Java 后端通过以下任何方式处理跨域：
- `@CrossOrigin` 注解
- `WebMvcConfigurer.addCorsMappings()`
- `CorsFilter` / `CorsConfiguration` Bean
- `HttpServletResponse.setHeader("Access-Control-Allow-Origin", ...)` 等手动写响应头

**强制要求**：CORS 响应头统一在 nginx 配置中写入（参考 `deploy-conf/nginx/subconf/cross_domain.conf`），后端不感知跨域逻辑。

**发现存量后端 CORS 代码时**：立即告知用户，说明应迁移到 nginx，不在后端继续扩展或修改该部分代码。

---

## 六、dev / test / prod 三套配置文件自动对齐

**适用范围**：工程内按环境成对维护的三类配置文件——

| 类别 | 文件 |
|---|---|
| env | `deploy-conf/env.dev` / `env.test` / `env.prod`，`src/backend/<服务名>/.env` / `.env.test` / `.env.prod` |
| nginx | `deploy-conf/nginx/vhosts/<服务名>.dev.conf` / `.test.conf` / `.prod.conf` |
| 应用配置 | `src/backend/<服务名>/src/main/resources/application-dev.yml` / `-test.yml` / `-prod.yml` |

**强制要求**：
- 三套文件的**配置项集合必须保持对齐**：新增配置项时同步写入三套环境文件；删除或更名配置项时三套同步变更，禁止只改其中一套
- 三套文件只允许**值**不同（域名、端口、证书路径、日志级别、Swagger 开关等环境差异项）；**结构性配置块**（nginx 的 location/proxy_pass 块、应用的数据源、Actuator 健康检查端点等）不允许只存在于单一环境
- env 占位符模板文件取值保持 `changeme` 等语义占位符，不写真实凭证（与规范三联动）
- 发现存量不对齐（某配置项/配置块只存在于部分环境）时：立即告知用户，一次性补齐对齐后再继续当前任务
- 部署脚本、文档中引用的配置项发生变化时，同步检查三套环境文件是否均已更新
