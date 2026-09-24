#!/bin/bash
# <SERVICE_NAME> 等微服务的数据库增量升级 / 差集查询
#
# 与 deploy.sh --target db 的分工：本脚本只做「增量补齐」，永不 DROP、永不重建、永不恢复备份。
# 已应用与否不查任何记账表，而由每个迁移文件头部的 `-- @probe:` 探测语句对目标库现问现答。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS_ROOT="$REPO_ROOT/deploy-conf/db/migrations"
RECORD_ROOT="$REPO_ROOT/deploy-conf/db/migrate-records"   # 运行留痕：按环境分文件，只写本地
BACKEND_ROOT="$REPO_ROOT/src/backend"
APP_ROOT="${APP_ROOT:-/opt/soft/apps}"    # 远端应用根目录，与 deploy.sh 保持一致

# ==============================================================================
# 在册微服务（必须与 scripts/deploy.sh 顶部服务表的 SERVICES 一致）
# 每个服务一个独立迁移目录 deploy-conf/db/migrations/<服务>/，各连自己 .env 里的库。
# ==============================================================================
SERVICES=("<SERVICE_NAME>")
DEFAULT_SERVICES="$(IFS=','; printf '%s' "${SERVICES[*]}")"
# ==============================================================================

MODE="apply"                              # apply | query
ASSUME_YES=0
CONFIRM_PROD=0
INCLUDE_UNPROBED=0
NO_REPORT=0
REMOTE_HOST=""
DEPLOY_ENV="dev"
SERVICE_SELECTION="$DEFAULT_SERVICES"
ONLY_FILTERS=""
LIST_SERVICES=0

TARGET_DESC=""
OFFLINE=0                                 # -q 且目标库不在本机又没给 -r：只复读本地留痕，不询问任何库
RECORD_FILE=""
RECORD_REL=""
RECORD_WRITTEN=0

RUN_ARGV="$0 $*"                           # 留痕里记本次命令
LAST_ERROR=""                             # fail() 写入，供留痕记结论
declare -A IDENT                          # 服务 → 库身份指纹（报告与留痕都要看）
EXEC_LIST=""                              # 本次实际执行的文件
PENDING_LIST=""                           # 本次判为待应用的文件
OFF_TS=""                                 # 离线答复照录的那次问库时刻（取自留痕最后一节标题）
OFF_APPLIED=0; OFF_PENDING=0; OFF_MANUAL=0; OFF_IDEM=0; OFF_UNKNOWN=0; OFF_ROWS=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [db-migrate.sh] $*"
}

log_step() {
    echo
    log "$*"
}

# 报告行：既打到终端，也收进留痕缓冲（终端表格与留痕文件逐字一致）
emit() {
    printf '%s\n' "$*"
    printf '%s\n' "$*" >>"$REC_TMP"
}

warn() {
    log "WARN: $*"
}

fail() {
    LAST_ERROR="$*"
    log "错误: $*"
    if [ -n "${REC_TMP:-}" ]; then
        write_record || true
    fi
    echo "[STATUS] ERROR - 数据库增量升级失败：$*$(rec_note)"
    exit 1
}

status_ok() {
    echo "[STATUS] OK - $*"
}

# 只有真写了留痕才在 [STATUS] 行尾附路径（--no-report 时不提，免得指着一个没动的文件说"留痕在此"）
rec_note() {
    if [ "$RECORD_WRITTEN" -eq 1 ]; then
        printf '；留痕 %s' "$RECORD_REL"
    fi
}

# 结尾总结里的留痕说明：写没写、写到哪
rec_written_note() {
    if [ "$RECORD_WRITTEN" -eq 1 ]; then
        printf '；留痕已追加到 %s' "$RECORD_REL"
    elif [ "$NO_REPORT" -eq 1 ]; then
        printf '；本次按 --no-report 未写留痕'
    else
        printf '；本次未写留痕'
    fi
}

# 示例命令里该不该带 -r：远端要带、本机不带。
# 必须用 if 而不是 `[ cond ] && printf`——后者条件不成立时整条返回 1，
# 被 `var=$(...)` 接住后 set -e 会把脚本静默终止（总结块就是这样在 dev 上打不出来的）。
remote_flag() {
    if [ -n "$REMOTE_HOST" ]; then
        printf ' -r %s' "$REMOTE_HOST"
    fi
}

# 「下一步」给的示例命令必须与本次范围一致：漏掉 --only／-s 会让人照着敲出一次更大范围的执行
scope_flags() {
    local f out=""
    if [ "$SERVICE_SELECTION" != "$DEFAULT_SERVICES" ]; then
        out="$out -s $SERVICE_SELECTION"
    fi
    for f in $ONLY_FILTERS; do          # 有意不加引号：这里就是要按空格拆成多个 --only
        out="$out --only $f"
    done
    if [ "$INCLUDE_UNPROBED" -eq 1 ]; then
        out="$out --include-unprobed"
    fi
    printf '%s' "$out"
}

# 有「需人工」文件才提一句，为 0 时不制造噪音
manual_note() { # $1=需人工个数
    if [ "${1:-0}" -gt 0 ]; then
        printf '；另有需人工 %s 个，脚本一律不代跑（判据写在各文件头部）' "$1"
    fi
}

