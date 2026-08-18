---
name: aibug
description: 连接 aibug 系统，循环自动修复 PENDING 状态的 Bug。依次执行：登录获取 token → 获取下一个 Bug → 分析代码并修复 → 更新状态（FIXED/FAILED），直到无更多待处理 Bug。必须配合 aibug 系统使用。支持 /aibug -h 查看帮助。
---

# aibug

自动连接 aibug Bug 管理系统，循环获取并修复 PENDING 状态的 Bug，直到队列为空。

**触发条件**：用户要求自动修复 Bug、接入 aibug 系统，或说"开始修 Bug"。

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
  --project-id=N      项目 ID（如 --project-id=1）
  -h, --help          显示本帮助

工作流程
  1. POST {host}/aibug/api/auth/login          登录，获取 token
  2. GET  {host}/aibug/api/bugs/next           获取下一个 PENDING Bug
  3. PUT  {host}/aibug/api/bugs/{id}/status    标记为 IN_PROGRESS
  4. 分析 Bug 内容，定位并修复代码
  5. PUT  {host}/aibug/api/bugs/{id}/status    标记为 FIXED 或 FAILED
  6. 循环回到第 2 步，直到无更多 PENDING Bug

Bug 字段说明
  id          Bug 唯一 ID
  content     Bug 描述文本（说明需要修复的内容）
  fileUrls    附件相对路径（截图等，相对于 host）
  status      当前状态：PENDING / IN_PROGRESS / FIXED / FAILED / RESOLVED / CLOSED
  failReason  失败原因（状态为 FAILED 时必填）

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

### 1.2 交互询问缺失参数

将所有未通过命令行提供的必填参数**一次性列出**，统一询问：

| 参数 | 说明 |
|---|---|
| `HOST` | aibug 系统 Base URL，如 `http://your-server:8082` |
| `USERNAME` | 登录账号 |
| `PASSWORD` | 登录密码 |
| `PROJECT_ID` | 项目 ID |

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
  "projectId": 1,
  ...
}
```

**响应**（无更多 Bug）：返回 HTTP 4xx 或空对象。遇到此情况，**退出循环**，向用户报告"所有 Bug 已处理完毕"。

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

### 3.3 分析并修复 Bug

根据 Bug 的 `content` 字段描述：

1. **理解需求**：阅读 `content`，明确需要修改什么。
2. **查看附件**：如果 `fileUrls` 不为空，用 Read 工具读取图片（URL = `{HOST}{fileUrls}`），作为辅助参考。
3. **定位代码**：根据描述在当前工程中找到需要修改的文件和位置。
4. **执行修复**：用 Edit / Write 工具修改代码，确保修改范围最小、不引入新问题。

### 3.4 更新 Bug 状态

**修复成功** → 标记为 `FIXED`：

```bash
curl -s -X PUT "{HOST}/aibug/api/bugs/{id}/status" \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"status":"FIXED","projectId":{PROJECT_ID}}'
```

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

**回读验证**（必做）：PUT 后用与 3.2 相同的方式回读 `GET /bugs/{id}`，确认 `status` 为 `FIXED` 或 `FAILED`；不一致则重试一次，仍不一致则向用户告警并保留该 Bug 的 ID 与期望状态。

### 3.5 循环至下一个 Bug

完成一个 Bug 的处理后，回到 **3.1**，继续获取下一个 PENDING Bug。

---

## 四、完成输出

所有 Bug 处理完毕后，向用户输出汇总：

```
## aibug 修复完成

共处理 Bug：N 个
  - FIXED：N 个
  - FAILED：N 个（附各 Bug ID 和失败原因）

队列已清空，无更多 PENDING Bug。
```

---

## 五、注意事项

- 所有参数（HOST、USERNAME、PASSWORD、PROJECT_ID）均无默认值，必须由用户在每次调用时提供。
- 密码仅用于登录请求，不写入任何文件，不在日志中明文输出。
- `FAILED` 状态必须提供 `failReason`，否则 API 会返回错误。
- 服务端对 `status` 做枚举校验（PENDING / IN_PROGRESS / FIXED / FAILED / RESOLVED / CLOSED），非法值返回 HTTP 400 及 `{"error": ...}`；每次 PUT 后必须检查响应中的 `error` 字段，出现则视为更新失败。
- 每次修复前先标记 `IN_PROGRESS`，确保同一 Bug 不被并发处理。
- 本 skill 仅修改代码文件，不执行 `git commit`，由用户决定是否提交修复结果。
