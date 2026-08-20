---
name: api-test
description: 全端 API 联调检查与修复。完整扫描工程中所有客户端（web 管理后台、小程序、Android、iOS）代码，静态收集后端 API 调用并整理成 URL 清单 test/api/url-list.md；逐个实际发起请求验证 HTTP 状态码是否为 200，非 200 定位前端/后端原因并修复；再检查响应内容的业务合理性，明显不合理的也一并修复；最终输出修复结果 test/api/test-result.md。当用户要求"API 联调测试"、"接口连通性检查与修复"、"全端 API 自测"、"生成 API URL 清单并验证"时触发。支持 /api-test -h 查看帮助。
---

# api-test

完整扫描工程中各客户端（web 管理后台、小程序、Android、iOS）调用的后端 API：静态收集生成 URL 清单 → 逐个请求验证 HTTP 200 → 非 200 定位修复 → 响应业务合理性检查与修复 → 输出测试结果。

**定位**：联调阶段的接口自测。验证"接口通不通、返回对不对"，不替代完整业务功能测试。

**触发条件**：用户要求检查/验证/修复工程各端调用的后端 API，或要求生成 API 清单并逐个验证。

---

## 零、参数处理

**如果用户传入 `-h` 或 `--help`**，不执行任何操作，直接输出以下帮助信息后结束：

---

```
用法: /api-test [选项]

选项（通过命令行传入的参数直接使用，不再交互询问）
  --base-url=URL      后端 API 基础地址（如 http://localhost:8080/api/xxx）。
                      不传则自动探测（各端 env / proxy 配置 / nginx vhost / specs）
  --client=<端>       只扫描指定端（web / miniapp / android / ios，可多次传入）。
                      不传则扫描工程中实际存在的所有端
  --allow-write       允许直接探测 POST/PUT/DELETE 等写操作 API（默认逐个询问）
  --no-fix            只检查并输出报告，不修改任何代码
  -h, --help          显示本帮助

工作流程
  1. 前置检查：识别工程中存在的客户端目录（web 管理后台 / 小程序 / Android / iOS），
     探测后端 base url、确认后端服务在线（健康检查）、确认鉴权 token 获取方式
  2. 全端扫描：静态收集各端代码调用的后端 API（方法 + 路径 + 参数），
     整理成 URL 清单写入 test/api/url-list.md
  3. 逐个验证：curl 实际请求，首先判断 HTTP 响应码是否 200
  4. 诊断修复：非 200 请求按状态码定位前端/后端原因，最小化修复并复验
  5. 业务合理性检查：对 200 响应检查返回内容，业务层面明显不合理的
     （错误码非 0、数据缺失/矛盾、与页面预期不符等）分析并修复
  6. 结果输出：汇总写入 test/api/test-result.md

产物
  test/api/url-list.md     API URL 清单（端 × 页面/模块 × 方法 × 路径 × 参数）
  test/api/test-result.md  验证与修复结果（首次状态 × 最终状态 × 处置 × 修改文件）

示例
  /api-test                                    扫描全部端，自动探测后端地址，检查并修复
  /api-test --client=web                       只扫描 web 管理后台
  /api-test --base-url=http://localhost:8080/api/mall --allow-write
  /api-test --no-fix                           只出报告，不改代码
  /api-test -h                                 显示本帮助
```

---

## 一、前置检查

### 1.1 识别各端代码目录

扫描当前工作目录，确定存在哪些客户端（存在才扫描，一个都没有则报告并终止）：

| 端 | 常见目录 | 说明 |
|---|---|---|
| web 管理后台 | `src/web/`（含 `src/web/v0/` AI 生成代码目录） | Next.js / Vue / React 等 |
| 小程序 | `src/miniapp/`、`src/miniprogram/`、`miniapp/` 或含 `project.config.json` 的目录 | 微信/支付宝等小程序 |
| Android | `src/android/` | Kotlin / Java，Retrofit / OkHttp |
| iOS | `src/ios/`，或含 `.xcodeproj` / `.xcworkspace` 的目录 | Swift / ObjC，URLSession / Alamofire |

目录形态无法确定时，向用户确认各端代码位置。

### 1.2 探测后端 base url

按以下优先级确定后端 API 基础地址，命中即停：

1. 命令行 `--base-url`。
2. 各端环境/配置文件：web 的 `.env*`（`NEXT_PUBLIC_*` / `VITE_*`）、小程序的 env 配置或请求封装常量、Android 的 `BuildConfig` / `local.properties` / Retrofit baseUrl、iOS 的 Info.plist / 请求封装常量。
3. 代理配置：`next.config.*` rewrites、`vite.config.*` server.proxy。
4. 各端请求封装文件（axios instance / fetch wrapper / Retrofit / URLSession 封装）中硬编码的 baseURL。
5. `deploy-conf/nginx/vhosts/*.dev.conf` 或 `specs/deployment.md` 中登记的后端地址。

