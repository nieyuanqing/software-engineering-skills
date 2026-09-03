---
name: aibug
description: 连接 aibug 系统，循环自动修复 PENDING 状态的 Bug。依次执行：登录获取 token → 获取下一个 Bug → 分析代码并修复 → 更新状态（FIXED/PARTIALLY_FIXED/FAILED），直到无更多待处理 Bug。必须配合 aibug 系统使用。支持 /aibug -h 查看帮助。
---

# aibug

自动连接 aibug Bug 管理系统，循环获取并修复 PENDING 状态的 Bug，直到队列为空。

**触发条件**：用户要求自动修复 Bug、接入 aibug 系统，或说"开始修 Bug"。

> **执行方式：必须串行执行，禁止并行。** 同一时刻只允许一个本 skill 实例；**每条 Bug 通过子 agent 处理，严格逐条串行**——上一条 Bug 完成状态回传（FIXED / PARTIALLY_FIXED / FAILED）并回读确认后，才可为下一条 Bug 启动子 agent。禁止并行启动多个实例、并行启动多个子 agent 同时处理不同 Bug，也禁止与 /aicase、/do-test 并发运行。

---

## 零、参数处理

**如果用户传入 `-h` 或 `--help`**，不执行任何操作，直接输出以下帮助信息后结束：

---

```
用法: /aibug [选项]

选项（通过命令行传入的参数直接使用，不再交互询问）
  --host=URL          aibug 系统 Base URL（如 --host=http://your-server:8082）
  --username=NAME     登录账号
  --password=PASS     登录密码
  --project-id=N      项目 ID（必填，未指定直接报错；如 --project-id=1）
  -h, --help          显示本帮助

工作流程
  1. POST {host}/aibug/api/auth/login          登录，获取 token
  2. GET  {host}/aibug/api/bugs/next           获取下一个 PENDING Bug
  3. PUT  {host}/aibug/api/bugs/{id}/status    标记为 IN_PROGRESS
  4. 委托子智能体分析 Bug 并修复；每修复一个即刻验证（编译/构建/复测），
     验证通过才可标记 FIXED / PARTIALLY_FIXED，禁止最后统一验证
  5. PUT  {host}/aibug/api/bugs/{id}/status    标记为 FIXED、PARTIALLY_FIXED
     （必填 fixNote）或 FAILED（必填 failReason）
  6. 循环回到第 2 步，直到无更多 PENDING Bug

Bug 字段说明
  id          Bug 唯一 ID
  content     Bug 描述文本（说明需要修复的内容）
  fileUrls    附件相对路径（截图等，相对于 host）
  status      当前状态：PENDING / IN_PROGRESS / FIXED / PARTIALLY_FIXED
              / FAILED / RESOLVED / CLOSED
  failReason  失败原因（状态为 FAILED 时必填）
  fixNote     部分修复说明（状态为 PARTIALLY_FIXED 时必填）：
              已修复内容 + 剩余待修复问题

示例
  /aibug --host=http://your-server:8082 --username=admin --password=secret --project-id=1
  /aibug -h
```

---

## 一、收集参数

### 1.1 解析命令行参数

| 命令行写法 | 对应参数 |
|---|---|
| `--host=URL` | `HOST`（必填，无默认值） |
| `--username=NAME` | `USERNAME`（必填，无默认值） |
| `--password=PASS` | `PASSWORD`（必填，无默认值） |
| `--project-id=N` | `PROJECT_ID`（必填，无默认值） |

### 1.2 参数校验与补齐

- **`PROJECT_ID` 必须通过 `--project-id=N` 显式指定**：未指定时**直接报错终止**（输出 `错误：缺少 --project-id=N，必须指定项目 ID`），不交互询问、不继续执行。
- 其余必填参数缺失时**一次性列出**，统一交互询问：

| 参数 | 说明 |
|---|---|
| `HOST` | aibug 系统 Base URL，如 `http://your-server:8082` |
| `USERNAME` | 登录账号 |
| `PASSWORD` | 登录密码 |

所有参数确定后，**向用户回显参数列表**（密码替换为 `****`），确认后开始执行。

---

## 二、认证

用 Bash 工具执行以下请求，提取 `token` 字段：

```bash
curl -s -X POST "{HOST}/aibug/api/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"{USERNAME}","password":"{PASSWORD}"}'
```

**响应**（成功）：
```json
{"id": 1, "username": "admin", "displayName": "管理员", "token": "<TOKEN>"}
```

- 若响应包含 `error` 字段，**立即停止**，向用户报告登录失败原因。
- 登录成功后将 `token` 存入变量，后续所有请求均带 `Authorization: Bearer <token>` 头。

---

## 三、修复循环

