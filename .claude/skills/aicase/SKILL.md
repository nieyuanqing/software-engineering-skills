---
name: aicase
description: 连接 aibug 系统，通过 GET /bugs/since?since=yyyy-MM-dd_HH:mm:ss 接口按时间拉取 Bug 清单，逐个分析是否需要转化为回归测试用例，在 test/cases/ 生成 TEST-CASE-{4位编号}.md（优先级固定 P1，元信息标记"生成来源：AICASE SKILL"）并重建 case-summary.md。时间参数支持 今天/昨天/前天 或日期，调用 API 前统一转换为 yyyy-MM-dd_HH:mm:ss；可选 --reporter 按提报人过滤。必须配合 aibug 系统使用。支持 /aicase -h 查看帮助。
---

# aicase

连接 aibug Bug 管理系统，按时间拉取 Bug 清单，逐个分析是否值得沉淀为回归测试用例；值得转化的在 `test/cases/` 生成标准用例文件（优先级固定 **P1**，元信息标记 **AICASE SKILL 生成**），并重建 `case-summary.md`。

**触发条件**：用户要求把 aibug 的 Bug 转化为测试用例、根据近期 Bug 补充回归用例，或直接输入 /aicase。

> **执行方式：必须串行执行，禁止并行。** 同一时刻只允许一个本 skill 实例；Bug 严格逐个判定与生成（CASE 编号按序分配，禁止并发写入）。禁止并行启动多个实例、多个子智能体同时生成用例，也禁止与 /aibug、/do-test 并发运行。

---

## 零、参数处理

**如果用户传入 `-h` 或 `--help`**，不执行任何操作，直接输出以下帮助信息后结束：

---

```
用法: /aicase [选项]

选项（通过命令行传入的参数直接使用，不再交互询问）
  --host=URL          aibug 系统 Base URL（同 /aibug，如 --host=http://your-server:8082）
  --username=NAME     登录账号
  --password=PASS     登录密码
  --project-id=N      项目 ID（必填，未指定直接报错；作为 API 查询参数
                      project-id 传入，服务端必填并按其过滤）
  --reporter=NAME     Bug 提报者用户名（可选，服务端按提报人过滤，
                      如 --reporter=lvtao；不传则不按提报人过滤；
                      对应 API 查询参数 reporter）
  --since=TIME        Bug 起始时间（按创建时间），支持：
                        今天 | 昨天 | 前天 | YYYY-MM-DD | YYYY-MM-DD_HH:MM:SS
                      默认: 今天。调用 API 时统一转换为 yyyy-MM-dd_HH:mm:ss 格式
                      （如 2026-08-26_00:00:00）
  -h, --help          显示本帮助

工作流程
  1. POST {host}/aibug/api/auth/login            登录，获取 token
  2. GET  {host}/aibug/api/bugs/since?since=...  获取指定时间起的 Bug 清单
  3. 去重：已有用例元信息含 "aibug Bug #<id>" 的 Bug 跳过
  4. 逐个判定是否值得转化为回归用例：功能/接口/业务流程类转化；
     文案/样式微调、一次性数据、环境配置类跳过
  5. 需转化的逐个生成 test/cases/TEST-CASE-{4位编号}.md：
     优先级固定 P1，元信息追加 "生成来源：AICASE SKILL（aibug Bug #<id>）"
  6. 重建 test/cases/case-summary.md（AICASE 生成的用例名称后缀（AICASE））

示例
  /aicase --host=http://your-server:8082 --username=admin --password=secret --project-id=1
  /aicase --host=http://your-server:8082 --username=admin --password=secret \
      --project-id=1 --since=昨天
  /aicase --host=http://your-server:8082 --username=admin --password=secret \
      --project-id=1 --since=2026-08-26
  /aicase --host=http://your-server:8082 --username=admin --password=secret \
      --project-id=1 --reporter=lvtao --since=昨天
  /aicase -h
```

---

## 一、收集参数

### 1.1 解析命令行参数

| 命令行写法 | 对应参数 |
|---|---|
| `--host=URL` | `HOST`（必填，无默认值） |
| `--username=NAME` | `USERNAME`（必填，无默认值） |
| `--password=PASS` | `PASSWORD`（必填，无默认值） |
| `--project-id=N` | `PROJECT_ID`（**必填**，无默认值；作为 API 查询参数 `project-id` 传入，服务端必填） |
| `--reporter=NAME` | `REPORTER`（可选；Bug 提报者用户名，服务端过滤，对应 API 查询参数 `reporter`） |
| `--since=TIME` | `SINCE`（默认 `今天`） |