全部无法确定时，询问用户提供 base url。多个后端服务（不同 context-path）时，按服务分别记录。

### 1.3 确认后端服务在线

1. 确定后端服务名（`src/backend/<name>/`，唯一目录即默认）。
2. 健康检查：`curl -s -o /dev/null -w "%{http_code}" {BASE_URL}/health`，或按 specs/deployment.md 约定的健康检查端点（如 `/api/<name>/health`）。
3. 返回 200 → 继续。
4. 不在线 → 询问用户：由用户启动，还是尝试本地启动（`src/backend/<name>` 下 `./mvnw spring-boot:run` / `mvn spring-boot:run`，后台运行并等待健康检查通过）。用户拒绝则终止。

### 1.4 确认鉴权方式

检查各端请求封装是否自动附加 `Authorization` 头：

- **需要登录** → 找到登录 API 与凭据来源：
  - 优先测试环境账号配置（`deploy-conf/env.*.example`、specs 文档、前端 mock）。
  - 找不到 → 请用户提供测试账号或一个有效 token。
  - 拿到后先调登录接口换取 token，后续所有探测请求带上 `Authorization` 头。
- **无需登录** → 直接继续。

凭据只用于请求，不写入任何文件，不在输出中明文展示。

---

## 二、全端扫描与 URL 清单

### 2.1 按端收集 API 调用

对每个存在的端，静态收集所有后端调用：

| 端 | 收集要点 |
|---|---|
| web | 每个页面（Next.js `app/**/page.tsx` / `pages/**` / 路由配置）及其 import 的 service/hook/工具文件中的 `fetch` / `axios` / 请求 hook；公共布局（layout/App）中的调用归为"全局"组 |
| 小程序 | 每个页面（`pages/**`）与 `utils/`、`api/` 目录中的 `wx.request` / 请求封装调用 |
| Android | Retrofit 接口定义（`@GET/@POST` 注解）、OkHttp 直接调用、Repository/ViewModel 中的 URL 常量 |
| iOS | URLSession / Alamofire 请求构造处、API service 层的 URL 常量与路径拼接 |

只追后端调用，不追 UI 组件与纯本地逻辑。每条记录：**所属端、页面/模块、HTTP 方法、完整路径（含 base url 前缀）、参数来源**（path / query / body）。

### 2.2 写入 URL 清单文件

将收集结果写入 `test/api/url-list.md`（目录不存在则创建）：

```markdown
# API URL 清单

后端地址：<base url>（来源：自动探测/用户提供）
生成时间：<YYYY-MM-DD>
扫描范围：web 管理后台 / 小程序 / Android / iOS（按实际存在的端列出）

| # | 端 | 页面/模块 | 方法 | API 路径 | 参数 | 类型 |
|---|-----|----------|------|----------|------|------|
| 1 | web | /home | GET | /api/mall/banners | - | 读 |
| 2 | web | /order/create | POST | /api/mall/orders | {productId,...} | 写 |
| 3 | miniapp | pages/index | GET | /api/mall/banners | - | 读 |
| 4 | android | OrderRepository | GET | /api/mall/orders | page,size | 读 |
```

### 2.3 确定测试参数

实际探测需要具体参数值，按以下顺序取值：

1. 代码中现成的示例值 / mock 数据 / 默认参数。
2. 从接口语义推断的最小可用值（如 `page=1&size=10`、列表首条记录的 id）。
3. 依赖其他接口返回值的（如详情接口依赖列表接口返回的 id）→ 先探测上游接口，从响应体中提取真实值。
4. 仍无法确定 → 标记 `待参数`，全部收集完后**一次性**向用户询问。

### 2.4 确认后开始验证

向用户展示清单摘要（各端条数、写操作条数）并确认：

- 读操作（GET）：默认直接探测。
- 写操作（POST/PUT/DELETE）：默认**逐条询问**用户是否执行；传入 `--allow-write` 时直接探测。写操作提示用户将作用于当前后端环境的数据。

---

## 三、逐个验证（HTTP 200 检查）

对清单中每条 API 执行：

```bash
curl -s -w "\n[HTTP_STATUS:%{http_code}]" -X {METHOD} "{URL}" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{BODY}'
```

- **首先判断 HTTP 响应码是否为 200**；非 200 时保留响应体（截断至 50 行以内）供诊断。
- 逐条输出即时结果：`[#3] GET /api/mall/orders → 200 OK` 或 `[#5] POST /api/mall/orders → 500 ✗`。
- 多端调用同一接口时只需实际探测一次，结果共享到各端记录。

---