以下步骤循环执行，直到无更多 PENDING Bug 为止。

### 执行过程输出要求（必做）

每轮循环对每个实际 API 调用向用户输出**一行**记录，只含 **方法 + 路径 + 结果**，禁止输出完整 curl 命令、请求头与 JSON 原文：

```
[取 Bug]     GET /aibug/api/bugs/next?projectId={PROJECT_ID} → 200，#<id>
[回传状态]   PUT /aibug/api/bugs/{id}/status → 200，status=IN_PROGRESS
[回读确认]   GET /aibug/api/bugs/{id} → 200，status=IN_PROGRESS
[回传状态]   PUT /aibug/api/bugs/{id}/status → 200，status=PARTIALLY_FIXED，fixNote=已修复…；待修复…
[回读确认]   GET /aibug/api/bugs/{id} → 200，status=PARTIALLY_FIXED，fixNote 一致
```

- 路径中 `{PROJECT_ID}`、`{id}` 替换为真实值；token 与 Authorization 头一律不出现。
- 非 200 或响应含 `error` 时在同一行追加一句话原因，不重试转述响应体。

### 上下文与权重控制（全程必做）

**上下文增长优化**（防止长循环撑爆上下文窗口）：

1. **子智能体隔离**：3.3 的分析与修复默认委托给子智能体（Agent 工具）执行——子智能体拥有独立上下文，定位/阅读/修改代码的完整过程不进入主循环；主循环只接收结构化结果（常规 5 行，仅 PARTIALLY_FIXED 多 1 行）。
2. **响应瘦身**：所有 API 响应只保留 `id`、`content`（≤500 字，超长截断）、`fileUrls`、`status`、`fixNote`、`error` 字段；禁止把完整 JSON 原文粘进对话。
3. **台账式记录**：主循环只维护一行式台账 `#<id> → FIXED/PARTIALLY_FIXED/FAILED（一句话原因；PARTIALLY_FIXED 追加"待修复"要点）`，不保留分析细节。
4. **定期压缩**：每处理完 5 个 Bug，或感知上下文占用约 60% 时，执行一次 `/compact`，并明确要求保留：连接参数与 token、台账表、当前未完成 Bug 的状态。

**当前 Bug 信息权重优先**（当前需求/bug 信息高于历史上下文）：

1. **Bug 卡先行**：开始处理每个 Bug 时，先输出"当前 Bug 卡"（`#id / content / fileUrls / 目标状态`）；该 Bug 的处理全程以卡内信息为唯一事实来源。
2. **禁止串味**：当前 Bug 卡与之前 Bug 的结论、历史对话、经验假设冲突时，一律以当前 Bug 卡为准；不复用上一个 Bug 的定位结果、根因判断或修复方案。
3. **干净上下文**：子智能体 prompt 只包含当前 Bug 卡 + 工程路径 + 修复约束，不携带任何历史 Bug 信息，天然保证当前需求获得最高权重。

### 3.1 获取下一个 Bug

```bash
curl -s "{HOST}/aibug/api/bugs/next?projectId={PROJECT_ID}" \
  -H "Authorization: Bearer <token>"
```

**响应**（有 Bug）：
```json
{
  "id": 6,
  "content": "Bug 描述文本",
  "fileUrls": "/images/202608/xxx.png",
  "filePaths": "/data/aibug/images/202608/xxx.png",
  "status": "PENDING",
  "fixNote": null,
  "projectId": 1,
  ...
}
```

**响应**（无更多 Bug）：返回 HTTP 4xx 或空对象。遇到此情况，**退出循环**，向用户报告"所有 Bug 已处理完毕"。

**项目校验（必做）**：取到 Bug 后立即将响应中的 `projectId` 与命令行 `PROJECT_ID` 比对：

- 一致 → 进入 3.2；
- 不一致 → **不更新该 Bug 状态**，记台账 `#<id> → 项目校验不通过（projectId=<实际值> ≠ <PROJECT_ID>）`，跳过该 Bug，回到本步取下一个；
- 若再次取回同一 Bug ID（服务端过滤异常），**立即终止循环**并向用户告警，该记录列入完成汇总的"项目校验不通过"清单，防止死循环。

### 3.2 标记为 IN_PROGRESS

获取到 Bug 后，立即更新状态，防止被重复领取：

```bash
curl -s -X PUT "{HOST}/aibug/api/bugs/{id}/status" \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"status":"IN_PROGRESS","projectId":{PROJECT_ID}}'
```

**回读验证**（必做）：PUT 后立即回读，确认状态确实落库，防止"提示成功、实际未生效"：

```bash
curl -s "{HOST}/aibug/api/bugs/{id}" \
  -H "Authorization: Bearer <token>"
```

