---
name: db-compare
description: 只读比对两个环境的 PostgreSQL 表与字段结构（字段级：类型/长度/可空/默认值），输出差异报告。源环境默认本地开发环境（--src-db=dev|test|prod），目标环境必须手动指定远程主机名（--dst-db=<主机名>，无默认值，缺失时提醒）。当用户要求"比对数据库结构/表结构差异/字段是否对齐/环境间 schema 差异核对/上线前确认表结构"时触发。全程不支持任何写操作。支持 /db-compare -h 查看帮助。
---

# db-compare

比对源环境与目标环境的**表清单 + 字段结构**，粒度到字段级，输出差异报告。全程只读：只 `SELECT information_schema.columns`，并用 `default_transaction_read_only=on` 在数据库侧强制只读。

> **执行方式：只读，不支持任何写操作。** 不生成、不执行、不建议直接运行任何 DDL/DML；比对结果需要变更时，一律交由人工在对应环境执行并复核。目标环境通过 SSH 在**远端本机**执行只读 psql（部署约定 PostgreSQL 是本机私有实例，外部不可直连），数据库口令只在远端进程内使用，不出本机、不进报告。

## 零、参数处理

**如果用户传入 `-h` 或 `--help`**，不执行任何比对，直接把下面的帮助信息**原样输出在本次回复正文里**后结束（斜杠命令把 SKILL.md 注入我的上下文不等于已展示给用户，正文里只回一句"已输出"就是没输出）：

```
用法: /db-compare --dst-db=<远程主机名> [选项]

必填（无默认值，缺失时本 skill 会停下提醒，不猜测）
  --dst-db=HOST          目标环境的远程主机名，如 --dst-db=db-prod

可选
  --src-db=ENV           源环境：dev | test | prod，默认 dev（本地开发环境）
                         dev 读 src/backend/<服务>/.env，test/prod 读 .env.test / .env.prod
  --src-host=HOST        源侧也在远程主机时使用（默认本机直连）
  --service=NAME         服务名，用于定位 src/backend/<服务>/ 与远端 /opt/soft/apps/<服务>/
                         本机只有一个后端时自动识别，多个时必须指定
  --schema=NAME          比对的 schema，默认 public
  --out=FILE             报告另存为 markdown 文件（默认只输出到对话）
  -h, --help             显示本帮助

示例
  /db-compare --dst-db=db-prod                        # 本地 dev vs 远端 prod 主机
  /db-compare --src-db=test --dst-db=db-prod          # 测试环境 vs 生产主机
  /db-compare --dst-db=db-prod --service=aibug --schema=app
  /db-compare --dst-db=db-prod --out=/tmp/schema-diff.md

边界
  - 只读：仅 SELECT information_schema，不比对数据行，不生成也不执行变更 SQL
  - 粒度：表存在性 + 字段类型/长度/精度/可空性/默认值；不比对索引、约束、
    序列、注释、触发器、权限
  - 一次比对一个 schema；多 schema 需分别执行
```

---

## 一、参数与前置检查

1. **`--dst-db` 缺失必须先提醒再停**：向用户输出
   `需要指定目标环境的远程主机名：--dst-db=<主机名>。源环境默认本地开发环境（--src-db=dev），目标环境没有默认值、不允许猜测。`
   然后结束本轮，不猜测主机、不读任何库、不用当前项目的 `deploy-conf/env.prod` 顶替。
2. `--src-db` 只接受 `dev|test|prod`，其它值直接报错，不纠正成默认值。
3. 本机可用性：`psql` 客户端必须存在；走远端时 `ssh` 必须可用。**目标主机需已配置免密登录**（脚本用 `ssh -o BatchMode=yes`，不会弹密码）；不可免密时提醒用户改用 `! ssh-copy-id <主机>` 或手工执行，不尝试任何密码交互。
4. 服务名定位：未传 `--service` 时脚本自动探测 `src/backend/*/`，唯一则用，多个则报错列出候选——此时**必须让用户指定**，不猜。
5. 环境文件必须存在可读：源侧 `src/backend/<服务>/.env`（或 `.env.test` / `.env.prod`）；目标侧固定为远端 `/opt/soft/apps/<服务>/.env`（部署时由 deploy.sh 落盘）。目标侧路径不存在时报错并提示用 `--service` 校正，**不在远端搜索或猜测路径**。

## 二、执行

统一通过本 skill 自带脚本执行，禁止手工拼 psql 命令：

```bash
bash <本 skill 目录>/scripts/db-compare.sh run \
  --src-db=<dev|test|prod> --dst-db=<主机名> [--service=<服务名>] [--schema=<名称>] [--out=<文件>]
```

脚本内部动作（按顺序）：

| 步骤 | 动作 |
|---|---|
| 1 | 本机侧：source 环境文件后 `psql -h ${DB_HOST} -p ${DB_PORT} -U $DB_USER -d $DB_NAME`，执行 `scripts/structure.sql` 导出 `表 <TAB> 字段 <TAB> 类型 <TAB> 可空 <TAB> 默认值` |
| 2 | 目标侧：`ssh <主机> bash -s`，在**远端** source 该主机的 `.env` 后执行同一份 `structure.sql`，口令不出远端 |
| 3 | 只读保证：连接两侧都带 `PGOPTIONS="-c default_transaction_read_only=on"`，且 SQL 首行再 `SET default_transaction_read_only = on` |
| 4 | 比对：表级（清单差集）+ 字段级（共有表内的字段增减、类型/可空/默认值差异），排序确定、结果可复现 |
| 5 | 输出 markdown 报告；`--out` 时同时落盘 |

