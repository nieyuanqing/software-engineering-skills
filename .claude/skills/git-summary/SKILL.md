---
name: git-summary
description: 输出指定 git 分支从创建时间开始的精简 commit 摘要列表，默认当前分支，可指定基线分支与是否包含 merge 提交。当用户问"这个分支都改了什么"、"从建分支起做了哪些事"、"分支做了哪些提交/周报素材/发布说明/分支全貌梳理"时触发。支持 /git-summary -h 查看帮助。
---

# git-summary

给定分支（默认当前分支），列出**该分支独有**的提交摘要：分叉点、分支起始时间、逐条一行摘要、类型与作者统计。全程只读，不改动任何 git 状态。

## 零、参数处理

**如果用户传入 `-h` 或 `--help`**，不执行任何操作，直接输出以下帮助信息后结束：

```
用法: /git-summary [选项]

选项
  --branch=NAME       目标分支（可选，默认当前分支；支持本地名或 origin/xxx）
  --base=NAME         基线分支（可选，默认自动探测 origin/HEAD → main → master）
  --with-merges       列表中包含 merge 提交（可选，默认排除）
  --limit=N           只列最近 N 条（可选，正整数；表头与统计仍按全量计算，分支即基线时默认 30）
  -h, --help          显示本帮助

示例
  /git-summary                                  # 当前分支，相对默认基线
  /git-summary --branch=feature/login           # 指定分支
  /git-summary --base=develop --branch=feat/x   # 基线是 develop
  /git-summary --with-merges --limit=20
```

---

## 一、参数解析与校验

| 命令行写法 | 对应参数 |
|---|---|
| `--branch=NAME` | `BRANCH`（可选，默认当前分支） |
| `--base=NAME` | `BASE`（可选，默认自动探测） |
| `--with-merges` | `MERGE_FLAG`（可选，取 `--no-merges` 或空） |
| `--limit=N` | `LIMIT`（可选，正整数） |

- 分支位置参数也接受：`/git-summary feature/login` 等价 `--branch=feature/login`。
- **时间一律东八区**：所有 git 取时命令前置 `TZ=Asia/Shanghai`（与 common-rules 全局时间规范一致）。
- 目标与基线分支名统一先解析成可用 ref：先按原样 `git rev-parse --verify --quiet "<name>^{commit}"`，失败再依次试 `refs/heads/<name>`、`refs/remotes/origin/<name>`。
- `BRANCH` 解析不到 → 报错终止，并列出相近分支供用户选择（`git branch -a --format='%(refname:short)' | head -15`），不猜测。
- `BASE` 探测顺序（都探测不到则报错要求 `--base`）：
  1. `git symbolic-ref --short -q refs/remotes/origin/HEAD` 去掉 `origin/` 前缀；
  2. 依次 `main`、`master`，各自先试本地 `refs/heads/<b>`，再试 `refs/remotes/origin/<b>`。
- 当前目录不是 git 仓库（`git rev-parse --git-dir` 失败）→ 报错终止。
- 浅克隆（`git rev-parse --is-shallow-repository` 为 `true`）→ 先告警："浅克隆可能算不出真实分叉点"，继续执行但在输出里标注结果可能不完整；**不得**自行 `git fetch --unshallow`，需要补历史时先征得用户同意。

## 二、取值与列表

`BRANCH` 为默认当前分支时用 `git branch --show-current`；输出为空（detached HEAD）且用户未指定 `--branch` → 用 `HEAD` 并在输出里标注"当前处于游离 HEAD"。

```bash
export TZ=Asia/Shanghai

# 1. 分叉点（仅用于确定区间，不作为分支创建时间）
START=$(git merge-base "$BASE" "$BRANCH")
RANGE="$START..$BRANCH"

# 2. 分支独有提交列表（正序，一行一条）
git log $MERGE_FLAG --reverse --date=format-local:'%Y-%m-%d' \
  --pretty=format:'%h %ad %s' $RANGE

# 3. 分支起始时间 = 区间内最早一条提交的时间
git log $MERGE_FLAG --reverse --date=format-local:'%Y-%m-%d %H:%M:%S' \
  --pretty=format:'%ad' $RANGE | head -1

# 4. 统计
git rev-list --count $MERGE_FLAG $RANGE                    # 提交数
git shortlog -sn $MERGE_FLAG $RANGE | wc -l                # 作者数
git log $MERGE_FLAG --pretty=format:'%s' $RANGE \
  | sed -E 's/^([a-z]+):.*/\1/; t; s/.*/other/' \
  | sort | uniq -c | sort -rn                              # 按 commit 类型分布
```