- 响应中 `status` 必须为 `IN_PROGRESS`，否则重试一次；仍不一致则**停止处理该 Bug**，向用户报告不一致详情。

### 3.3 分析并修复 Bug（子智能体隔离）

**默认方式：委托子智能体**（Agent 工具，subagent_type 用 general-purpose），prompt 只包含：

- 当前 Bug 卡：`#id`、`content`（原文）、附件完整地址（`{HOST}{fileUrls}`，如有）
- 工程根路径，以及约束：最小化修复、只改代码不执行 git commit、**修复后必须验证**、**按下方三态判定标准给出结果**、无法修复时明确说明原因

**串行约束（必做）**：每条 Bug 单独委托一个子智能体，同一时刻最多只有一个子智能体在运行；当前子智能体返回结果并记入台账后，才可为下一条 Bug 启动新的子智能体，禁止同时派出多个子智能体并行修复。

要求子智能体以下列固定格式返回（常规 5 行，结果为 `PARTIALLY_FIXED` 时必须追加第 6 行），主循环只将该结果记入台账，不追问细节：

```
结果: FIXED | PARTIALLY_FIXED | FAILED
修改文件: <逐行列出；FAILED 时写 无>
验证: <验证方式> → 通过 | 失败
说明: <一句话根因或失败原因>
部分修复说明: <仅 PARTIALLY_FIXED 返回：已修复 <已完成内容>；待修复 <剩余问题>>
```

**三态判定标准**（写入子智能体 prompt，必须逐点核对）：把 `content` 拆成独立问题点逐条核对——

- 全部问题点均已修复且验证通过 → `FIXED`
- 仅部分问题点修复（如只覆盖一端/一条路径/一个接口，其余点未处理或需外部系统、需产品决策配合）→ `PARTIALLY_FIXED`，并在"部分修复说明"里同时写清"已修复"与"待修复"，已修复部分必须验证通过
- 一点都没修复、或修复后验证不通过 → `FAILED`

禁止把已全量修好且验证通过的 Bug 报成 `PARTIALLY_FIXED`（避免虚增人工待办），也禁止用 `PARTIALLY_FIXED` 掩盖验证失败。

子智能体内部执行：理解 `content` → 查看附件图片（如有）→ 定位代码 → Edit/Write 最小化修复 → **即刻验证（必做）**：修复完成后**在同一轮内立即验证**，验证通过才返回结果，然后才进入 3.4 更新状态、再取下一个 Bug；**禁止**把验证推迟到所有 Bug 修复完后统一做。验证方式按工程类型选最低成本——Java 工程 `mvn -q -DskipTests compile` 编译通过；前端工程构建或 lint 通过；Bug 指向具体接口时用 curl 复测该接口行为符合描述预期；工程有相关测试则运行对应测试。验证未通过则继续修复直至通过，仍无法通过则如实报告 `验证: 失败`，不得虚报 FIXED。

**回退方式**（无法使用子智能体时）：主循环内联执行上述四步，但必须遵守"上下文与权重控制"——响应与文件内容只截取相关片段，不把大段原文粘进对话。

### 3.4 更新 Bug 状态

按 3.3 的三态判定结果回传，一次 PUT 一个终态：

| 子智能体结果 | 回传状态 | 必填说明字段 |
|---|---|---|
| `结果: FIXED` + `验证: 通过`，问题点全部覆盖 | `FIXED` | 无 |
| `结果: PARTIALLY_FIXED` + 已修复部分 `验证: 通过` | `PARTIALLY_FIXED` | `fixNote` |
| `结果: FAILED`，或复验仍不通过 | `FAILED` | `failReason` |

**标记 FIXED 的前提**：该 Bug 的验证已在**本轮修复后即刻完成**（不是全部修完后统一验证），且子智能体结果同时满足 `结果: FIXED` 与 `验证: 通过`。若 `验证: 失败`，退回子智能体追加修复一轮（携带失败现象），复验仍失败则标记 `FAILED`，failReason 写明"修复后验证未通过：<验证方式与失败现象>"。

**全部修复** → 标记为 `FIXED`：

```bash
curl -s -X PUT "{HOST}/aibug/api/bugs/{id}/status" \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"status":"FIXED","projectId":{PROJECT_ID}}'
```

**部分修复** → 标记为 `PARTIALLY_FIXED`，并填写 `fixNote`（必填，缺失服务端返回 400）：

```bash
curl -s -X PUT "{HOST}/aibug/api/bugs/{id}/status" \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"status":"PARTIALLY_FIXED","projectId":{PROJECT_ID},"fixNote":"已修复：<已完成内容>；待修复：<剩余问题>"}'
```

