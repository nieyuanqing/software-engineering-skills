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
     （必填 fixNote）或 FAILED（必填 failReason）；说明字段按固定标签分行填写，
     纯文本不写 markdown 标记（弹窗按 markdown 渲染，可选贴 http/站内链接）
  6. 循环回到第 2 步，直到无更多 PENDING Bug

Bug 字段说明
  id          Bug 唯一 ID
  content     Bug 描述文本（说明需要修复的内容）
  fileUrls    附件相对路径（截图等，相对于 host）
  status      当前状态：PENDING / IN_PROGRESS / FIXED / PARTIALLY_FIXED
              / FAILED / RESOLVED / CLOSED
  failReason  失败原因（状态为 FAILED 时必填），固定三行纯文本：
              现象 / 定位 / 下一步
  fixNote     部分修复说明（状态为 PARTIALLY_FIXED 时必填），固定三行纯文本：
              已修复 / 待修复 / 验证

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
[回传状态]   PUT /aibug/api/bugs/{id}/status → 200，status=PARTIALLY_FIXED，fixNote=已修复/待修复/验证
[回读确认]   GET /aibug/api/bugs/{id} → 200，status=PARTIALLY_FIXED，fixNote 三行逐行一致
```

- 路径中 `{PROJECT_ID}`、`{id}` 替换为真实值；token 与 Authorization 头一律不出现。
- `fixNote` / `failReason` 是多行结构化字段，输出行里**只标注标签序列**（如 `fixNote=已修复/待修复/验证`），不在这里展开正文，正文由 3.4 的回读验证逐行比对。
- 非 200 或响应含 `error` 时在同一行追加一句话原因，不重试转述响应体。

### 上下文与权重控制（全程必做）

**上下文增长优化**（防止长循环撑爆上下文窗口）：

1. **子智能体隔离**：3.3 的分析与修复默认委托给子智能体（Agent 工具）执行——子智能体拥有独立上下文，定位/阅读/修改代码的完整过程不进入主循环；主循环只接收结构化结果（常规 4 行，`PARTIALLY_FIXED`/`FAILED` 追加 3 行回写字段）。
2. **响应瘦身**：所有 API 响应只保留 `id`、`content`（≤500 字，超长截断）、`fileUrls`、`status`、`fixNote`、`error` 字段；禁止把完整 JSON 原文粘进对话。
3. **台账式记录**：主循环只维护一行式台账 `#<id> → FIXED/PARTIALLY_FIXED/FAILED（PARTIALLY_FIXED 摘 fixNote 的"待修复"行、FAILED 摘 failReason 的"定位"行）`，不保留分析细节，也不在台账里重复整段回写字段。
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
- 工程根路径，以及约束：最小化修复、只改代码不执行 git commit、**修复后必须验证**、**按下方三态判定标准给出结果**、**`PARTIALLY_FIXED`/`FAILED` 必须按 3.4 的三行标签结构回写说明字段，且字段值是纯文本（这两个字段在 aibug 弹窗按 markdown 渲染，除可选的 http/站内链接外不得带任何 markdown 标记）**、无法修复时明确说明原因

**串行约束（必做）**：每条 Bug 单独委托一个子智能体，同一时刻最多只有一个子智能体在运行；当前子智能体返回结果并记入台账后，才可为下一条 Bug 启动新的子智能体，禁止同时派出多个子智能体并行修复。

要求子智能体以下列固定格式返回（常规 4 行，`修改文件` 可占多行；结果为 `PARTIALLY_FIXED` / `FAILED` 时必须追加对应的 3 行结构化回写字段），主循环只把结论记入台账，并按原样把回写字段提交给服务端，**禁止改写成一段连续文字**：

```
结果: FIXED | PARTIALLY_FIXED | FAILED
修改文件: <逐行列出；FAILED 时写 无>
验证: <验证方式> → 通过 | 失败
说明: <一句话根因>
回写字段(fixNote): <仅 PARTIALLY_FIXED，按 3.4 三行结构：已修复 / 待修复 / 验证>
回写字段(failReason): <仅 FAILED，按 3.4 三行结构：现象 / 定位 / 下一步>
```