**时间口径（强制）**：起点、跨度、列表日期一律取 **author date（`%ad`）**，不得与 committer date（`%cd`）混用——rebase、amend、`--date=` 造数据都会让两者相差很大，混用会让"分支起始时间"看着莫名其妙。

**为什么不能用 merge-base 的时间当创建时间**：分支中途同步过基线（merge/rebase `main`）后，分叉点会前进到同步进来的那条提交，其时间晚于分支真实创建时间。因此分叉点只用来划区间，**分支起始时间取区间内最早一条独有提交**。

**列表语义**：`$START..$BRANCH` 是"可从 BRANCH 到达、不可从分叉点到达"的集合，分支自己的提交全部保留，基线侧被同步进来的提交自动排除，无需再手工过滤。若 `git merge-base` 因历史被改写而算不出共同祖先，改用 `git log $BRANCH --not $BASE`（同样语义），并在输出里注明"未找到共同祖先，已按 `--not 基线` 计算"。

**分支即基线时退化**：`START` 等于 `BRANCH` 本身（`BASE` 与 `BRANCH` 是同一分支，如直接在 `main` 上执行）时，`$START..$BRANCH` 恒为空，改取整条分支历史 `git log $BRANCH`，"分支起始时间"取该分支最早一条提交，并在表头标注 `分支即基线，按整条历史输出`；此情形默认按 `--limit=30` 只列最近 30 条（用户显式传了 `--limit` 时以其为准），表头写明 `共 N 条，仅列最近 K 条`。

## 三、输出格式

```
## 分支摘要：<BRANCH>（基线 <BASE>）

分叉点：<START 短 hash> <分叉点日期>
起始时间：<区间最早提交时间>（分支独有第一条）
提交数：N 条（不含 merge；含 merge 共 M 条）｜时间跨度：<起> ~ <止>｜作者：K 人
类型分布：feat 5 · fix 3 · docs 1 · other 2

| # | commit | 日期 | 说明 |
|---|---|---|---|
| 1 | a1b2c3d | 2026-09-03 | feat: 新增 /git-summary skill |
| 2 | e4f5g6h | 2026-09-04 | fix: 修正 nginx 证书路径 |
```

- 说明列取 commit message **首行原文**，不改写、不翻译、不补全；超过 72 字符按 71 字符 + `…` 截断。
- 首行没有 `类型:` 前缀的提交照原样列出，类型分布里计入 `other`。
- 传 `--limit=N` 时按时间正序取**最近 N 条**；分支即基线的退化输出未指定 `--limit` 时按默认 30 条。两者都在表格上方标注 `共 M 条，仅列最近 N 条`，统计行仍按全量计算。
- 提交数为 0 时不输出空表格，改为一行说明（见第四节）。
- 输出后按 common-rules 规范一补：影响范围（本 skill 全程只读，写"无变更"）、人工待办（无则 `1. 无`）、开始/结束时间（东八区实测，不估算）。

## 四、边界与回退

| 情形 | 处理 |
|---|---|
| 区间 0 条（分支已合并回基线） | 不报错，输出一行：`<BRANCH> 相对 <BASE> 无独有提交（分叉点 <hash> <日期>）`，不伪造列表 |
| `BRANCH` 与 `BASE` 是同一分支（直接在 `main` 上执行） | 按第二节"分支即基线时退化"处理：取整条分支历史，默认只列最近 30 条，表头标注 `分支即基线，按整条历史输出` |
| detached HEAD 且未指定 `--branch` | 用 `HEAD`，输出表头标注"游离 HEAD（非分支）" |
| 分支基于其它特性分支创建 | 结果会包含父特性分支的独有提交；在输出末尾提示"如需只统计本分支增量，用 `--base=<父分支>` 重跑" |
| 目标分支与基线历史完全不相干（如孤儿分支） | 按 `--not 基线` 输出全量并在表头注明无共同祖先 |

## 五、注意事项

- **只读**：允许的命令限于 `git rev-parse` / `rev-list` / `log` / `show` / `merge-base` / `branch` / `shortlog` / `symbolic-ref`。禁止 `checkout`、`switch`、`fetch`、`pull`、`rebase`、`merge`、`reset`、`gc` 等任何改动工作区或仓库状态的命令；确需补历史（浅克隆）时先征得用户同意。
- 不写入任何文件，结果只输出到对话；用户明确要求导出时才写 `<分支名>-summary.md` 到当前目录并告知路径。
- 不输出 commit 正文全文与 diff，不贴大段原始日志；列表逐条只保留 `hash + 日期 + 首行`。
- 统计数字与表格必须由同一组命令产出，禁止凭记忆或估算填写；分支、区间、计数有不确定时先跑命令确认。
- 本 skill 只做"读历史、给摘要"，不判定代码质量、不做发布风险评估，也不代替用户决定是否合并。