`fixNote` 编写要求：

- 固定采用 `已修复：…；待修复：…` 两段式，两段都必须有实质内容，"待修复"不得写成"其余部分"这类空话
- 全文 ≤200 字，只写问题点级别的事实，不贴代码
- 已修复部分必须是**本轮已验证通过**的内容；未验证的部分一律归入"待修复"
- 每个 `PARTIALLY_FIXED` 的 Bug 都要把"待修复"要点原样列入本次任务的**人工待办**清单（common-rules 规范一"人工待办"板块），标注 `#<id>` 与 `@研发`，避免剩余问题被漏掉

**无法修复** → 标记为 `FAILED`，并填写 `failReason`（必填）：

```bash
curl -s -X PUT "{HOST}/aibug/api/bugs/{id}/status" \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"status":"FAILED","projectId":{PROJECT_ID},"failReason":"<无法修复的具体原因>"}'
```

无法修复的常见情形：
- Bug 描述指向的文件在当前工程中不存在
- 需要修改的逻辑超出当前代码范围（依赖外部系统）
- 描述不足以确定如何修复，且无法从上下文推断

**回读验证**（必做）：PUT 后用与 3.2 相同的方式回读 `GET /bugs/{id}`，确认 `status` 为 `FIXED`、`PARTIALLY_FIXED` 或 `FAILED`；标为 `PARTIALLY_FIXED` 时还要确认回读的 `fixNote` 与提交内容一致。不一致则重试一次，仍不一致则向用户告警并保留该 Bug 的 ID、期望状态与期望 `fixNote`。

> 服务端只在对应状态下保存说明字段：`failReason` 仅 `FAILED` 保留，`fixNote` 仅 `PARTIALLY_FIXED` 保留，其余状态一律置空。因此后续把某条 `PARTIALLY_FIXED` 的 Bug 改成 `FIXED`/`RESOLVED` 时原 `fixNote` 会被清空，需要留痕的剩余问题应先另建 Bug 或在本轮汇总中记录。

### 3.5 循环至下一个 Bug

完成一个 Bug 的处理后，回到 **3.1**，继续获取下一个 PENDING Bug。

---

## 四、完成输出

所有 Bug 处理完毕后，向用户输出汇总：

```
## aibug 修复完成

共处理 Bug：N 个
  - FIXED：N 个
  - PARTIALLY_FIXED：N 个（逐条列出 #id 与 fixNote 中的"待修复"要点；无则 0）
  - FAILED：N 个（附各 Bug ID 和失败原因）
  - 项目校验不通过：N 个（逐条列出 #id 与实际 projectId；无则 0）

队列已清空，无更多 PENDING Bug。
```

- `PARTIALLY_FIXED` 的 Bug 已脱离 PENDING 队列（服务端 `/bugs/next` 只下发 `PENDING`），本轮及后续 `/aibug` 都不会再自动处理其剩余问题；需在 aibug 界面把状态改回 `PENDING` 才会重新进入队列。
- 这些剩余问题除列在本汇总外，还必须按 3.4 要求进入规范一的"人工待办"板块（`@研发`）。

---

## 五、注意事项

- 所有参数（HOST、USERNAME、PASSWORD、PROJECT_ID）均无默认值，必须由用户在每次调用时提供。
- `PROJECT_ID` 必须通过命令行 `--project-id=N` 传入；缺失时直接报错终止，不做交互询问兜底。
- 密码仅用于登录请求，不写入任何文件，不在日志中明文输出。
- `FAILED` 状态必须提供 `failReason`，`PARTIALLY_FIXED` 状态必须提供 `fixNote`，否则 API 返回 400。
- 服务端对 `status` 做枚举校验（PENDING / IN_PROGRESS / FIXED / PARTIALLY_FIXED / FAILED / RESOLVED / CLOSED），非法值返回 HTTP 400 及 `{"error": ...}`；每次 PUT 后必须检查响应中的 `error` 字段，出现则视为更新失败。
- `PARTIALLY_FIXED` 只用于"确有代码改动且已改动部分验证通过"的情形：一点未改或验证不通过一律 `FAILED`，全量修好一律 `FIXED`，禁止用它搪塞未验证的修复。
- 每次修复前先标记 `IN_PROGRESS`，确保同一 Bug 不被并发处理。
- **必须串行执行**：本 skill 全程单实例、每条 Bug 委托子 agent 逐条串行处理，禁止并行（多实例、多个子 agent 同时处理多条 Bug、与 /aicase 或 /do-test 并发均不允许）；用户要求并行时应明确拒绝并说明该约束。
- 本 skill 仅修改代码文件，不执行 `git commit`，由用户决定是否提交修复结果。