`结果` 为 `FIXED` 时两个回写字段都省略；缺行、标签改名、把多点写成一段散文、或字段值里带 markdown 标记（加粗/行内代码/表格/引用/行首 `#`、`-`、`*`、`数字.`/空行/代码块围栏），一律视为格式不合规退回子智能体按结构重发，主循环不得自行拼句子补全或直接提交。

**三态判定标准**（写入子智能体 prompt，必须逐点核对）：把 `content` 拆成独立问题点逐条核对——

- 全部问题点均已修复且验证通过 → `FIXED`
- 仅部分问题点修复（如只覆盖一端/一条路径/一个接口，其余点未处理或需外部系统、需产品决策配合）→ `PARTIALLY_FIXED`，并按 `回写字段(fixNote)` 写满三行，`已修复` 行必须是本轮验证通过的内容
- 一点都没修复、或修复后验证不通过 → `FAILED`，并按 `回写字段(failReason)` 写满三行

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

**标记 FIXED 的前提**：该 Bug 的验证已在**本轮修复后即刻完成**（不是全部修完后统一验证），且子智能体结果同时满足 `结果: FIXED` 与 `验证: 通过`。若 `验证: 失败`，退回子智能体追加修复一轮（携带失败现象），复验仍失败则标记 `FAILED`，`failReason` 按下文三行结构填写，`现象` 行写"修复后复验未通过：<验证方式与失败现象>"。

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
  -d '{"status":"PARTIALLY_FIXED","projectId":{PROJECT_ID},"fixNote":"已修复：<…>\n待修复：<…>\n验证：<…> → 通过"}'
```

**无法修复** → 标记为 `FAILED`，并填写 `failReason`（必填）：

```bash
curl -s -X PUT "{HOST}/aibug/api/bugs/{id}/status" \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"status":"FAILED","projectId":{PROJECT_ID},"failReason":"现象：<…>\n定位：<…>\n下一步：<…>"}'
```

#### 说明字段结构化写法（`fixNote` / `failReason` 通用，必做）

**禁止把多处信息揉进一段连续文字**，两个字段都按固定标签分行书写。aibug 查看弹窗对这两个字段（含 Bug `content`）走 **markdown 渲染**（`react-markdown` + `remark-gfm` + `remark-breaks`），因此字段值要同时满足下面三组规则。

**分行结构**：

- 一行一个标签，标签固定不可改名、不可省略、不可合并；一行只写一件事
- 值内用**单个 `\n`** 分行提交（JSON 里写 `\n`）即可断行——`remark-breaks` 已生效，**不需要**行尾补两个空格，也不需要加空行
- 单行 ≤60 字符、整体 ≤200 字符（按字符数，含路径与接口名；markdown 链接语法里的地址不计入单行 60 字符，但仍计入 200 字符总长）；只写问题点级别的事实，不贴代码、不写排查过程叙述
- 位置与接口写成 `文件:行`（如 `BugServiceImpl.java:88`）、`GET /api/bugs` 这类**裸文本**，不用反引号包裹
- 列表页的说明行仍是单行截断纯文本（不走 markdown），因此第一行（`已修复` / `现象`）必须单独看懂，不能依赖后两行才成立

**markdown 规避**（以下按实测渲染结果给出，写错比一段散文更乱）：

- 禁止 markdown 标记语法：`**加粗**` 渲染成粗体、反引号渲染成行内代码、`|` 渲染成表格（叠加 `remark-breaks` 还会把表格行打断）、`>` 渲染成引用块、成对的 `*` 或 `_` 渲染成斜体、`~~x~~` 渲染成删除线。字段值一律裸文本，不为"好看"加任何标记
- 禁止行首 `#` + 空格（`# 165 …`、`## 待修复 …`）：实测渲染成一级/二级大标题。`#165 修复…`（`#` 紧跟字符）实测仍是正文，但为免误加空格，Bug ID 统一放行内（`已修复：#165 …`）或写 `Bug 165`
- 禁止行首 `-`、`+`、`*`、`数字.`：实测解析成列表项，缩进错位；`待修复` / `下一步` 行的多个并列点仍在**同一行内**用 `；` 分隔，不要改写成 markdown 列表
- 禁止代码块围栏（连续三个反引号）：整段渲染成 `<pre><code>` 黑底块，还会把缩进带进弹窗
- 禁止空行：连续两个 `\n` 会切成两个 `<p>`、段间距把三行撑散；一个标签行内也不许有裸换行
- 尖括号不必回避，但注意自动链接形态：实测 `<500ms`、`a<b`、甚至 `<b>加粗</b>` 都会被转义成正文字面显示（组件未启用 raw HTML），不会被吞；只有 `<https://example.com/x>` 这种尖括号包 URL 的写法会变成自动链接。要写地址就用下面"允许且建议使用"的 markdown 链接语法
- 两处下划线/星号分别出现在不同标签行也不会配对成斜体（实测 `deleted_flag` 跨行两例仍为正文），但同一行内成对就会，命名尽量只用下划线连接、不加对仗符号