usage() {
    cat <<'EOF'
Usage:
  bash scripts/db-migrate.sh [OPTIONS]
  -h, --help    显示本帮助

迁移层脚本：只认 deploy-conf/db/migrations/<服务>/V<n>__*.sql 与文件头部的 `-- @probe:`，
判「已应用／待应用／需人工」，按版本号升序逐服务增量执行，并给每次真问过库的运行留一节本地留痕。
  · 本脚本自己不连库：问库与写库一律回调执行层 scripts/db-sql.sh（取口令、拼 ssh、起 psql 只在那一处）。
  · 永不 DROP、永不重建、永不从备份恢复——那是 scripts/deploy.sh --target db 的动作，误用即毁库。
  · 本脚本没有 --apply（为什么见第七节）。

一、模式：一个轴一个开关，互不重叠
  -q, --query         只读差集报告。逐文件一行 + 判定汇总 + 待应用文件单列成清单，全程不写库。
  （不加 -q）          增量执行。只跑「待应用」与「重复执行」两类，跑前交互确认（-y 跳过）；失败即中止后续文件。
  --list-services     打印 目标机→服务→迁移目录→env 文件 的映射后退出，不连库。
  没有 --dry-run：它给出的「将要执行的清单」就是 -q 报告末尾单列的那份待应用清单，两份实现只会互相漂移。
    要先看再跑，就 `-q` 看完再照它「下一步」给的那条 `--yes` 敲。

二、连哪台库：-e 只挑配置文件，主机一律由 -r 决定
  -e, --env dev       默认。读 src/backend/<服务>/.env，连该文件里写的那台库
      test|prod       库在远端：必须显式给 -r，读的是那台机上的 /opt/soft/apps/<服务>/.env
  -r, --remote USER@HOST
                      唯一能把动作指向远端的参数（不给就只碰本机库）。ssh 上去只为取连接参数；
                      SQL 经 ssh 标准输入流式喂给远端 psql，远端不落 .sql、不留任何文件。
  为什么不替你把 `-e test` 自动连到某台 test 机：连哪台机必须是显式说出来的参数，
    脚本内不登记任何目标机——省得一次环境参数的改动把写操作打到别的库上。
  为什么也不能「没给 -r 就照本机 .env.test 连」：那份文件里的 DB_HOST=127.0.0.1 说的是 test 那台机
    自己，在 dev 机器上照它连到的是 dev 库，报告与 dev 一字不差——那是假绿。
  所以缺 -r 时按模式分两种处置：
    -q                 不拒绝，走**离线答复**：不连任何库，只把本地留痕
                       deploy-conf/db/migrate-records/<env>.md 的最后一节（＝最近一次真问过该库的那次）
                       照录成逐文件表并写明快照时刻；留痕里没有的文件判「离线未知」
    增量执行           在连库前直接拒绝：判定与写入都必须现问那个库，加 -r 再来

三、范围
  -s, --services a,b  要处理的服务，默认脚本顶部 SERVICES 表里的全部；迁移目录名与服务目录名一致。
  --only <V9|<服务>/V9|<服务缩写>/V22|文件名>
                      只处理指定文件，可重复。不同服务的库可以有同号版本（两边都有 V9），裸版本号会
                      同时命中并 WARN；只跑其中一个服务的那条就带服务名（服务名前缀能唯一匹配即可，
                      全名、完整文件名都可）。服务名前缀写错或不唯一直接报错，不会静默匹配不到。
  --include-unprobed  把「未标注 @probe」的文件一起执行（默认拒绝，宁可漏跑也不猜）。

四、护栏与留痕
  -y, --yes           跳过交互确认。目标库在远端时的写操作必须带（只读 -q 不需要）。
      --confirm-prod  prod 的第二把锁：prod 增量执行需 --yes 与 --confirm-prod 同时给出，缺其一即拒。
      --no-report     本次不写留痕。默认每次真问过库的运行都往 deploy-conf/db/migrate-records/<env>.md
                      追加一节（命令、库身份指纹、判定表、汇总、本次执行清单）；离线答复不构成一次问答，
                      不写留痕。凭据一律不写进去，目标机上也不留文件。

五、文件头探测行（与 `-- V21: 标题` 写在同一处）
  -- @probe: SELECT ...   返回 >0 即判「已应用」；一个文件可写多条，全部命中才算已应用。
  -- @probe: idempotent   判「重复执行」（判定列的写法；表末汇总那一行把它写成「每次执行」，同一个东西）。
                        文件自带 IF NOT EXISTS / NOT EXISTS 预检，重复安全，每轮都跑。
  -- @probe: manual       判「需人工」，永不自动执行（踢连接、改库名、清垃圾、涉资金回补一类）。
  缺 @probe 行            判「未标注」，增量执行默认跳过它；要跑请显式加 --include-unprobed。
  判定共六态：已应用／待应用／需人工／重复执行／未标注／探测出错（离线答复另加「离线未知」）。
  「探测出错」的行永不进执行清单（判定不可信）；本轮若只剩这类文件，脚本直接报错要求先修探测语句。

六、报告与留痕的列（-q 的输出与留痕里的表同构）
  标记 | 服务 | 版本 | 文件 | 判定 | 脚本执行 | 生成时间
    标记      `>>` ＝ 待应用，本脚本唯一会自动执行的一类；用纯 ASCII，不用颜色码（免得污染留痕）
    脚本执行   本脚本最近一次跑过该文件的时刻，取自本地留痕；没跑过显示 —
    生成时间   该 .sql 在本机磁盘上的落地时刻（东八区取 mtime）
  不输出历次运行清单；「探测出错」的报错文本单独列在表末一块里，不藏在行内。

七、与执行层 scripts/db-sql.sh 的分工（别把两边的开关混着敲）
  本脚本**没有 --apply**：写库是增量执行时由本脚本内部回调 `db-sql.sh --apply -f <文件>` 完成的，
    那个参数不进本脚本的命令行；敲 `db-migrate.sh --apply` 只会得到「未知参数」。
  要手工跑单个 SQL、非 V 号的订正文件，或 `@probe: manual` 那一类 → 走执行层：
      bash scripts/db-sql.sh -e dev -s <服务> --apply -f <文件>
  执行层**没有 -q**：读是它的默认（连上即数据库侧强制 default_transaction_read_only=on），
    写只有 --apply 这一条显式路径——一个轴一个开关，不重复声明。
  执行层也**没有输出排版参数**：只出 psql 结果表，本脚本 run_sql 自己剥掉表头两行与 (N rows)
    收尾并 trim 两端空白，故问库的 SQL 一律写成单列。
  prod 写：执行层默认拒跑，只接受已持双确认锁的调用方传 --prod-approved；双确认的判定只在本脚本这一处。

Examples:
  bash scripts/db-migrate.sh -q                                    # 本机 dev 还差哪些增量（只读）
  bash scripts/db-migrate.sh                                       # 本机 dev 增量升级（跑前要确认）
  bash scripts/db-migrate.sh -e test -r <user@host> -q             # 现问 test 库差集（只读，不需 --yes）
  bash scripts/db-migrate.sh -e test -q                            # 离线看上次问出来的结果（纯本地，不连库）
  bash scripts/db-migrate.sh -e test -r <user@host> --yes --only <服务>/V9
                                                                   # 只升某个服务的 V9（同号别的服务那条不动）
  bash scripts/db-migrate.sh -r <user@host> -q -s <服务>           # 只查一个服务的差集
  bash scripts/db-migrate.sh -e prod -r <user@host> --yes --confirm-prod   # prod 双确认
EOF
}

# ── Phase 1: 参数解析与护栏 ───────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        -q|--query) MODE="query"; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        --confirm-prod) CONFIRM_PROD=1; shift ;;
        --include-unprobed) INCLUDE_UNPROBED=1; shift ;;
        --no-report) NO_REPORT=1; shift ;;
        --list-services) LIST_SERVICES=1; shift ;;
        -e|--env) [ $# -ge 2 ] || fail "$1 需要参数 dev|test|prod"; DEPLOY_ENV="$2"; shift 2 ;;
        --env=*) DEPLOY_ENV="${1#*=}"; shift ;;
        -s|--services) [ $# -ge 2 ] || fail "$1 需要参数 a,b"; SERVICE_SELECTION="$2"; shift 2 ;;
        --services=*) SERVICE_SELECTION="${1#*=}"; shift ;;
        -r|--remote) [ $# -ge 2 ] || fail "$1 需要参数 USER@HOST"; REMOTE_HOST="$2"; shift 2 ;;
        --remote=*) REMOTE_HOST="${1#*=}"; shift ;;
        --only) [ $# -ge 2 ] || fail "--only 需要参数（V编号或文件名）"; ONLY_FILTERS="$ONLY_FILTERS $2"; shift 2 ;;
        --only=*) ONLY_FILTERS="$ONLY_FILTERS ${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "未知参数: $1（bash scripts/db-migrate.sh -h 看帮助）" ;;
    esac
done

case "$DEPLOY_ENV" in
    dev|test|prod) ;;
    *) fail "--env 只支持 dev|test|prod，收到: $DEPLOY_ENV" ;;
esac

if [ "$LIST_SERVICES" -eq 0 ] && [ "$DEPLOY_ENV" = "prod" ] && [ "$MODE" = "apply" ]; then
    if [ "$ASSUME_YES" -ne 1 ] || [ "$CONFIRM_PROD" -ne 1 ]; then
        fail "prod 增量升级必须同时给 --yes 与 --confirm-prod（当前缺其一，拒绝执行）"
    fi
fi

valid_service() {
    local want="$1" known
    for known in "${SERVICES[@]}"; do
        [ "$want" = "$known" ] && return 0
    done
    return 1
}

RESOLVED_SCOPE=""                         SCOPE_HINT=""
SCOPE_AMBIGUOUS=0
# --only 的服务名前缀：接受全名，也接受能**唯一**匹配到在册服务的前缀缩写（如 de→demo-service）。
# 结果写全局 RESOLVED_SCOPE，供调用方在**顶层**拼进 fail 文本——绝不在 $(...) 里调 fail，
# 那样只终止子 shell，报错会被当成变量值吞掉（本仓库脚本统一用这个口径返回字符串）。
resolve_scope() { # $1=前缀 → 置 RESOLVED_SCOPE / SCOPE_HINT / SCOPE_AMBIGUOUS
    local want="$1" svc hit="" n=0
    RESOLVED_SCOPE="" SCOPE_HINT="" SCOPE_AMBIGUOUS=0
    for svc in "${SERVICES[@]}"; do
        if [ "$svc" = "$want" ]; then
            RESOLVED_SCOPE="$svc"
            return 0
        fi
    done
    for svc in "${SERVICES[@]}"; do
        case "$svc" in
            "$want"*) hit="$svc"; n=$((n + 1)) ;;
        esac
    done
    if [ "$n" -eq 1 ]; then
        RESOLVED_SCOPE="$hit"
        return 0
    fi
    if [ "$n" -gt 1 ]; then
        SCOPE_AMBIGUOUS=1
        SCOPE_HINT="前缀「$want」同时匹配到 ${SERVICES[*]} 里的多个服务，请写全服务名"
        return 1
    fi
    SCOPE_HINT="服务名前缀「$want」不在册，可选：${SERVICES[*]}"
    return 1
}

