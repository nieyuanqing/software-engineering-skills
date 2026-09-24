#!/usr/bin/env bash
# 数据库 SQL 执行器（本工程唯一连库入口）：把「一段 SQL 打到某个环境的库」收成一个脚本，
# 避免在对话里贴多层嵌套引号的一行命令（终端折行或换 shell 就会把引号吃掉，
# 轻则 psql 参数解析失败，重则连错库）。
#
# 与 scripts/db-migrate.sh 的分工（两层各管一件事，功能不重复）：
#   本脚本＝**执行层**：只认「环境 + 服务 + 一段 SQL」，负责取连接参数、拼 ssh/psql、默认只读、
#            `--apply` 才放开写、prod 写默认拒跑。**不认迁移文件、不做任何判定、不写留痕。**
#   db-migrate.sh＝**迁移层**：只认 `V<n>__*.sql` 与文件头 `-- @probe:`，负责判「已应用／待应用／需人工」、
#            写 deploy-conf/db/migrate-records/<env>.md 留痕、按版本序批量升级；
#            **它自己不连库**——所有真问库与真写库都回调本脚本（ssh + PGPASSWORD + psql 的传输只有一处实现）。
#
# 默认只读：连上后强制 default_transaction_read_only=on，任何写操作都会被数据库拒掉。
# 写操作必须显式 --apply，且目标为远端时还要显式 -r <host>（本脚本不登记任何目标机）。
# 本脚本**没有查询模式也没有只读开关**：读是默认（不加 --apply 时数据库侧强制 read_only），
#   写只有 --apply 一条显式路径——一个轴上一个参数，不做"再声明一遍只读"的重复开关。
# 输出**只有一种**：psql 原始的对齐结果表（表头 + 数据行 + `(N rows)` 收尾），进度日志走 stderr。
#   不提供第二种排版开关：机器调用方（db-migrate.sh）自己剥掉表头、分隔线、行数收尾并 trim 两端空白。
# 凭据一律从目标环境的 .env 现取，只在进程环境变量里存在，不落盘、不回显。
#
# 用法:
#   bash scripts/db-sql.sh -e dev  -f path/to.sql                # 本机 dev 库，只读
#   bash scripts/db-sql.sh -e test -r <user@host> -f path/to.sql # test 库，只读
#   bash scripts/db-sql.sh -e test -r <user@host> --apply -f ... # test 库，允许写（迁移文件也走这条）
#   echo "select 1" | bash scripts/db-sql.sh -e test -r <user@host>   # SQL 走标准输入
#
# 选项:
#   -e, --env <dev|test|prod>   目标环境（默认 dev）。test/prod 的库不在本机，必须显式 -r
#   -r, --remote <user@host>    唯一能指向远端的参数；SQL 经 ssh 标准输入流式执行，目标机不落任何文件
#   -s, --service <名>          取哪份 .env 的连接参数（默认脚本顶部 SERVICES 表第一项）
#   -f, --file <路径|->         SQL 文件；不给或给 - 则从标准输入读
#       --apply                 放开写操作（缺它则数据库侧强制只读，DDL 直接被数据库拒绝）
#       --prod-approved         prod 写操作的放行位：**只给已持双确认锁的调用方**（db-migrate 仅在
#                               同时拿到 --yes 与 --confirm-prod 时才传）；人工直接跑本脚本永远不该加它
#   -h, --help                  显示本用法
set -euo pipefail

# 在册微服务（必须与 scripts/deploy.sh、scripts/db-migrate.sh 顶部的服务表一致）
SERVICES=("<SERVICE_NAME>")

ENVIRONMENT="dev"
REMOTE_HOST=""
SERVICE="${SERVICES[0]}"
SQL_FILE=""
APPLY=0
PROD_APPROVED=0

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ROOT_LOCAL="$REPO_ROOT/src/backend"
APP_ROOT_REMOTE="${APP_ROOT:-/opt/soft/apps}"

# 日志一律走 stderr：stdout 只放 psql 的结果表，人工看与程序解析的都是同一张表
log()  { printf '[%s] [db-sql] %s\n' "$(TZ='Asia/Shanghai' date '+%H:%M:%S')" "$*" >&2; }
fail() { log "ERROR - $*"; printf '[STATUS] ERROR - %s\n' "$*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "缺少必要命令: $1"; }

usage() { awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; }

while [ $# -gt 0 ]; do
    case "$1" in
        -e|--env)        ENVIRONMENT="${2:-}"; shift 2 ;;
        -r|--remote)     REMOTE_HOST="${2:-}"; shift 2 ;;
        -s|--service)    SERVICE="${2:-}"; shift 2 ;;
        -f|--file)       SQL_FILE="${2:-}"; shift 2 ;;
        --apply)         APPLY=1; shift ;;
        --prod-approved) PROD_APPROVED=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) fail "未知参数: $1（-h 看用法）" ;;
    esac