### 1.2 参数校验与补齐

- **`PROJECT_ID` 必须通过 `--project-id=N` 显式指定**：未指定时**直接报错终止**（输出 `错误：缺少 --project-id=N，必须指定项目 ID`），不交互询问、不继续执行。
- 其余必填参数（HOST / USERNAME / PASSWORD）缺失时**一次性列出**统一交互询问。
- `SINCE` 缺失时使用默认 `今天`，不强制询问。

参数确定后向用户回显（密码替换为 `****`），确认后开始执行。

---

## 二、--since 时间转换

用户传入的 `SINCE` 在调用 API 前必须转换为 `yyyy-MM-dd_HH:mm:ss` 格式：

| 用户输入 | 转换结果 |
|---|---|
| `今天` | `$(date +%Y-%m-%d)_00:00:00` |
| `昨天` | `$(date -d 'yesterday' +%Y-%m-%d)_00:00:00` |
| `前天` | `$(date -d '2 days ago' +%Y-%m-%d)_00:00:00` |
| `YYYY-MM-DD`（如 `2026-08-26`） | 原日期 + `_00:00:00` |
| `YYYY-MM-DD_HH:MM:SS` | 原样使用 |

转换后向用户明示实际请求的时间值（如 `since=2026-08-26_00:00:00`）。

---

## 三、认证

与 /aibug 相同：

```bash
curl -s -X POST "{HOST}/aibug/api/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"{USERNAME}","password":"{PASSWORD}"}'
```

- 响应包含 `error` 字段 → 立即停止，报告登录失败原因。
- 成功后保存 `token`，后续请求均带 `Authorization: Bearer <token>`；token 与密码禁止明文输出（一律显示 `***`）。

---

## 四、获取 Bug 清单

```bash
curl -s "{HOST}/aibug/api/bugs/since?since={SINCE_转换值}&project-id={PROJECT_ID}" \
  -H "Authorization: Bearer <token>"
```

指定了 `REPORTER` 时再追加 `&reporter={REPORTER}`（服务端按提报人过滤）：

```bash
curl -s "{HOST}/aibug/api/bugs/since?since={SINCE_转换值}&project-id={PROJECT_ID}&reporter={REPORTER}" \
  -H "Authorization: Bearer <token>"
```

`project-id` 是 **API 必填参数**（缺失返回 400 `{"error":"project-id为必填参数"}`），与本 skill 的 `--project-id` 必填校验一致。

**响应**：Bug 对象数组（字段同 /bugs/next：`id`、`content`、`fileUrls`、`status`、`projectId`、`createdAt`、`username`（提报人）等）。

**响应瘦身**（必做）：每个 Bug 只保留 `id`、`content`（≤500 字，超长截断）、`fileUrls`、`status`、`projectId`、`createdAt`、`username`；禁止把完整 JSON 原文粘进对话。

- **逐条强制校验**（必做，服务端过滤之外的兜底双保险）：对返回的每个 Bug 依次校验——
  - 项目校验：`projectId` 必须等于 `PROJECT_ID`；
  - 提报人校验（仅指定了 `REPORTER` 时）：`username`（提报者）必须等于 `REPORTER`；
  - 任一不通过 → 该记录**跳过**（不进入判定与生成流程），记一行台账
    `#<id> → 校验不通过（projectId=<实际值> / reporter=<实际值>）`，并在完成汇总中逐条列出。
- 清单为空或全部校验不通过 → 输出"该项目在该时间段内无可处理 Bug"后结束。
- 响应为 `{"error": ...}`（时间格式非法等）→ 停止并报告；清单为空数组 → 直接输出"该时间段内无 Bug"后结束。
- 向用户输出一行台账表头：`共拉取 N 个 Bug（since=<时间值>[，reporter=<提报人>]）`。

---

## 五、逐个 Bug 判定与生成

### 5.1 去重（必做）

处理每个 Bug 前，在 `test/cases/` 下检索 `aibug Bug #<id>`：

```bash
grep -rl "aibug Bug #<id>" test/cases/ 2>/dev/null
```

命中 → 该 Bug 记 `跳过（已有 CASE: <文件名>）`，不再处理。

### 5.2 转化判定标准