# 与 deploy.sh resolve_env_file 同规则：dev→.env，其余 .env.<env>，缺失回退 .env
local_env_file() {
    local base_dir="$BACKEND_ROOT/$1"
    if [ "$DEPLOY_ENV" != "dev" ] && [ -f "$base_dir/.env.$DEPLOY_ENV" ]; then
        echo "$base_dir/.env.$DEPLOY_ENV"
    else
        echo "$base_dir/.env"
    fi
}

remote_env_file() { echo "$APP_ROOT/$1/.env"; }
migrations_dir() { echo "$MIGRATIONS_ROOT/$1"; }

# 远端只认显式 --remote：脚本不猜、不登记、不会因为 -e test 就去连某台机。
# 而未给 --remote 时本机也没有 test/prod 库（那两份 env 里的 127.0.0.1 指那台机自己），照连就连到 dev 库出假绿。
if [ "$DEPLOY_ENV" != "dev" ] && [ -z "$REMOTE_HOST" ] && [ "$LIST_SERVICES" -eq 0 ]; then
    if [ "$MODE" = "query" ]; then
        OFFLINE=1                         # 查询可以纯本地答复（复读留痕），不碰任何数据库
    else
        fail "-e $DEPLOY_ENV 的库不在本机，升级必须显式指定远端：加 -r/--remote <user@host>（只想看差集可以 -e $DEPLOY_ENV -q，纯本地答）"
    fi
fi
if [ -n "$REMOTE_HOST" ]; then
    TARGET_DESC="ssh $REMOTE_HOST（显式 --remote）"
elif [ "$OFFLINE" -eq 1 ]; then
    TARGET_DESC="离线（本机无 $DEPLOY_ENV 库，只答本地留痕）"
else
    TARGET_DESC="本机直连（dev 库在本机）"
fi
RECORD_FILE="$RECORD_ROOT/$DEPLOY_ENV.md"
RECORD_REL="${RECORD_FILE#"$REPO_ROOT"/}"
# 目标是远端库（只认显式 --remote）时，写操作必须非交互确认过；--list-services 不连库，豁免
if [ "$LIST_SERVICES" -eq 0 ] && [ -n "$REMOTE_HOST" ] && [ "$MODE" = "apply" ] && [ "$ASSUME_YES" -ne 1 ]; then
    fail "$DEPLOY_ENV 的库在 $REMOTE_HOST 上，写操作必须加 --yes（先跑 -q 看差集再决定）"
fi

IFS=',' read -r -a SERVICE_LIST <<<"$SERVICE_SELECTION"
if [ "${#SERVICE_LIST[@]}" -eq 0 ]; then
    fail "--services 为空"
fi
for svc in "${SERVICE_LIST[@]}"; do
    valid_service "$svc" || fail "未知服务: $svc（在册：${SERVICES[*]}）"
    [ -d "$(migrations_dir "$svc")" ] || fail "缺少迁移目录: $(migrations_dir "$svc")"
done

if [ "$LIST_SERVICES" -eq 1 ]; then
    log "目标 [$DEPLOY_ENV]：$TARGET_DESC"
    printf '%-16s %-46s %-46s %s\n' "服务" "迁移目录" "本地 env（$DEPLOY_ENV）" "取连接参数用的 env"
    for svc in "${SERVICE_LIST[@]}"; do
        if [ -n "$REMOTE_HOST" ]; then
            printf '%-16s %-46s %-46s %s\n' "$svc" "$(migrations_dir "$svc")" \
                "$(local_env_file "$svc")" "$REMOTE_HOST:$(remote_env_file "$svc")"
        else
            printf '%-16s %-46s %-46s %s\n' "$svc" "$(migrations_dir "$svc")" \
                "$(local_env_file "$svc")" "本机 $(local_env_file "$svc")"
        fi
    done
    exit 0
fi

ERR_TMP="$(mktemp)"
PLAN_TMP="$(mktemp)"
DUP_TMP="$(mktemp)"
REC_TMP="$(mktemp)"                       # 本次报告行，退出前落到 deploy-conf/db/migrate-records/<env>.md
trap 'rc=$?; write_record || true; rm -f "$ERR_TMP" "$PLAN_TMP" "$DUP_TMP" "$REC_TMP"; exit $rc' EXIT

# 留痕：只写本地仓库内的 deploy-conf/db/migrate-records/<env>.md，一次运行追加一节；远端机器上不留任何文件。
# 内容只有判定结果与库身份，凭据（口令、DSN 密码段）一律不写。
write_record() {
    if [ "$NO_REPORT" -eq 1 ] || [ ! -s "$REC_TMP" ]; then
        return 0
    fi
    mkdir -p "$RECORD_ROOT" || return 0
    local stamp target conclusion r_service r_name
    local f="$RECORD_FILE"
    stamp="$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')"
    target="$TARGET_DESC"
    if [ -n "$LAST_ERROR" ]; then
        conclusion="失败 - $LAST_ERROR"
    elif [ "$MODE" = "query" ]; then
        conclusion="只读查询（未写库）"
    else
        conclusion="已执行 $N_EXECUTED 个文件"
    fi
    local pre_exists=1
    [ -f "$f" ] && pre_exists=0
    {
        if [ "$pre_exists" -eq 1 ]; then
            printf '# 数据库增量升级留痕（env=%s）\n\n' "$DEPLOY_ENV"
            printf '> 由 scripts/db-migrate.sh 自动追加：一次运行一节，**只写本地、不在目标机上留任何文件**；判定不入库、不建记账表（凭据也不入本文件）。\n'
        fi
        printf '\n---\n\n'
        printf '## %s · %s · %s · 服务 %s\n\n' "$stamp" "$DEPLOY_ENV" "$target" "$SERVICE_SELECTION"
        printf -- '- 命令：`%s`\n' "$RUN_ARGV"
        printf -- '- 结论：%s\n' "$conclusion"
        printf -- '- 取连接参数自：%s\n' "$TARGET_DESC"
        local s
        for s in "${SERVICE_LIST[@]}"; do
            if [ -n "${IDENT[$s]+x}" ]; then
                printf -- '- 库身份 [%s]：%s\n' "$s" "${IDENT[$s]}"
            fi
        done
        printf -- '- 汇总：%s\n' "$(summary_text)"
        if [ -n "$PENDING_LIST" ]; then
            printf -- '- 待应用清单（%s 个，按执行顺序）：\n' "$N_PENDING"
            while IFS=$'\t' read -r r_service r_name; do
                [ -n "$r_service" ] || continue
                printf '    - `%s/%s`\n' "$r_service" "$r_name"
            done <<<"$(pending_paths)"
        fi
        if [ -n "$EXEC_LIST" ]; then
            printf -- '- 本次执行：%s\n' "$EXEC_LIST"
        fi
        printf '\n'
        cat "$REC_TMP"
    } >>"$f"
    log "留痕已写入：$RECORD_REL（命令／结论／库身份／判定表；--no-report 可关闭）"
    RECORD_WRITTEN=1
    NO_REPORT=1
}

# 离线答复：目标库不在本机、又没给 -r 时的 -q。它不拒绝也不连任何库，只复读本地留痕——
# 「还差哪些迁移」的真答案在目标库里，离线只能答"上次问出来的结果"，所以每行都要标出处。
last_record_section() { # 输出 $RECORD_FILE 最近一节的正文；没有留痕返回 1
    [ -s "$RECORD_FILE" ] || return 1
    awk '/^## /{hit=1; body=""} hit{body=body $0 "\n"} END{if (!hit) exit 1; printf "%s", body}' "$RECORD_FILE"
}