done

known_service() {
    local want="$1" known
    for known in "${SERVICES[@]}"; do
        [ "$want" = "$known" ] && return 0
    done
    return 1
}
known_service "$SERVICE" || fail "未知服务: $SERVICE（在册：${SERVICES[*]}）"

case "$ENVIRONMENT" in
    dev)  REMOTE_HOST="" ;;
    test|prod)
        [ -n "$REMOTE_HOST" ] || fail "$ENVIRONMENT 的库不在本机，必须显式给 -r <host>（不给就只碰本机库）"
        ;;
    *) fail "未知环境: $ENVIRONMENT（只支持 dev|test|prod）" ;;
esac

# prod 写：默认一律拒跑（人工待办的 prod 项按项目约定挂起）。唯一放行路径是调用方已持双确认锁
# 并显式传 --prod-approved；那两把锁在 db-migrate.sh 里（--yes 与 --confirm-prod 同时给出才转过来），
# 确认判定只在那一处，本脚本不重复一套 prod 确认逻辑。
if [ "$ENVIRONMENT" = "prod" ] && [ "$APPLY" = 1 ] && [ "$PROD_APPROVED" != 1 ]; then
    fail "prod 写操作不经本脚本代跑（人工待办 prod 项一律挂起）；要只读去掉 --apply 即可。批量升级请走 scripts/db-migrate.sh -e prod -r <host> --yes --confirm-prod"
fi

if [ -n "$SQL_FILE" ] && [ "$SQL_FILE" != "-" ]; then
    [ -f "$SQL_FILE" ] || fail "找不到 SQL 文件: $SQL_FILE"
else
    SQL_FILE=""
fi

SQL_SOURCE="$SQL_FILE"
[ -n "$SQL_SOURCE" ] || SQL_SOURCE="<stdin>"

# 远端与本机同构：source 该环境的 .env → 口令只进环境变量 → SQL 经标准输入喂给 psql。
# 只读模式下再加一道数据库侧闸门，脚本没写 --apply 就物理上写不进去。
build_psql_command() {
    local envfile="$1" ro_clause=""
    if [ "$APPLY" != 1 ]; then
        ro_clause='export PGOPTIONS="-c default_transaction_read_only=on"; '
    fi
    printf '%s' "set -a; . $envfile; set +a; export PGPASSWORD=\"\$DB_PASSWORD\"; ${ro_clause}exec psql -w -h \"\$DB_HOST\" -p \"\$DB_PORT\" -U \"\$DB_USERNAME\" -d \"\$DB_NAME\" -v ON_ERROR_STOP=1 -f -"
}

run_against() {
    local cmd="$1"
    if [ -n "$REMOTE_HOST" ]; then
        if [ -n "$SQL_FILE" ]; then
            ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 "$REMOTE_HOST" "$cmd" < "$SQL_FILE"
        else
            ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 "$REMOTE_HOST" "$cmd"
        fi
    elif [ -n "$SQL_FILE" ]; then
        bash -c "$cmd" < "$SQL_FILE"
    else
        bash -c "$cmd"
    fi
}

if [ -n "$REMOTE_HOST" ]; then
    ENVFILE="$APP_ROOT_REMOTE/$SERVICE/.env"      # 每台机只有本机那一份，不存在 .env.test 之分
    TARGET_DESC="ssh $REMOTE_HOST 上机取 $ENVFILE"
    require_command ssh
else
    ENVFILE="$APP_ROOT_LOCAL/$SERVICE/.env"       # 本机只有当前环境那一份 .env（部署时按环境覆盖）
    [ -f "$ENVFILE" ] || fail "找不到本机 env: $ENVFILE"
    TARGET_DESC="本机 $ENVFILE"
    require_command psql
fi

log "环境 $ENVIRONMENT ／ 服务 $SERVICE ／ 连接参数来源 $TARGET_DESC"
log "SQL 来源 $SQL_SOURCE ／ 模式 $([ "$APPLY" = 1 ] && echo '允许写入（--apply）' || echo '只读（数据库侧强制 read_only）')"

if [ -n "$REMOTE_HOST" ]; then
    # 必须带 -n：这条预检不喂 stdin，不加的话 ssh 会把调用方管道进来的 SQL 整段吞掉，
    # 后面真正执行 psql 的那条 ssh 就只能拿到空输入（现象是"执行完成"却一行结果都没有）
    ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=15 "$REMOTE_HOST" \
        "test -f $ENVFILE" || fail "远端没有 $ENVFILE（$REMOTE_HOST）"
fi

run_against "$(build_psql_command "$ENVFILE")"

log "执行完成（未回显任何连接参数与凭据）"