**生成 CASE**（同时满足）：
- Bug 指向可复现的功能行为：接口报错/返回数据错误、业务规则错误、流程中断、权限异常、状态流转错误等
- 能整理成可执行、可断言的步骤（API / Playwright UI / 人工）

**跳过**（记录原因，一行台账）：
- 纯文案错别字、样式/像素级微调
- 一次性数据订正、环境/配置问题
- 描述过于模糊，无法形成可执行步骤
- 与现有用例场景实质重复（即使未命中 5.1 的字面去重）

判定时可读附件截图（`{HOST}{fileUrls}`）与工程代码辅助理解，但只截取相关片段。

### 5.3 生成 CASE（子智能体隔离）

主循环先分配编号：扫描 `test/cases/TEST-CASE-*.md` 现有最大编号，加上本轮已分配数，取下一个 4 位编号（无文件从 `0001` 起）。

**默认委托子智能体**（Agent 工具，subagent_type 用 general-purpose）写入用例文件，prompt 只包含：

- 当前 Bug 卡：`#id`、`content`（原文）、附件完整地址（如有）
- 工程根路径、目标文件路径 `test/cases/TEST-CASE-<编号>.md`
- 用例模板要求：与 /new-test-case 完全一致（元信息/前置条件/测试数据/步骤表/结果验证/善后清理），步骤类型 API / UI(Playwright) / 人工
- 固定约束：**优先级一律 P1**；元信息表在标准四行后追加一行：

  ```
  | 生成来源 | AICASE SKILL（aibug Bug #<id>） |
  ```

- 不写真实账号密码（用"测试账号"等占位）、不执行 git commit、可结合工程代码（Controller、src/web、test/api/url-list.md）确定真实 API 路径与页面选择器

子智能体以下列固定格式返回（≤3 行），主循环记入台账：

```
结果: GENERATED | SKIPPED
文件: test/cases/TEST-CASE-NNNN.md（SKIPPED 时写 无）
说明: <一句话场景摘要或跳过原因>
```

**回退方式**（无法使用子智能体时）：主循环内联生成，仍须遵守响应瘦身与模板要求。

### 5.4 台账

主循环只维护一行式台账：`#<id> → 已生成 TEST-CASE-NNNN（场景名）| 跳过（原因）`，不保留分析细节。

---

## 六、重建 case-summary.md（必做）

全部 Bug 处理完后，按 /new-test-case 第四节的规则**重建** `test/cases/case-summary.md`（扫描全部历史用例，覆盖式更新），并遵循：

- 元信息含 `生成来源：AICASE SKILL` 的用例，**CASE 名称列追加后缀 `（AICASE）`**（如 `下单异常修复回归（AICASE）`）
- 本 skill 生成的用例优先级固定为 `P1`

---

## 七、完成输出

```
## aicase 完成

拉取 Bug：N 个（since=<时间值>）
  - 生成 CASE：a 个
      TEST-CASE-NNNN <场景名>（aibug Bug #id）
      ...
  - 跳过（已有 CASE）：b 个
  - 跳过（不宜转化）：c 个（逐条：#id 原因）
  - 校验不通过：d 个（逐条：#id 原因，如 projectId=<实际值>≠<PROJECT_ID>、
    reporter=<实际值>≠<REPORTER>）

用例清单：test/cases/case-summary.md
执行方式：/do-test --task=cases（本批用例均为 P1）
```

---

## 八、注意事项

- 访问参数（HOST、USERNAME、PASSWORD、PROJECT_ID）的取用与安全要求与 /aibug 一致：密码仅用于登录请求，不写入任何文件、不明文输出。
- `/bugs/since` 服务端校验时间格式 `yyyy-MM-dd_HH:mm:ss`（下划线分隔），非法返回 400 与 `error` 提示；`since` 参数本身可选（不传返回全部），本 skill 默认 `今天`，不做无时间范围的全量拉取。
- CASE 内容不得写入真实凭证；附件截图仅用于理解 Bug，不落盘到工程。
- 只新增用例文件与重建 `case-summary.md`，不修改已有用例；不执行 `git commit`，由用户决定是否提交。
- 本 skill 只读 aibug 数据（除登录外不发起任何写请求），不改变任何 Bug 状态。
- **必须串行执行**：本 skill 全程单实例、逐个 Bug 判定与生成，禁止并行（多实例、多子智能体同时生成用例、与 /aibug 或 /do-test 并发均不允许）；用户要求并行时应明确拒绝并说明该约束。