其它两个模式（同一脚本，同一套逻辑）：

```bash
# 只导出一侧结构快照
bash <本 skill 目录>/scripts/db-compare.sh dump --side=src [--src-db=dev] [--service=NAME]
bash <本 skill 目录>/scripts/db-compare.sh dump --side=dst --dst-db=<主机名>

# 离线复比对两份已导出的快照（不连库）
bash <本 skill 目录>/scripts/db-compare.sh compare --src=<快照A> --dst=<快照B>
```

**退出码语义**（必须据此下结论，禁止凭输出印象判断）：

| 退出码 | 含义 | 处理 |
|---|---|---|
| 0 | 两侧表与字段结构完全一致 | 结论写"一致" |
| 1 | 存在差异 | 完整呈现报告各段差异 |
| 2 | 执行失败（参数缺失、env 不存在、psql/ssh 失败、快照为空） | 不输出结论，按报错原文说明卡点并给出待办 |

## 三、输出

报告固定六段，逐段原样呈现给用户，不改写、不合并、不省略空段（空段显示"无"）：

1. 概览：表数量（含共有张数）、字段数量
2. 结论：一致，或差异分类计数
3. 表级差异：仅源侧存在 / 仅目标侧存在
4. 字段增减（仅统计两侧共有表内的字段）
5. 字段属性差异表：`表.字段 | 源类型 | 目标类型 | 源可空 | 目标可空 | 源默认值 | 目标默认值 | 差异项`
6. 未覆盖范围

清单类每段最多渲染 40 条、差异表最多 60 行，超出提示"另有 N 条，用 `--out` 导出完整报告"——需要完整清单时用 `--out=<文件>` 再报告文件路径，不得为拼完整清单去手工 `cat` 大文件。

按 common-rules 规范一补：影响范围（**只读比对，无变更**）、人工待办（差异需谁处理，见下）、开始/结束时间（东八区实测）。差异非空时，人工待办按归属拆分：结构差异需改代码或补迁移 → `@研发` / `@DBA`；主机不可达、免密未配、权限不足 → `@运维`。

## 四、只读边界（强制）

- 允许的命令只有：`psql`（仅 `structure.sql` 这一条 SELECT）、`ssh`（仅转发该脚本）、`git rev-parse`、`basename`/`cut`/`sort`/`comm`/`join`/`awk` 等本地文本处理。
- **禁止**：任何 `CREATE/ALTER/DROP/TRUNCATE/INSERT/UPDATE/DELETE/COPY/VACUUM/GRANT`；`psql -c` 执行其它语句；导入导出业务数据；生成"同步脚本"并顺手执行；`scp`/写远端文件；建库建表建 schema；`--fix`/`--apply` 之类自动修复（本 skill 不提供）。
- 用户要求"顺手把差异补平/生成 DDL 执行掉"时：明确拒绝在本 skill 内执行，说明只读约束，把动作转成人工待办。
- 口令与连接串：只 `source` 到子进程环境，绝不 `echo`、绝不写进报告或日志；报告中主机名只出现主机名本身，不出现 `DB_PASSWORD`、不出现完整 `postgres://` 连接串。
- 不读取业务表数据，因此比对结果不含任何生产数据内容。

## 五、边界与回退

| 情形 | 处理 |
|---|---|
| 未指定 `--dst-db` | 第一节的提醒话术，停止执行 |
| 本机 `src/backend/` 下多个服务 | 报错并列出候选，要求 `--service`，不自动挑一个 |
| 源环境文件里 `DB_PASSWORD=changeme` 等占位符 | 报错提示这是模板值、需要真实开发库配置，停止（不尝试连接其它库） |
| 目标主机不可达 / 免密未配 / 远端无 psql | 报错原文摘要 + 人工待办 `@运维`，退出码 2，不降级为本机库比对 |
| 远端 `.env` 不在 `/opt/soft/apps/<服务>/` | 报错要求确认服务名；不搜索远端目录 |
| 非 PostgreSQL 库（MySQL 等） | 明确说明本 skill 只支持 PostgreSQL，停止 |
| 两侧 schema 名不同（如源 `public`、目标 `app`） | 不支持一次比对两个不同 schema 名；分别用 `--schema` 导出快照后用 `compare` 模式离线比对 |
| 共有表为 0 张 | 结论按表级差异呈现，并在结论后提示"疑似两侧不是同一套库/schema，请确认 `--src-db`、`--service`、`--schema`" |

## 六、注意事项

- 结论只能来自退出码与报告原文，禁止凭"看起来差不多"下判断；报告条目原样引用，不改写表名字段名。
- 比对结果有差异时，**不要**顺手改任何一侧的结构，也不要在报告里给出可直接执行的变更 SQL。
- 大库比对耗时主要在两侧抓取（各一次 SELECT），单侧抓取失败即终止，不做半成品报告。
- 本 skill 不写入目标工程任何文件；仅当用户显式传 `--out` 时写出报告文件。
- 快照（`dump` 模式输出）含表名与字段名，属结构信息，仍不得提交到工程仓库以外的位置；用完的临时快照自行清理。