**允许且建议使用**：`待修复` / `下一步` 行可以贴 markdown 链接指向复现截图或外部工单，如 `[复现截图](/images/202608/xxx.png)`——实测渲染成 `<a href="/images/202608/x.png">`（相对路径原样保留进 href），弹窗内新窗口打开（组件已带 `rel="noopener noreferrer"`）；`/images/` 由 nginx 三套环境统一指向 `/data/aibug/images/`，站内相对路径可直接用。**禁止** `javascript:`、`data:` 与 base64 内联图：组件的 URL 过滤只放行 `http/https/irc/ircs/mailto/xmpp` 与相对路径，实测 `[点我](javascript:alert(1))` 渲染成空 `href`、base64 内联图渲染成空 `src` 的 `<img>`（浏览器还会报空 src 警告），点了没反应还白占 200 字符预算。

`fixNote` 固定三行：

| 行 | 标签 | 内容 |
|---|---|---|
| 1 | `已修复` | 问题点 → 改动位置（`文件:行` / 接口 / 页面），只写本轮已验证通过的部分 |
| 2 | `待修复` | 未覆盖的问题点 → 未做原因（缺文件 / 依赖外部系统 / 需产品确认），禁止写"其余部分"这类空话 |
| 3 | `验证` | 验证方式 → 通过 |

`failReason` 固定三行：

| 行 | 标签 | 内容 |
|---|---|---|
| 1 | `现象` | 复现出的失败表现，或本轮复验失败的具体现象 |
| 2 | `定位` | 阻塞原因 → 涉及位置。常见情形：Bug 指向的文件在当前工程不存在 / 逻辑超出当前代码范围（依赖外部系统）/ 描述不足以确定如何修复 |
| 3 | `下一步` | 需要谁提供什么才能继续修复（如 `@运维 提供 xx 配置`、`@产品 确认 xx 规则`） |

示例（`fixNote`）：

```
已修复：列表分页 total 计算 -> BugServiceImpl.java:88 改为按过滤后条件统计
待修复：页码越界未处理 -> 需前端分页组件同步改造（[复现截图](/images/202608/x.png)）
验证：curl GET /bugs?projectId=1 翻到越界页码 -> 通过（返回空列表不再 500）
```

示例（`failReason`）：

```
现象：导出接口 500，日志报 unknown column deleted_flag
定位：本工程无 deleted_flag 字段，表结构由外部库维护 -> OrderMapper.xml:41
下一步：@DBA 确认线上表是否已有 deleted_flag，或提供建表语句
```

- 每个 `PARTIALLY_FIXED` 的 Bug，要把 `待修复` 那一行原样列入本次任务的**人工待办**清单（common-rules 规范一"人工待办"板块），标注 `#<id>`，`@角色` 按该行点名的归属填写，未点名时默认 `@研发`