## 四、非 200 诊断与修复

传入 `--no-fix` 时跳过本节与第五节，直接汇总报告。

对每条非 200 请求，按下表定位，遵循**先客户端后后端**的顺序排查：

| 状态码 | 客户端侧检查 | 后端侧检查 |
|---|---|---|
| 404 | 路径拼写、base url 前缀、动态参数拼接（多/少斜杠） | Controller 是否存在该 mapping、路径前缀（context-path）、nginx 转发规则 |
| 405 | 请求方法是否与接口定义一致 | mapping 注解的方法类型 |
| 400 | 必填参数是否缺失、参数名/类型/格式（日期、枚举） | `@RequestParam`/`@RequestBody` 校验注解、DTO 字段定义 |
| 401/403 | 是否漏带/错带 Authorization 头、token 过期 | 安全配置白名单、token 校验逻辑 |
| 500 | （少见）请求体结构错误导致反序列化异常 | 查后端日志定位异常栈：`/data/logs/apps/<name>/` 或本地运行控制台；修复代码缺陷（NPE、SQL、缺表/缺数据等） |
| 超时/000 | base url 是否指向存活服务 | 服务是否假死、端口是否监听 |

### 修复规则

1. **最小化修复**：只改导致该请求失败的位置，不顺手重构。
2. 判定为客户端问题 → 修改对应端代码后重新执行该请求验证。
3. 判定为后端问题 → 修改后端代码后重新编译并重启服务（等待健康检查通过），再复验该请求。
4. 复验仍失败 → 继续诊断，直至定位根因；确认无法修复（如依赖外部系统、缺测试数据）时记录具体原因，标记 `未解决`，继续处理下一条。
5. 修复一条后，若改动影响其他已通过接口（如改了公共路径前缀），对受影响的接口重新复验。

---

## 五、业务合理性检查

对 HTTP 200 的响应，检查返回内容在业务层面是否明显不合理：

1. **协议层**：响应体中的业务错误码（如 `code != 0`、`success=false`）与 200 状态矛盾。
2. **数据完整性**：页面/模块预期必有数据的接口返回空（如首页 banner、登录用户信息为空）；字段缺失或为 null 但客户端代码直接使用会崩溃。
3. **数据一致性**：列表 total 与条目数矛盾、金额/数量为负、状态值不在合法枚举内、关联数据对不上（如订单引用不存在的商品）。
4. **与客户端预期不符**：字段名/结构与客户端 DTO、解析代码不一致。

判定为"明显不合理"才修复；属于测试数据问题（库里本来就没数据）的不算缺陷——记录为 `缺测试数据`，必要时经用户同意后造最小测试数据后复验。

修复同样遵循最小化原则：后端逻辑错误改后端，客户端解析错误改客户端；修复后复验该接口。

---

## 六、结果输出

将验证与修复结果写入 `test/api/test-result.md`：

```markdown
# API 测试结果

后端地址：<base url>
测试时间：<YYYY-MM-DD>
扫描范围：<各端>
URL 清单：test/api/url-list.md（共 M 条）

| # | 端 | 页面/模块 | API | 首次状态 | 最终状态 | 处置 |
|---|-----|----------|-----|---------|---------|------|
| 1 | web | /home | GET /api/mall/banners | 200 | 200 | 通过 |
| 2 | web | /order/list | GET /api/mall/orders | 404 | 200 | 已修复（前端路径拼写） |
| 3 | miniapp | pages/order | GET /api/mall/orders/{id} | 200 | 200 | 已修复（响应缺字段，后端补齐） |
| 4 | web | /order/create | POST /api/mall/orders | 500 | 500 | 未解决（原因） |

结果：通过 X 条 / 修复 Y 条（HTTP 修复 a 条 + 业务修复 b 条）/ 未解决 Z 条 / 跳过（用户未确认写操作） W 条

修改文件清单：
  - src/web/...（修复内容）
  - src/backend/<name>/...（修复内容）
```

同时向用户输出上述内容的中文摘要。

---

## 七、注意事项

- 工程根目录 `v0/` 是只读产品设计文档，禁止修改；`src/web/v0/` 是代码目录，可正常修改。
- 探测使用的账号、token 只出现在请求中，不写入文件、不提交版本库、不在报告中明文输出。
- 写操作 API（POST/PUT/DELETE）默认必须经用户确认才执行；提醒用户其作用于当前后端环境数据。
- 后端改动后的重启遵循工程部署规范（supervisord 管理的生产服务不得随意重启，优先本地/dev 环境验证）。
- CORS 问题只能在 nginx 配置中解决，禁止改后端代码绕过。
- 本 skill 只修改代码文件与 test/api/ 下的两个产物文件，不执行 `git commit`，由用户决定是否提交。