offline_table() { # $1=上次问库那节的正文：按本目录现有文件逐个显示"上次问库判成什么 + 本脚本有没有跑过它"
    local sec="$1" service name key missing=0 svc nm vd
    local -A OV
    while IFS=$'\t' read -r svc nm vd; do
        [ -n "$nm" ] || continue
        OV["$svc/$nm"]="$vd"
    done < <(printf '%s\n' "$sec" | awk -v svc_list="$DEFAULT_SERVICES" '
        function known_service(col,    i) {
            for (i = 1; i <= n_svc; i++) if (col == svc[i]) return 1
            return 0
        }
        BEGIN { n_svc = split(svc_list, svc, ",") }
        /\.sql[[:space:]]/ {
            # 行格式兼容：新格式有前导「标记」列（>> 或空白），旧格式没有 ⇒ 用偏移 o 统一取字段
            o = ($1 == ">>") ? 2 : 1
            if (!known_service($o)) next
            if ($(o + 2) !~ /\.sql$/) next
            printf "%s\t%s\t%s\n", $o, $(o + 2), $(o + 3)
        }')
    printf '\n%s\n' "全部增量 sql 及其执行情况（判定照录 ${OFF_TS} 那次问库的结果，不是 ${DEPLOY_ENV} 库此刻的状态；生成时间取本目录文件的当前时刻）："
    table_file_width only
    W_VD=12                                   # 本表的表头是「判定（上次）」，比现问表宽 4 列，整表同宽
    printf '%s\n' "$(trow "标记" "服务" "版本" "文件" "判定（上次）" "脚本执行" "生成时间")"
    for service in "${SERVICE_LIST[@]}"; do
        for name in $(list_migrations "$service"); do
            matches_only "$service" "$name" || continue      # 离线表同样尊重 --only，否则定向查询会回一整屏
            key="$service/$name"
            mark="${EXEC_AT[$key]:-—}"
            OFF_ROWS=$((OFF_ROWS + 1))
            if [ -n "${OV[$key]+x}" ]; then
                flag=""
                case "${OV[$key]}" in
                    已应用)   OFF_APPLIED=$((OFF_APPLIED + 1)) ;;
                    待应用)   OFF_PENDING=$((OFF_PENDING + 1)); flag=">>" ;;
                    需人工)   OFF_MANUAL=$((OFF_MANUAL + 1)) ;;
                    重复执行) OFF_IDEM=$((OFF_IDEM + 1)) ;;
                    *)        OFF_UNKNOWN=$((OFF_UNKNOWN + 1)) ;;
                esac
                printf '%s\n' "$(trow "$flag" "$service" "$(version_of "$name")" "$name" \
                       "${OV[$key]}" "$mark" "$(file_gen_time "$(migrations_dir "$service")/$name")")"
            else
                missing=$((missing + 1))
                OFF_UNKNOWN=$((OFF_UNKNOWN + 1))
                printf '%s\n' "$(trow "" "$service" "$(version_of "$name")" "$name" \
                       "离线未知" "$mark" "$(file_gen_time "$(migrations_dir "$service")/$name")")"
            fi
        done
    done
    W_VD=8
    if [ "$OFF_PENDING" -gt 0 ]; then
        printf '%s\n' "标记 >> ＝ 待应用（那次问库时该跑还没跑）：注意这是 ${OFF_TS} 的快照，此刻是否仍待应用要带 -r <user@host> -q 现问"
    fi
    if [ "$missing" -gt 0 ]; then
        log "其中 $missing 条在上次问库的判定表里没有，已按「离线未知」补上（多为那次之后新增的增量）⇒ 这份表始终覆盖本目录现有全部文件；现问加 -r <user@host> -q"
    fi
}

offline_report() {
    local sec svc n total=0 rec_n
    log "离线答复：$DEPLOY_ENV 库不在本机、本次也没给 -r/--remote ⇒ 不连任何数据库、不写留痕，只照录本地 $RECORD_REL"
    printf '\n%-16s %-8s %s\n' "服务" "文件数" "本目录现有迁移文件（离线只报清单，判定要问库）"
    for svc in "${SERVICE_LIST[@]}"; do
        n="$(find "$(migrations_dir "$svc")" -maxdepth 1 -name 'V*.sql' | wc -l | tr -d ' ')"
        printf '%-16s %-8s %s\n' "$svc" "$n" "$(migrations_dir "$svc")"
        total=$((total + n))
    done
    log "本目录在册迁移合计 $total 个"
    if ! sec="$(last_record_section)"; then
        log "$RECORD_REL 里还没有 $DEPLOY_ENV 的任何一节 ⇒ 这个环境从未被本脚本问过库，给不出逐文件判定"
        log "要现问 $DEPLOY_ENV 的差集：bash scripts/db-migrate.sh -e $DEPLOY_ENV -r <user@host> -q（只读，不需 --yes）"
        final_summary
        status_ok "$DEPLOY_ENV 离线答复：本地没有 $DEPLOY_ENV 的留痕可照录（在册迁移 $total 个），本次未连库、未改数据；要现问请加 -r <user@host> -q"
        return 0
    fi
    OFF_TS="$(printf '%s\n' "$sec" | head -n 1 | sed -nE 's/^## ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}).*/\1/p')"
    [ -n "$OFF_TS" ] || OFF_TS="时刻未识别"
    build_exec_index
    offline_table "$sec"
    rec_n="$(printf '%s\n' "$sec" | awk -v svc_list="$DEFAULT_SERVICES" '
        BEGIN { n = split(svc_list, s, ",") }
        /\.sql[[:space:]]/ {
            o = ($1 == ">>") ? 2 : 1
            for (i = 1; i <= n; i++) if ($o == s[i] && $(o + 2) ~ /\.sql$/) { c++; break }
        }
        END { print c + 0 }')"
    if [ "$rec_n" != "$total" ]; then
        warn "上次问库判定了 $rec_n 个文件、本目录现有 $total 个 ⇒ 期间迁移文件有增减，上面这份历史答案不含新增项"
    fi
    log "上表的判定照录自 $RECORD_REL 的最后一节（$OFF_TS 那次问 $DEPLOY_ENV 库），不是 $DEPLOY_ENV 库此刻的状态"
    final_summary
    status_ok "$DEPLOY_ENV 离线答复：照录 $OFF_TS 那次问库的结果（已应用 ${OFF_APPLIED}／待应用 ${OFF_PENDING}／需人工 ${OFF_MANUAL}／重复执行 ${OFF_IDEM}，共 ${OFF_ROWS} 个文件），本次未连库、未改数据；要看此刻真实状态请加 -r <user@host> -q"
}

# ── Phase 2: 连库一律交给执行层 scripts/db-sql.sh ────────────
# 本脚本只做"迁移层"该做的事：认 V 文件、探 @probe、判已应用/待应用、写 migrate-records 留痕、
# 按版本序决定跑哪些。**取连接参数、拼 ssh、pgPASSWORD、psql 传输**这一套全部在 db-sql.sh 一处实现，
# 两层各管一件事，不出现"同一件写库动作有两个入口、两套 prod 判定"。
DB_SQL="$REPO_ROOT/scripts/db-sql.sh"
[ -f "$DB_SQL" ] || fail "缺少执行层脚本: ${DB_SQL}（本脚本不直连数据库，所有问库与写库都要经它）"

ENV_SOURCE=""                             # 仅作展示与留痕用（"连接参数取自哪份 env"），本脚本不读其内容
CONN_SERVICE=""

# 组一次执行层调用的公共参数（远端必须显式 -r，与 db-sql.sh 同一条规则）
db_sql_args() {
    local -a out=(-e "$DEPLOY_ENV" -s "$CONN_SERVICE")
    if [ -n "$REMOTE_HOST" ]; then
        out+=(-r "$REMOTE_HOST")
    fi
    printf '%s\n' "${out[@]}"
}

db_sql() { # $@=额外参数（如 --apply / -f 文件 / --prod-approved）；SQL 走标准输入
    local -a args=() base
    while IFS= read -r base; do args+=("$base"); done < <(db_sql_args)
    bash "$DB_SQL" "${args[@]}" "$@"
}

resolve_conn() { # $1=service（同一服务只解析一次）；真正连库的是 db-sql.sh
    local service="$1"
    if [ "$CONN_SERVICE" = "$service" ] && [ -n "$ENV_SOURCE" ]; then
        return 0
    fi
    if [ -n "$REMOTE_HOST" ]; then
        ENV_SOURCE="$REMOTE_HOST:$(remote_env_file "$service")"
    else
        ENV_SOURCE="$(local_env_file "$service")"
        [ -f "$ENV_SOURCE" ] || fail "未找到 env 文件: $ENV_SOURCE"
    fi
    CONN_SERVICE="$service"
    log "连接参数来源 [$service] $ENV_SOURCE（口令由执行层现取、不回显、不落盘）"
    # 库身份指纹：把"这份报告是哪个库"变成报告自身的一部分——主机地址、库名、实例启动时刻、public 表数
    local fp
    if fp="$(run_sql "SELECT current_database() || ' @ ' || coalesce(inet_server_addr()::text,'?') || ':' || current_setting('port') || ' 启动=' || pg_postmaster_start_time()::text || ' public表=' || (SELECT count(*) FROM information_schema.tables WHERE table_schema='public')")"; then
        IDENT["$service"]="$(tr -d '\n' <<<"$fp")"
    else
        IDENT["$service"]="取不到（$(err_text 80)）"
    fi
    log "库身份 [$service] ${IDENT[$service]}"
}

