---
name: web-api-test
description: 前后端 API 联调检查与修复。针对集成了后端服务 API 的 src/web（含 v0 生成前端）工程，逐页枚举页面调用的后端 API，实际发起请求验证是否返回 HTTP 200；对非 200 请求定位前端（路径/方法/参数/鉴权）与后端（映射/参数绑定/异常日志）原因并修复，修复后重新验证。当用户要求"前后端联调测试"、"逐页检查页面 API 是否 200"、"API 连通性检查与修复"、"v0 前端接口自测"时触发。支持 /web-api-test -h 查看帮助。
---

# web-api-test

对 src/web 前端逐页检查其调用的后端 API：静态收集调用清单 → 实际请求验证 HTTP 200 → 非 200 定位前后端原因并修复 → 复验至通过。

**定位**：前后端联调阶段的接口自测。只验证"接口能不能通"，不替代业务功能测试。

**触发条件**：用户要求检查/验证/修复 src/web 页面调用的后端 API，或要求前后端联调自测。

---

## 零、参数处理

**如果用户传入 `-h` 或 `--help`**，不执行任何操作，直接输出以下帮助信息后结束：

---

```
用法: /web-api-test [选项]

选项（通过命令行传入的参数直接使用，不再交互询问）
  --base-url=URL    后端 API 基础地址（如 http://localhost:8080/api/xxx）。
                    不传则自动探测（前端 env / proxy 配置 / nginx vhost / specs）
  --page=<route>    只测指定页面路由（可多次传入，如 --page=/home --page=/user/list）。
                    不传则测全部页面
  --allow-write     允许直接探测 POST/PUT/DELETE 等写操作 API（默认逐个询问）
  --no-fix          只检查并输出报告，不修改任何代码
  -h, --help        显示本帮助

工作流程
  1. 前置检查：src/web 存在、识别路由结构、探测后端 base url、
     确认后端服务在线（健康检查）、确认鉴权 token 获取方式
  2. 逐页枚举：按路由结构列出全部页面，静态收集每个页面（含其引入的
     service/hook/工具文件）调用的后端 API：方法 + 路径 + 参数
  3. 逐个探测：curl 实际请求，记录 HTTP 状态码与响应体
  4. 诊断修复：非 200 请求按状态码定位前端/后端原因，最小化修复，
     后端改动重启后复验，直至 200 或确认无法修复（记录原因）
  5. 汇总报告：页面 × API × 状态 × 处置结果 中文清单

示例
  /web-api-test                                  自动探测后端地址，全量检查并修复
  /web-api-test --page=/order/list               只检查订单列表页
  /web-api-test --base-url=http://localhost:8080/api/mall --allow-write
  /web-api-test --no-fix                         只出报告，不改代码
  /web-api-test -h                               显示本帮助
```

---

## 一、前置检查

### 1.1 确认前端工程

检查当前工作目录是否存在 `src/web/`：

- 存在 → 继续。前端代码可能位于 `src/web/v0/`（AI 生成代码目录，可正常读写）。
- 不存在 → 报告"未检测到 src/web/ 目录"并终止。

### 1.2 识别路由结构

识别前端框架与页面组织方式，确定"页面"的枚举来源：

| 框架形态 | 页面枚举来源 |
|---|---|
| Next.js App Router | `app/**/page.tsx`（路由 = 目录路径） |
| Next.js Pages Router | `pages/**/*`（路由 = 文件路径） |
| Vue Router / React Router | 路由配置文件（`router/index.*`、`<Route>` 声明）中的每条路由 |

同时找出页面的公共入口布局（layout / App 组件），其中的 API 调用视为**所有页面共用**，单独归为"全局"一组。

### 1.3 探测后端 base url

按以下优先级确定后端 API 基础地址，命中即停：

1. 命令行 `--base-url`。
2. 前端环境文件：`.env` / `.env.development` / `.env.local` 中的 `NEXT_PUBLIC_*` / `VITE_*` API 变量。
3. 前端代理配置：`next.config.*` rewrites、`vite.config.*` server.proxy、`package.json` proxy。
4. 前端请求封装文件（axios instance / fetch wrapper）中硬编码的 baseURL。
5. `deploy-conf/nginx/vhosts/*.dev.conf` 或 `specs/deployment.md` 中登记的后端地址。

全部无法确定时，询问用户提供 base url。

### 1.4 确认后端服务在线

1. 确定后端服务名（`src/backend/<name>/`，唯一目录即默认）。
2. 健康检查：`curl -s -o /dev/null -w "%{http_code}" {BASE_URL}/health`，或按 specs/deployment.md 约定的健康检查端点（如 `/api/<name>/health`）。
3. 返回 200 → 继续。
4. 不在线 → 询问用户：由用户启动，还是尝试本地启动（`src/backend/<name>` 下 `./mvnw spring-boot:run` / `mvn spring-boot:run`，后台运行并等待健康检查通过）。用户拒绝则终止。

### 1.5 确认鉴权方式

检查前端请求封装是否自动附加 `Authorization` 头：

- **需要登录** → 找到登录 API 与凭据来源：
  - 优先测试环境账号配置（`deploy-conf/env.*.example`、specs 文档、前端 mock）。
  - 找不到 → 请用户提供测试账号或一个有效 token。
  - 拿到后先调登录接口换取 token，后续所有探测请求带上 `Authorization` 头。
- **无需登录** → 直接继续。

凭据只用于请求，不写入任何文件，不在输出中明文展示。

---

## 二、页面枚举与 API 收集