**回读验证**（必做）：PUT 后用与 3.2 相同的方式回读 `GET /bugs/{id}`，确认 `status` 为 `FIXED`、`PARTIALLY_FIXED` 或 `FAILED`；标为 `PARTIALLY_FIXED` / `FAILED` 时还要逐行确认回读的 `fixNote` / `failReason` 与提交内容一致、三个标签行齐全未塌成一行。服务端存的是提交原文（markdown 只在展示端渲染），逐行比对按原文即可；带链接的字段，另在 aibug 查看弹窗确认链接可点开、没有被解析成标题/列表/代码块。不一致则重试一次，仍不一致则向用户告警，并保留该 Bug 的 ID、期望状态与缺失或被改动的标签行。

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
  - PARTIALLY_FIXED：N 个（逐条列出 #id 与 fixNote 的 `待修复` 行原文；无则 0）
  - FAILED：N 个（逐条列出 #id 与 failReason 的 `现象` + `下一步` 行原文；无则 0）
  - 项目校验不通过：N 个（逐条列出 #id 与实际 projectId；无则 0）

队列已清空，无更多 PENDING Bug。
```

- 汇总里引用说明字段时只摘对应标签行的原文，禁止把三行改写成一段叙述。
- `PARTIALLY_FIXED` 的 Bug 已脱离 PENDING 队列（服务端 `/bugs/next` 只下发 `PENDING`），本轮及后续 `/aibug` 都不会再自动处理其剩余问题；需在 aibug 界面把状态改回 `PENDING` 才会重新进入队列。
- `fixNote` 的 `待修复` 行与 `failReason` 的 `下一步` 行产生的事项，一律进入规范一的"人工待办"板块；行首 `@角色` 按该行点名的归属填写（如 `@DBA`、`@运维`、`@产品`），未点名归属时默认 `@研发`。

---

## 五、注意事项

- 所有参数（HOST、USERNAME、PASSWORD、PROJECT_ID）均无默认值，必须由用户在每次调用时提供。
- `PROJECT_ID` 必须通过命令行 `--project-id=N` 传入；缺失时直接报错终止，不做交互询问兜底。
- 密码仅用于登录请求，不写入任何文件，不在日志中明文输出。
- `FAILED` 状态必须提供 `failReason`，`PARTIALLY_FIXED` 状态必须提供 `fixNote`，否则 API 返回 400。
- `fixNote` / `failReason` 一律按 3.4 的三行标签结构回写（值内用单个 `\n` 分行），禁止写成一段连续文字。
- 这两个字段在 aibug 查看弹窗按 **markdown 渲染**，字段值必须是纯文本标签行：不写 markdown 标记（粗体、行内代码、表格、引用、成对 `*`/`_`、删除线），行首不用 `#`+空格与 `-`、`+`、`*`、`数字.`，不写空行与代码块围栏；尖括号本身安全（raw HTML 会被转义成正文），但 `<url>` 形态会变成自动链接，写地址统一用 markdown 链接语法，且只允许 `http/https` 或站内相对路径。
- 服务端对 `status` 做枚举校验（PENDING / IN_PROGRESS / FIXED / PARTIALLY_FIXED / FAILED / RESOLVED / CLOSED），非法值返回 HTTP 400 及 `{"error": ...}`；每次 PUT 后必须检查响应中的 `error` 字段，出现则视为更新失败。
- `PARTIALLY_FIXED` 只用于"确有代码改动且已改动部分验证通过"的情形：一点未改或验证不通过一律 `FAILED`，全量修好一律 `FIXED`，禁止用它搪塞未验证的修复。
- 每次修复前先标记 `IN_PROGRESS`，确保同一 Bug 不被并发处理。
- **必须串行执行**：本 skill 全程单实例、每条 Bug 委托子 agent 逐条串行处理，禁止并行（多实例、多个子 agent 同时处理多条 Bug、与 /aicase 或 /do-test 并发均不允许）；用户要求并行时应明确拒绝并说明该约束。
- 本 skill 仅修改代码文件，不执行 `git commit`，由用户决定是否提交修复结果。