# 执行一条只读 SQL（探测与库身份用）：结果走 stdout；报错文本留在 $ERR_TMP。
# 读路径不给 --apply：执行层默认就是只读（连上即数据库侧 read_only），写路径只有 run_file 那一处。
#
# 执行层只有一种输出：psql 的对齐结果表
#   表头行 + 分隔线 + 数据行（值两端补了对齐空格）+ `(N rows)` 收尾 + 空行
# 解析前统一过一遍 psql_data_rows：去表头两行、去行数收尾、去空行、trim 两端空白。
# 只喂**单列**查询（本脚本的两处查询都是把多字段拼成一列的字符串），多列查询列间的对齐空隙还原不了。
psql_data_rows() {
    awk '{
            sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "")
            if (NR <= 2 || $0 == "" || /^\([0-9]+ rows?\)$/) next
            print
        }'
}

# 报错文本单独取：执行层的 stderr 混着它自己的进度日志，
# 滤掉 [HH:MM:SS] [db-sql] 与 [STATUS] 两类行，psql 的 ERROR 原文照抄
err_text() { # $1=最大字符数
    awk '!/^\[[0-9:]+\] \[db-sql\] / && !/^\[STATUS\] /' "$ERR_TMP" | tr -d '\n' | cut -c1-"$1"
}

run_sql() { # $1=sql → stdout 只剩已 trim 的数据行
    printf '%s\n' "$1" | db_sql 2>"$ERR_TMP" | psql_data_rows
}

# 把一个迁移文件交给执行层执行（写操作；远端仍经 ssh 标准输入流式执行，不在远端落 .sql）
run_file() { # $1=sql 文件
    # 硬保护：-q 全程只读，任何路径都不许走到这里执行 SQL
    if [ "$MODE" = "query" ]; then
        fail "内部保护：-q 只查询模式不得执行迁移文件（被拦下：$1）"
    fi
    local out rc=0
    if [ "$DEPLOY_ENV" = "prod" ]; then
        # prod 的双确认锁只在本脚本判（--yes 与 --confirm-prod 都齐才会走到这里），
        # 判过之后才允许给执行层传 --prod-approved；执行层自己不重复一套 prod 确认
        db_sql --apply --prod-approved -f "$1" 2>"$ERR_TMP" || rc=$?
    else
        db_sql --apply -f "$1" 2>"$ERR_TMP" || rc=$?
    fi
    out="$(err_text 400)"
    if [ -n "$out" ]; then
        log "psql 输出：$out"
    fi
    return "$rc"
}

# ── Phase 3: 迁移文件清单与探测行解析 ─────────────────────────
# 版本号数值升序、同版本按文件名；同版本多文件只 WARN 一次，不重编号
migration_pairs() { # $1=service → 每行「版本号 + 制表符 + 文件名」
    local dir name ver
    dir="$(migrations_dir "$1")"
    for name in "$dir"/V*.sql; do
        [ -f "$name" ] || continue
        name="$(basename "$name")"
        ver="${name#V}"; ver="${ver%%__*}"
        printf '%s\t%s\n' "$ver" "$name"
    done | sort -t"$(printf '\t')" -k1,1n -k2,2
}

list_migrations() { # $1=service
    migration_pairs "$1" | cut -f2
}

version_of() { # $1=文件名 → V<n>
    local v="${1#V}"
    echo "V${v%%__*}"
}

# 迁移文件的生成时刻：取磁盘 mtime。Linux 的创建时间（birth time）并不可靠暴露，
# 而 V*.sql 写完即不编辑（要改判据是新建 V<n+1>），故 mtime 就是它的落地时刻。
file_gen_time() { # $1=文件绝对路径 → YYYY-MM-DD HH:MM（东八区）
    local t
    t="$(TZ='Asia/Shanghai' stat -c '%y' "$1" 2>/dev/null || TZ='Asia/Shanghai' stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$1" 2>/dev/null || true)"
    [ -n "$t" ] || { printf '—'; return 0; }
    printf '%s %s' "${t%% *}" "$(printf '%s' "$t" | sed -nE 's/^[^ ]+ ([0-9]{2}:[0-9]{2}).*/\1/p')"
}

# ── 表格排版（按显示列宽，不按字节）────────────────────────────
# bash 的 printf '%-Ns' 按**字节**补空格，终端却按**显示列**渲染：一个汉字 3 字节只占 2 列。
# 表头与「判定」取值都是中文 ⇒ 只要还用 %-Ns，每一列都会逐列往左缩，表头和数据对不齐。
# 故本表的每一格都走 padc，列宽取「表头显示宽」与「该列取值显示宽」的较大者。
disp_cols() { # $1=文本 → 终端显示列数
    local s="$1" b c n strip
    b="$(LC_ALL=C printf '%s' "$s" | wc -c)"; b=$((b))
    c=${#s}                                            # UTF-8 locale 下按字符计
    n=$(( c + (b - c) / 2 ))                           # 三字节字符先全按宽字符（2 列）计
    strip="${s//—/}"                                   # 「—」实测按 1 列渲染，扣回来
    printf '%s' "$(( n - (c - ${#strip}) ))"
}

padc() { # $1=目标显示列宽 $2=文本 → 右侧补空格到目标宽
    local w="$1" s="$2" n
    n="$(disp_cols "$s")"
    if [ "$n" -lt "$w" ]; then
        printf '%s%*s' "$s" "$(( w - n ))" ''
    else
        printf '%s' "$s"
    fi
}

# 列宽：标记 4（表头「标记」占 4 列，取值最多 ">>"）、服务 16、版本 5、判定 8（取值最长 4 个汉字）、
# 脚本执行 11（"MM-DD HH:MM"）；文件列由 table_file_width 按本次在册文件名实算。
W_MARK=4 W_SVC=16 W_VER=5 W_FILE=47 W_VD=8 W_EX=11

trow() { # $1..$7=各列文本 → 一行表格（列间单空格）
    printf '%s %s %s %s %s %s %s' \
        "$(padc "$W_MARK" "$1")" "$(padc "$W_SVC" "$2")" "$(padc "$W_VER" "$3")" \
        "$(padc "$W_FILE" "$4")" "$(padc "$W_VD" "$5")" "$(padc "$W_EX" "$6")" "$7"
}

table_file_width() { # $1=verdict（只量本次真会出现在表里的行）/ only（离线表按 --only 过滤）→ 置 W_FILE
    local mode="$1" service name n w=4
    for service in "${SERVICE_LIST[@]}"; do
        for name in $(list_migrations "$service"); do
            if [ "$mode" = "verdict" ]; then
                [ -n "${VERDICT[$service/$name]+x}" ] || continue
            else
                matches_only "$service" "$name" || continue
            fi
            n=${#name}
            [ "$n" -gt "$w" ] && w=$n
        done
    done
    W_FILE="$w"
}

warn_duplicate_versions() { # $1=service
    local dup ver names
    migration_pairs "$1" >"$DUP_TMP"
    dup="$(cut -f1 "$DUP_TMP" | sort -n | uniq -d || true)"
    for ver in $dup; do
        names="$(awk -F'\t' -v v="$ver" '$1==v{printf "%s ", $2}' "$DUP_TMP")"
        warn "$1 存在同版本多文件 V${ver}：${names}按文件名稳定序执行，不重编号（重编号会让已执行库的对象与文件名对不上）"
    done
}

# 过滤器已在启动时归一化成「规范服务名/…」，这里只需按服务名精确比对
filter_matches() { # $1=单个过滤器 $2=服务 $3=文件名
    local filt="$1" service="$2" name="$3" scope vtok num
    case "$filt" in
        */*)
            scope="${filt%%/*}"
            [ "$scope" = "$service" ] || return 1
            filt="${filt#*/}" ;;
    esac
    vtok="${name#V}"; vtok="${vtok%%__*}"
    if [[ "$filt" =~ ^[Vv]?[0-9]+$ ]]; then
        # 纯版本号写法按版本号精确匹配：子串匹配会让 --only V2 命中 V20~V26
        num="${filt#[Vv]}"
        [ "$num" = "$vtok" ] && return 0
        return 1
    fi
    filt="${filt%.sql}"
    [ "$filt" = "$name" ] && return 0
    case "$name" in
        *"$filt"*) return 0 ;;
    esac
    return 1
}