### 2.1 逐页收集

对第一步枚举出的每个页面（含"全局"组）：

1. 阅读页面组件源码，找出所有后端调用：`fetch` / `axios` / 封装好的 request 方法 / SWR、React Query 等数据请求 hook。
2. 页面 import 的 service / api / hook / 工具文件一并展开检查（只追后端调用，不追 UI 组件）。
3. 每条调用记录：**页面路由、HTTP 方法、完整路径（含 base url 前缀）、参数来源**（path 参数 / query / body）。

### 2.2 确定测试参数

实际探测需要具体参数值，按以下顺序取值：

1. 代码中现成的示例值 / mock 数据 / 默认参数。
2. 从接口语义推断的最小可用值（如 `page=1&size=10`、列表首条记录的 id）。
3. 依赖其他接口返回值的（如详情接口依赖列表接口返回的 id）→ 先探测上游接口，从响应体中提取真实值。
4. 仍无法确定 → 标记 `待参数`，全部收集完后**一次性**向用户询问。

### 2.3 输出清单并确认

向用户展示收集结果表格，并确认后开始探测：

```
| # | 页面 | 方法 | API 路径 | 参数 | 类型 |
|---|------|------|----------|------|------|
| 1 | /home | GET | /api/mall/banners | - | 读 |
| 2 | /order/create | POST | /api/mall/orders | {productId,...} | 写 |
```

- 读操作（GET）：默认直接探测。
- 写操作（POST/PUT/DELETE）：默认**逐条询问**用户是否执行；传入 `--allow-write` 时直接探测。写操作提示用户将作用于当前后端环境的数据。

---

## 三、逐个探测

对清单中每条 API 执行：

```bash
curl -s -w "\n[HTTP_STATUS:%{http_code}]" -X {METHOD} "{URL}" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{BODY}'
```

- 记录状态码；非 200 时保留响应体（截断至 50 行以内）供诊断。
- 逐条输出即时结果：`[#3] GET /api/mall/orders → 200 OK` 或 `[#5] POST /api/mall/orders → 500 ✗`。
- 全部探测完成后，若无非 200，直接跳到**五、完成输出**。

---

## 四、非 200 诊断与修复

传入 `--no-fix` 时跳过本节，直接汇总报告。

对每条非 200 请求，按下表定位，遵循**先前端后后端**的顺序排查：

| 状态码 | 前端侧检查 | 后端侧检查 |
|---|---|---|
| 404 | 路径拼写、base url 前缀、动态参数拼接（多/少斜杠） | Controller 是否存在该 mapping、路径前缀（context-path）、nginx 转发规则 |
| 405 | 请求方法是否与接口定义一致 | mapping 注解的方法类型 |
| 400 | 必填参数是否缺失、参数名/类型/格式（日期、枚举） | `@RequestParam`/`@RequestBody` 校验注解、DTO 字段定义 |
| 401/403 | 是否漏带/错带 Authorization 头、token 过期 | 安全配置白名单、token 校验逻辑 |
| 500 | （少见）请求体结构错误导致反序列化异常 | 查后端日志定位异常栈：`/data/logs/apps/<name>/` 或本地运行控制台；修复代码缺陷（NPE、SQL、缺表/缺数据等） |
| 超时/000 | base url 是否指向存活服务 | 服务是否假死、端口是否监听 |

### 修复规则

1. **最小化修复**：只改导致该请求失败的位置，不顺手重构。
2. 判定为前端问题 → 修改 src/web 代码后重新执行该请求验证。
3. 判定为后端问题 → 修改后端代码后重新编译并重启服务（等待健康检查通过），再复验该请求。
4. 复验仍失败 → 继续诊断，最多迭代直至定位根因；确认无法修复（如依赖外部系统、缺测试数据）时记录具体原因，标记 `未解决`，继续处理下一条。
5. 修复一条后，若改动影响其他已通过接口（如改了公共路径前缀），对受影响的接口重新复验。

---

## 五、完成输出

全部处理完成后，输出中文汇总：

```
## web-api-test 检查完成

后端地址：<base url>（来源：自动探测/用户提供）
检查页面：N 个，API 共 M 条

| # | 页面 | API | 首次状态 | 最终状态 | 处置 |
|---|------|-----|---------|---------|------|
| 1 | /home | GET /api/mall/banners | 200 | 200 | 通过 |
| 2 | /order/list | GET /api/mall/orders | 404 | 200 | 已修复（前端路径拼写） |
| 3 | /order/create | POST /api/mall/orders | 500 | 500 | 未解决（原因） |

结果：通过 X 条 / 修复 Y 条 / 未解决 Z 条 / 跳过（用户未确认写操作） W 条

修改文件清单：
  - src/web/v0/...（修复内容）
  - src/backend/<name>/...（修复内容）
```

---

## 六、注意事项

- 工程根目录 `v0/` 是只读产品设计文档，禁止修改；`src/web/v0/` 是代码目录，可正常修改。
- 探测使用的账号、token 只出现在请求中，不写入文件、不提交版本库、不在报告中明文输出。
- 写操作 API（POST/PUT/DELETE）默认必须经用户确认才执行；提醒用户其作用于当前后端环境数据。
- 后端改动后的重启遵循工程部署规范（supervisord 管理的生产服务不得随意重启，优先本地/dev 环境验证）。
- CORS 问题只能在 nginx 配置中解决，禁止改后端代码绕过。
- 本 skill 只修改代码文件，不执行 `git commit`，由用户决定是否提交。