matches_only() { # $1=服务 $2=文件名；ONLY_FILTERS 为空表示不过滤
    local service="$1" name="$2" filt
    if [ -z "$ONLY_FILTERS" ]; then
        return 0
    fi
    for filt in $ONLY_FILTERS; do
        if filter_matches "$filt" "$service" "$name"; then
            return 0
        fi
    done
    return 1
}

# 「服务/xxx」限定写法里的服务名前缀先归一化成全名（缩写按唯一前缀展开），认不出或多义就当场报错，
# 不能留到匹配阶段静默不命中——那会出现"看着跑了其实一条没跑"。
normalize_only_filters() {
    local filt scope out=""
    [ -n "$ONLY_FILTERS" ] || return 0
    for filt in $ONLY_FILTERS; do
        case "$filt" in
            */*)
                scope="${filt%%/*}"
                if ! resolve_scope "$scope"; then
                    fail "--only $filt 的${SCOPE_HINT}"
                fi
                if [ -z "${filt#*/}" ]; then
                    fail "--only $filt 缺少版本号或文件名"
                fi
                filt="$RESOLVED_SCOPE/${filt#*/}" ;;
        esac
        out="$out $filt"
    done
    ONLY_FILTERS="$out"
}

warn_only_ambiguity() { # 裸版本号过滤器同时命中多个服务时，提示改用「服务/版本」限定写法
    local filt svc name key hits svc_list
    [ -n "$ONLY_FILTERS" ] || return 0
    for filt in $ONLY_FILTERS; do
        case "$filt" in */*) continue ;; esac
        [[ "$filt" =~ ^[Vv]?[0-9]+$ ]] || continue          # 文件名写法本身含唯一名称，不必判歧义
        hits=""; svc_list=""
        for key in $(printf '%s\n' "${!VERDICT[@]}" | sort); do
            svc="${key%%/*}"; name="${key#*/}"
            if filter_matches "$filt" "$svc" "$name"; then
                hits="$hits  $key"
                case " $svc_list " in *" $svc "*) ;; *) svc_list="$svc_list $svc" ;; esac
            fi
        done
        set -- $svc_list
        if [ "$#" -gt 1 ]; then
            warn "--only $filt 同时命中 $# 个服务的同号版本：$hits；只跑其中一个请带服务名，如 --only ${1}/$filt"
        fi
    done
}

PROBE_KIND=""                             # sql | manual | idempotent | unprobed
PROBE_LINES=()                            # kind=sql 时的探测语句

parse_probes() { # $1=文件绝对路径
    local f="$1" pr
    PROBE_KIND="unprobed"
    PROBE_LINES=()
    local manuals=0 idempotents=0
    while IFS= read -r pr; do
        pr="${pr#-- @probe:}"; pr="${pr#--@probe:}"
        pr="${pr#"${pr%%[![:space:]]*}"}"; pr="${pr%"${pr##*[![:space:]]}"}"
        case "$pr" in
            manual) manuals=$((manuals + 1)); continue ;;
            idempotent) idempotents=$((idempotents + 1)); continue ;;
            '') continue ;;
        esac
        PROBE_LINES+=("$pr")
    done < <(grep -E '^--[[:space:]]*@probe:' "$f" || true)
    if [ "$manuals" -gt 0 ]; then
        PROBE_KIND="manual"; PROBE_LINES=()
    elif [ "$idempotents" -gt 0 ]; then
        PROBE_KIND="idempotent"; PROBE_LINES=()
    elif [ "${#PROBE_LINES[@]}" -gt 0 ]; then
        PROBE_KIND="sql"
    fi
}

# 多条探测语句 AND 成一条 0/1 判定 SQL（每条必须是单行 SELECT，返回单个数值）
# 输出压成单列 "键=命中"，不依赖 psql 的字段分隔符（-A 非对齐模式默认分隔符是 | 而非制表符）
probe_case_sql() { # $1=key $@=探测语句
    local key="$1"; shift
    local cond="" pr
    for pr in "$@"; do
        if [ -z "$cond" ]; then
            cond="( ($pr) > 0 )"
        else
            cond="$cond AND ( ($pr) > 0 )"
        fi
    done
    printf "SELECT '%s=' || (%s)::int" "$key" "$cond"
}

# 只取第一条探测语句正文：awk 自己读文件、命中即 exit，不接 `| head`
# （head 提前退出会让上游 sed 收到 SIGPIPE，pipefail 下把整条命令判成失败）
first_probe_body() { # $1=文件 → 首条 @probe 正文前 56 字符
    awk '/^--[ \t]*@probe:/ { sub(/^--[ \t]*@probe:[ \t]*/, ""); print substr($0, 1, 56); exit }' "$1"
}

probe_digest() { # $1=文件绝对路径 → 探测判据摘要（只喂「待应用」清单，判定表已不展示依据列）
    local f="$1" n
    n="$(grep -cE '^--[[:space:]]*@probe:' "$f" || true)"
    case "$PROBE_KIND" in
        manual) echo "人工执行，不自动跑" ;;
        idempotent) echo "自带幂等预检，每次执行" ;;
        unprobed) echo "缺 @probe 行" ;;
        *) echo "对象探测 ${n} 条: $(first_probe_body "$f")…" ;;
    esac
}

# ── Phase 4: 判定 ────────────────────────────────────────────
declare -A VERDICT REASON
declare -A EXEC_AT                        # 服务/文件 → 本脚本最近一次执行它的时刻（取自本地留痕）

build_exec_index() { # 只读本地留痕，汇总"哪些增量 sql 是这个工具跑过的、什么时候跑的"
    [ -s "$RECORD_FILE" ] || return 0
    local ts file
    while IFS=$'\t' read -r ts file; do
        [ -n "$file" ] || continue
        EXEC_AT["$file"]="$ts"            # 留痕按时间正序，后读到的即最近一次
    done < <(awk '
        /^## /            { ts=$0; sub(/^## /,"",ts); sub(/ ·.*/,"",ts)
                            sub(/^....-/, "", ts); sub(/:[0-9][0-9]$/, "", ts); next }
        /^- 本次执行：/    { v=$0; sub(/^- 本次执行：/,"",v); gsub(/^ +| +$/,"",v); gsub(/ +/,"、",v)
                            n = split(v, a, "、"); for (i = 1; i <= n; i++) if (a[i] != "") printf "%s\t%s\n", ts, a[i] }
    ' "$RECORD_FILE")
}

N_APPLIED=0; N_PENDING=0; N_MANUAL=0; N_IDEMPOTENT=0; N_UNPROBED=0; N_ERROR=0
N_EXECUTED=0
FILES_TOTAL=0

record_verdict() { # $1=key $2=判定 [$3=依据覆盖]
    VERDICT["$1"]="$2"
    if [ $# -ge 3 ]; then
        REASON["$1"]="$3"
    fi
}

apply_probe_row() { # $1=key $2=hit(0|1)
    if [ "$2" = "1" ]; then
        record_verdict "$1" "已应用"
    else
        record_verdict "$1" "待应用"
    fi
}

evaluate_service() { # $1=service
    local service="$1" dir name key rows row_sql out row
    dir="$(migrations_dir "$service")"
    warn_duplicate_versions "$service"

    local sql_keys=()
    local batch=""
    for name in $(list_migrations "$service"); do
        if ! matches_only "$service" "$name"; then
            continue
        fi
        parse_probes "$dir/$name"
        key="$service/$name"
        case "$PROBE_KIND" in
            manual) record_verdict "$key" "需人工" ;;
            idempotent) record_verdict "$key" "重复执行" ;;
            unprobed) record_verdict "$key" "未标注" ;;
            sql)
                sql_keys+=("$key")
                row_sql="$(probe_case_sql "$key" "${PROBE_LINES[@]}")"
                if [ -z "$batch" ]; then
                    batch="$row_sql"
                else
                    batch="$batch UNION ALL $row_sql"
                fi
                ;;
        esac
    done

    if [ "${#sql_keys[@]}" -eq 0 ]; then
        return 0
    fi
    # 一次 UNION ALL 问完所有文件：逐文件问会把 N 个文件变成 N 次 ssh + N 次连库
    if rows="$(run_sql "$batch")"; then
        while IFS= read -r row; do
            [ -n "$row" ] || continue
            apply_probe_row "${row%=*}" "${row##*=}"
        done <<<"$rows"
        return 0
    fi
    # 批量失败时不能整批判"探测出错"：一条写坏的探测语句会连坐同服务所有文件
    warn "$service 批量探测失败（$(err_text 160)），改为逐文件探测以定位出错文件"
    for key in "${sql_keys[@]}"; do
        name="${key#*/}"
        parse_probes "$dir/$name"
        if out="$(run_sql "$(probe_case_sql "$key" "${PROBE_LINES[@]}")")"; then
            out="${out%%$'\n'*}"
            apply_probe_row "${out%=*}" "${out##*=}"
        else
            record_verdict "$key" "探测出错" "$(err_text 120)"
        fi
    done
}

print_report() {
    local service name key mark flag gtime errs=""
    table_file_width verdict
    emit "$(trow "标记" "服务" "版本" "文件" "判定" "脚本执行" "生成时间")"
    for service in "${SERVICE_LIST[@]}"; do
        for name in $(list_migrations "$service"); do
            key="$service/$name"
            if [ -z "${VERDICT[$key]+x}" ]; then
                continue
            fi
            FILES_TOTAL=$((FILES_TOTAL + 1))
            mark="${EXEC_AT[$key]:-—}"
            gtime="$(file_gen_time "$(migrations_dir "$service")/$name")"
            flag=""
            [ "${VERDICT[$key]}" = "待应用" ] && flag=">>"
            emit "$(trow "$flag" "$service" "$(version_of "$name")" "$name" "${VERDICT[$key]}" "$mark" "$gtime")"
            if [ "${VERDICT[$key]}" = "探测出错" ]; then
                errs="$errs
    $service/$name：${REASON[$key]:-探测语句未返回结果}"
            fi
            case "${VERDICT[$key]}" in
                已应用) N_APPLIED=$((N_APPLIED + 1)) ;;
                待应用) N_PENDING=$((N_PENDING + 1)); PENDING_LIST="$PENDING_LIST $key" ;;
                需人工) N_MANUAL=$((N_MANUAL + 1)) ;;
                重复执行) N_IDEMPOTENT=$((N_IDEMPOTENT + 1)) ;;
                未标注) N_UNPROBED=$((N_UNPROBED + 1)) ;;
                探测出错) N_ERROR=$((N_ERROR + 1)) ;;
            esac
        done
    done
    if [ "$N_PENDING" -gt 0 ]; then
        emit "标记 >> ＝ 待应用（该跑还没跑）：这是本脚本唯一会自动执行的一类，其余行都不会被执行"
    fi
    # 「依据」列不逐行展示（判据本来就写在每个文件自己的 -- @probe: 头部），
    # 但探测出错是唯一的真异常，它的报错文本必须仍能看到
    if [ -n "$errs" ]; then
        emit "探测出错 ${N_ERROR} 个，报错文本如下（判定不可信，先修文件头部的探测语句）：$errs"
    fi
}

summary_text() {
    echo "已应用 ${N_APPLIED}／待应用 ${N_PENDING}（本次执行 ${N_EXECUTED}）／需人工 ${N_MANUAL}／每次执行 ${N_IDEMPOTENT}／未标注 ${N_UNPROBED}／探测出错 ${N_ERROR}　合计 ${FILES_TOTAL} 个文件"
}

summary_line() {
    echo "汇总：$(summary_text)"
}

# 待应用的文件名（服务/文件），按执行顺序
pending_paths() {
    local service name key
    for service in "${SERVICE_LIST[@]}"; do
        for name in $(list_migrations "$service"); do
            key="$service/$name"
            if [ "${VERDICT[$key]:-}" = "待应用" ]; then
                printf '%s\t%s\n' "$service" "$name"
            fi
        done
    done
}

# 结尾把「待应用」从整张表里单列出来：这一列就是"真去执行会跑哪些"，只查询时尤其要看它
report_pending() { # $1=本次语境
    local service name out
    out="$(pending_paths)"
    if [ -z "$out" ]; then
        log "待应用增量：0 个（$1）"
        return 0
    fi
    log "待应用增量 ${N_PENDING} 个（$1）："
    while IFS=$'\t' read -r service name; do
        [ -n "$service" ] || continue
        parse_probes "$(migrations_dir "$service")/$name"
        printf '  %-15s %-47s %s\n' "[$service]" "$name" "$(probe_digest "$(migrations_dir "$service")/$name")"
    done <<<"$out"
}

# 本次要执行的文件：待应用 + 每次执行(idempotent) + 未标注（仅在 --include-unprobed 时）
selected_files() {
    local service name key
    for service in "${SERVICE_LIST[@]}"; do
        for name in $(list_migrations "$service"); do
            key="$service/$name"
            if [ -z "${VERDICT[$key]+x}" ]; then
                continue
            fi
            case "${VERDICT[$key]}" in
                待应用|重复执行) printf '%s\t%s\t%s\n' "$service" "$name" "${VERDICT[$key]}" ;;
                未标注)
                    if [ "$INCLUDE_UNPROBED" -eq 1 ]; then
                        printf '%s\t%s\t%s\n' "$service" "$name" "${VERDICT[$key]}"
                    fi
                    ;;
            esac
        done
    done
}

confirm_apply() { # $1=待执行文件数
    if [ "$ASSUME_YES" -eq 1 ]; then
        return 0
    fi
    local ans
    printf '确认对 %s 环境执行以上 %s 个迁移文件？[y/N] ' "$DEPLOY_ENV" "$1"
    read -r ans </dev/tty || ans=""
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
        *) fail "已取消，未执行任何文件" ;;
    esac
}

do_apply() {
    local n service name verdict f
    selected_files >"$PLAN_TMP"
    n="$(wc -l <"$PLAN_TMP" | tr -d ' ')"

    if [ "$n" = "0" ]; then
        log "无待应用增量：需人工／未标注／探测出错 三类文件一律不由本脚本代跑"
        if [ "$N_ERROR" -gt 0 ]; then
            fail "存在探测出错的迁移文件，请先修正探测语句再执行"
        fi
        return 0
    fi

    log "本次将执行 ${n} 个文件（按版本号升序、逐服务串行）："
    while IFS=$'\t' read -r service name verdict; do
        log "  [$service] $name（$verdict）"
    done <"$PLAN_TMP"
    confirm_apply "$n"

    local cur=""
    while IFS=$'\t' read -r service name verdict <&3; do
        if [ -z "$service" ]; then
            continue
        fi
        if [ "$cur" != "$service" ]; then
            CONN_SERVICE=""               # 每个服务连自己的库，切服务就重新解析连接
            resolve_conn "$service"
            cur="$service"
        fi
        f="$(migrations_dir "$service")/$name"
        log_step "执行 [$service] $name（$verdict）"
        if ! run_file "$f"; then
            fail "[$service] $name 执行失败，已中止后续文件；psql 报错见上一行输出，请人工核对后再重试"
        fi
        N_EXECUTED=$((N_EXECUTED + 1))
        EXEC_LIST="$EXEC_LIST $service/$name"
    done 3<"$PLAN_TMP"
    # 计划与实跑必须对得上：漏跑比误重跑更危险（多数文件幂等挡得住重跑，挡不住静默跳过）
    if [ "$N_EXECUTED" -ne "$n" ]; then
        fail "计划执行 ${n} 个、实际执行 ${N_EXECUTED} 个，有文件被跳过；请核对上方执行日志后重试"
    fi
}

# 判定分布的一行：判定名补齐到 4 个全角宽、个数右对齐 3 位、后面跟一句白话注解
dist_row() { # $1=判定名 $2=个数 $3=注解
    local name="$1"
    case "$name" in
        已应用|待应用|需人工|未标注) name="${name}　" ;;
    esac
    printf '      %s%3d  %s\n' "$name" "$2" "$3"
}

# 结尾总结：固定版式——标签用全角空格补齐到同宽、判定分布竖排各带一句白话注解、
# 下一步的命令单独成行便于复制。三种模式同一骨架，只换内容与措辞。
final_summary() {
    local mode changed cmd hint svc total
    if [ "$OFFLINE" -eq 1 ]; then
        mode="离线答复（-q 且未给 -r）"
    elif [ "$MODE" = "query" ]; then
        mode="只读查询（-q）"
    else
        mode="增量执行"
    fi

    printf '\n%s\n'   "──────────────── 本次运行总结 ────────────────"
    printf '  %s  %s\n' "模式　　　" "$mode"
    printf '  %s  %s\n' "目标环境　" "${DEPLOY_ENV}　服务：${SERVICE_SELECTION}"

    if [ "$OFFLINE" -eq 1 ]; then
        printf '  %s  %s\n' "连的哪个库" "没有连库——${DEPLOY_ENV} 库不在本机，本次也没给 -r/--remote"
        if [ -n "$OFF_TS" ]; then
            printf '  %s  %s\n' "答案来源　" "${RECORD_REL} 的最后一节（＝最近一次真问过 ${DEPLOY_ENV} 库的那次）"
            printf '  %s  %s\n' "快照时刻　" "${OFF_TS}　此后 ${DEPLOY_ENV} 库若有变动，下表不反映"
            total="$OFF_ROWS"
        else
            printf '  %s  %s\n' "答案来源　" "${RECORD_REL} 里还没有 ${DEPLOY_ENV} 的任何一节 ⇒ 无可照录的答案"
            total=0
        fi
        printf '  %s  %s\n' "是否改数据" "否：未连库、未执行任何 SQL、未写留痕（离线答复不构成对库的一次问答）"
        printf '\n  %s  %s\n' "判定分布　" "共 ${total} 个文件（照录上面那一刻的判定，不是此刻状态）"
        dist_row 已应用   "$OFF_APPLIED" "库里已有，无需再跑"
        dist_row 待应用   "$OFF_PENDING" "该跑还没跑 ⇒ 本脚本唯一会自动执行的一类"
        dist_row 需人工   "$OFF_MANUAL"  "脚本一律不代跑，判据写在各文件头部"
        dist_row 重复执行 "$OFF_IDEM"    "自带幂等预检，每次都跑"
        dist_row 离线未知 "$OFF_UNKNOWN" "那次的表里没有这条，绝不猜成已应用／待应用"
        hint="要看 ${DEPLOY_ENV} 库此刻的真实状态（只读、不需 --yes）："
        cmd="bash scripts/db-migrate.sh -e ${DEPLOY_ENV} -r <user@host> -q$(scope_flags)"
    else
        printf '  %s  %s\n' "连的哪个库" "逐服务库身份指纹（并排两份环境即可看出是两个不同的库）："
        for svc in "${SERVICE_LIST[@]}"; do
            printf '      [%s] %s\n' "$svc" "${IDENT[$svc]:-未取得}"
        done
        case "$mode" in
            只读查询*) changed="否：只跑 @probe 探测，未执行任何迁移文件$(rec_written_note)" ;;
            *)         changed="是：执行了 ${N_EXECUTED} 个迁移文件（只做增量，未 DROP／重建／从备份恢复）$(rec_written_note)" ;;
        esac
        printf '  %s  %s\n' "是否改数据" "$changed"
        printf '\n  %s  %s\n' "判定分布　" "共 ${FILES_TOTAL} 个文件（本次现问库的结果）"
        dist_row 已应用   "$N_APPLIED"    "库里已有，无需再跑"
        dist_row 待应用   "$N_PENDING"    "该跑还没跑 ⇒ 本脚本唯一会自动执行的一类"
        dist_row 需人工   "$N_MANUAL"     "脚本一律不代跑，判据写在各文件头部"
        dist_row 重复执行 "$N_IDEMPOTENT" "自带幂等预检，每次都跑"
        dist_row 未标注   "$N_UNPROBED"   "文件缺 @probe 行，默认拒跑（--include-unprobed 才放行）"
        dist_row 探测出错 "$N_ERROR"      "探测语句本身跑不通，要先修探测再谈执行"
        if [ "$MODE" != "query" ] && [ "$N_EXECUTED" -gt 0 ]; then
            printf '      %s\n' "注：以上是执行前算的，不含本次刚跑的 ${N_EXECUTED} 个"
        fi
        case "$mode" in
            只读查询*)
                if [ "$N_PENDING" -eq 0 ]; then
                    hint="没有待应用的增量，不需要升级$(manual_note "$N_MANUAL")"
                    cmd=""
                else
                    hint="要执行这 ${N_PENDING} 个待应用文件（需 --yes）$(manual_note "$N_MANUAL")"
                    cmd="bash scripts/db-migrate.sh -e ${DEPLOY_ENV}$(remote_flag)$(scope_flags) --yes"
                fi
                ;;
            *)
                hint="复核本次执行结果（应显示待应用 0）："
                cmd="bash scripts/db-migrate.sh -e ${DEPLOY_ENV}$(remote_flag)$(scope_flags) -q"
                ;;
        esac
    fi

    printf '\n  %s  %s\n' "下一步　　" "$hint"
    if [ -n "$cmd" ]; then
        printf '      %s\n' "$cmd"
    fi
    printf '%s\n' "──────────────────────────────────────────────"
}

# ── 主流程 ───────────────────────────────────────────────────
EXTRA_NOTE=""
if [ -n "$ONLY_FILTERS" ]; then
    normalize_only_filters
    EXTRA_NOTE="$EXTRA_NOTE 只处理=$ONLY_FILTERS"
fi

log_step "Phase 1/4 参数：目标库=$TARGET_DESC 服务=${SERVICE_SELECTION} 模式=${MODE}${EXTRA_NOTE}"
log "本脚本只做增量：不会 DROP、不会重建、不会从备份恢复（那属 deploy.sh --target db）"
if [ "$NO_REPORT" -eq 1 ]; then
    log "留痕：已按 --no-report 关闭（本次不写 $RECORD_REL）"
elif [ "$OFFLINE" -eq 1 ]; then
    log "留痕：离线答复不写 $RECORD_REL（它不是对库的一次问答）"
else
    log "留痕文件：$RECORD_REL（本次运行的命令、库身份指纹、判定表与汇总会追加到这里；只写本地，目标机上不留文件）"
fi

if [ "$OFFLINE" -eq 1 ]; then
    offline_report
    exit 0
fi

log_step "Phase 2/4 解析连接并逐文件探测判定"
for svc in "${SERVICE_LIST[@]}"; do
    CONN_SERVICE=""
    resolve_conn "$svc"
    evaluate_service "$svc"
done

build_exec_index
print_report
warn_only_ambiguity

if [ "$MODE" = "query" ]; then
    log_step "Phase 3/4 只读报告结束（未执行任何写入），Phase 4/4 无需执行"
    summary_line
    report_pending "-q 只查询，本次未执行任何文件"
    write_record
    final_summary
    if [ "$N_PENDING" -eq 0 ]; then
        status_ok "$DEPLOY_ENV 现问完成（只读、未改数据）：共 ${FILES_TOTAL} 个文件 → 已应用 ${N_APPLIED}／待应用 0 ⇒ 没有需要执行的增量（另有需人工 ${N_MANUAL}／重复执行 ${N_IDEMPOTENT}）$(rec_note)"
    else
        rh=""
        if [ -n "$REMOTE_HOST" ]; then rh="，并照旧带上 -r $REMOTE_HOST"; fi
        status_ok "$DEPLOY_ENV 现问完成（只读、未改数据）：共 ${FILES_TOTAL} 个文件 → 待应用 ${N_PENDING}／已应用 ${N_APPLIED} ⇒ 要执行请加 --yes${rh}$(rec_note)"
    fi
    exit 0
fi

log_step "Phase 3/4 增量执行"
do_apply

log_step "Phase 4/4 汇总"
summary_line
if [ -n "$EXEC_LIST" ]; then
    log "本次已执行 ${N_EXECUTED} 个文件：$EXEC_LIST"
fi
report_pending "执行前判定的待应用清单"
write_record
final_summary
status_ok "$DEPLOY_ENV 增量升级完成：执行 ${N_EXECUTED} 个文件全部成功（只做增量，未 DROP／重建／从备份恢复）；上表判定是执行前算的，请再跑一次 -q 复核待应用应为 0$(rec_note)"


