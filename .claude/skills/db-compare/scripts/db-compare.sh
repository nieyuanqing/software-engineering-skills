#!/usr/bin/env bash
# db-compare.sh — PostgreSQL 表与字段结构只读比对（字段级）
#
# 模式：
#   run      抓两侧结构并比对（默认）
#   compare  比对两份已导出的结构快照 TSV（离线/复查用）
#   dump     只导出单侧结构快照到 stdout
#
# 全程只读：PGOPTIONS 强制 default_transaction_read_only=on，只 SELECT information_schema。
set -uo pipefail

MODE="run"; SRC_ENV="dev"; DST_HOST=""; SRC_HOST=""; SERVICE=""; SCHEMA="public"
OUT=""; C_SRC=""; C_DST=""; DUMP_SIDE=""

usage() {
  cat <<'USAGE'
用法: db-compare.sh run --dst-db=<主机名> [选项]

必填
  --dst-db=<主机名>          目标环境远程主机名。无默认值、不可猜测；缺失时脚本直接报错提醒。

可选
  --src-db=<dev|test|prod>   源环境，默认 dev（本机 src/backend/<服务>/.env）
  --src-host=<主机名>        源侧也走 SSH 时使用（默认本机直连）
  --service=<服务名>         定位 src/backend/<服务>/ 与远端 /opt/soft/apps/<服务>/.env
  --schema=<名称>            比对的 schema，默认 public
  --out=<文件>               报告另存为 markdown 文件（默认只输出到 stdout）
  -h, --help                 显示本帮助

其它模式
  db-compare.sh dump   --side=src|dst [同上选项]     只导出结构快照 TSV
  db-compare.sh compare --src=<tsv> --dst=<tsv>      离线比对两份快照
USAGE
}

die() { echo "错误：$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    run|compare|dump) MODE="$1" ;;
    --src-db=*)   SRC_ENV="${1#*=}" ;;
    --dst-db=*)   DST_HOST="${1#*=}" ;;
    --src-host=*) SRC_HOST="${1#*=}" ;;
    --service=*)  SERVICE="${1#*=}" ;;
    --schema=*)   SCHEMA="${1#*=}" ;;
    --out=*)      OUT="${1#*=}" ;;
    --side=*)     DUMP_SIDE="${1#*=}" ;;
    --src=*)      C_SRC="${1#*=}" ;;
    --dst=*)      C_DST="${1#*=}" ;;
    -h|--help)    usage; exit 0 ;;
    *) die "未知参数：$1（用 -h 查看帮助）" ;;
  esac
  shift
done

SQL_BODY=""
load_sql() {
  local dir
  dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  [ -f "$dir/structure.sql" ] || die "缺少结构查询文件：$dir/structure.sql"
  SQL_BODY=$(cat "$dir/structure.sql")
  case "$SQL_BODY" in
    *'$'*) die "structure.sql 含 \$ 字符，与本脚本的 heredoc 传递方式不兼容" ;;
  esac
  SQL_FILE="$dir/structure.sql"
}

# ---------- 参数与环境 ----------
check_common() {
  case "$SRC_ENV" in dev|test|prod) ;; *) die "--src-db 只能是 dev / test / prod，当前为：$SRC_ENV" ;; esac
}

locate_service() {
  [ -n "$SERVICE" ] && return 0
  cand=$(ls -d src/backend/*/ 2>/dev/null | sed 's#src/backend/##; s#/$##' | grep . || true)
  n=$(printf '%s\n' "$cand" | grep -c . || true)
  [ "$n" = "1" ] || die "未能唯一确定服务名（候选：${cand:-无}），请用 --service=<服务名> 指定"
  SERVICE="$cand"
}

src_env_file() {
  case "$SRC_ENV" in
    dev)  echo "src/backend/$SERVICE/.env" ;;
    *)    echo "src/backend/$SERVICE/.env.$SRC_ENV" ;;
  esac
}

# ---------- 抓取 ----------
psql_local() {  # $1=env 文件 $2=输出
  [ -f "$1" ] || { echo "env 文件不存在：$1" >&2; return 1; }
  [ -r "$1" ] || { echo "env 文件不可读：$1" >&2; return 1; }
  if grep -qE '^[[:space:]]*(DB_USER|DB_PASSWORD|DB_NAME)=([[:space:]]*|"?changeme"?)$' "$1"; then
    echo "$1 的 DB_USER/DB_PASSWORD/DB_NAME 存在空值或模板占位符 changeme，需先填真实开发库配置" >&2
    return 1
  fi
  ( set -a; . "$1"; set +a
    export PGOPTIONS="-c default_transaction_read_only=on"
    psql -X -q -A -t -v ON_ERROR_STOP=1 -v schema="$SCHEMA" -f "$SQL_FILE" \
      -h "${DB_HOST:-127.0.0.1}" -p "${DB_PORT:-5432}" -U "$DB_USER" -d "$DB_NAME" ) > "$2" 2>"$2.err"
  [ -s "$2" ] || { echo "本机抓取失败：$(tr '\n' ' ' < "$2.err" | cut -c1-200)" >&2; rm -f "$2.err"; return 1; }
  rm -f "$2.err"
}

psql_remote() {  # $1=主机 $2=远端 env 路径 $3=输出
  local host="$1" envf="$2" of="$3" err="$3.err"
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" 'bash -s' -- "$envf" "$SCHEMA" > "$of" 2>"$err" <<REMOTE
set -u
envf="\$1"; schema="\$2"
[ -f "\$envf" ] || { echo "远端 env 不存在：\$envf" >&2; exit 3; }
set -a; . "\$envf"; set +a
export PGOPTIONS="-c default_transaction_read_only=on"
cat <<'SQ' | psql -X -q -A -t -v ON_ERROR_STOP=1 -v schema="\$schema" -f - \\
     -h "\${DB_HOST:-127.0.0.1}" -p "\${DB_PORT:-5432}" -U "\$DB_USER" -d "\$DB_NAME"
$SQL_BODY
SQ
REMOTE
  [ -s "$of" ] || { echo "抓取失败（$host）：$(tr '\n' ' ' < "$err" | cut -c1-200)" >&2; rm -f "$err"; return 1; }
  rm -f "$err"
}

capture_side() {  # $1=src|dst $2=输出
  local side="$1" of="$2" host envf
  if [ "$side" = "src" ]; then host="$SRC_HOST"; else host="$DST_HOST"; fi
  if [ -n "$host" ]; then
    envf="/opt/soft/apps/$SERVICE/.env"
    echo "抓取 ${side}：ssh $host $envf（schema $SCHEMA）" >&2
    psql_remote "$host" "$envf" "$of"
  else
    envf=$(src_env_file)
    echo "抓取 ${side}：本机 $envf（--src-db=$SRC_ENV，schema $SCHEMA）" >&2
    psql_local "$envf" "$of"
  fi
}

# ---------- 比对 ----------
emit_list() {  # $1=换行分隔清单；最多渲染 40 条，超出提示用 --out 导出
  local n
  n=$(printf '%s' "$1" | grep -c . || true)
  printf '%s\n' "$1" | head -40 | sed 's/^/  - `/; s/$/`/'
  if [ "$n" -gt 40 ]; then printf '  - …（另有 %s 条，用 --out 导出完整报告）\n' "$((n-40))"; fi
  return 0
}

report() {  # $1=src tsv $2=dst tsv $3=源标签 $4=目标标签
  local s="$1" d="$2" sl="$3" dl="$4"
  local RD stmp dtmp sk dk
  RD=$(mktemp -d)
  stmp="$RD/src.tbls"; dtmp="$RD/dst.tbls"; sk="$RD/src.keys"; dk="$RD/dst.keys"
  cut -f1 "$s" | sort -u > "$stmp"; cut -f1 "$d" | sort -u > "$dtmp"
  comm -12 "$stmp" "$dtmp" > "$RD/shared"
  awk -F'\t' 'NR==FNR{keep[$1]=1;next} ($1 in keep){print $1"."$2"\t"$3"\t"$4"\t"$5}' "$RD/shared" "$s" | sort > "$sk"
  awk -F'\t' 'NR==FNR{keep[$1]=1;next} ($1 in keep){print $1"."$2"\t"$3"\t"$4"\t"$5}' "$RD/shared" "$d" | sort > "$dk"

  echo "## 结构比对：$sl（源） vs $dl（目标）｜schema $SCHEMA"
  echo
  printf -- '- 表数量：源 %s，目标 %s（共有 %s 张）\n' "$(wc -l < "$stmp" | tr -d ' ')" "$(wc -l < "$dtmp" | tr -d ' ')" "$(wc -l < "$RD/shared" | tr -d ' ')"
  printf -- '- 字段数量：源 %s，目标 %s\n' "$(wc -l < "$s" | tr -d ' ')" "$(wc -l < "$d" | tr -d ' ')"

  local t_only_s t_only_d f_only_s f_only_d changed
  t_only_s=$(comm -23 "$stmp" "$dtmp")
  t_only_d=$(comm -13 "$stmp" "$dtmp")
  cut -f1 "$sk" > "$sk.k"; cut -f1 "$dk" > "$dk.k"
  f_only_s=$(comm -23 "$sk.k" "$dk.k"); f_only_d=$(comm -13 "$sk.k" "$dk.k")
  changed=$(join -t$'\t' -j1 "$sk" "$dk" | awk -F'\t' '$2!=$5 || $3!=$6 || $4!=$7' | wc -l | tr -d ' ')
  local n_tbl_add n_tbl_del n_col_add n_col_del
  n_tbl_add=$(printf '%s' "$t_only_d" | grep -c . || true)
  n_tbl_del=$(printf '%s' "$t_only_s" | grep -c . || true)
  n_col_add=$(printf '%s' "$f_only_d" | grep -c . || true)
  n_col_del=$(printf '%s' "$f_only_s" | grep -c . || true)

  echo
  echo "### 结论"
  if [ "$n_tbl_add" = 0 ] && [ "$n_tbl_del" = 0 ] && [ "$n_col_add" = 0 ] && [ "$n_col_del" = 0 ] && [ "$changed" = 0 ]; then
    echo '- 两侧表与字段结构**完全一致**（字段级）'
  else
    printf -- '- **存在差异**：表 目标多 %s / 目标缺 %s；共有表内字段 目标多 %s / 目标缺 %s；字段属性差异 %s 处\n' \
      "$n_tbl_add" "$n_tbl_del" "$n_col_add" "$n_col_del" "$changed"
  fi

  echo
  echo "### 表级差异"
  echo
  if [ "$n_tbl_add" = 0 ] && [ "$n_tbl_del" = 0 ]; then
    echo '- 无：两侧表清单一致'
  else
    if [ "$n_tbl_del" != 0 ]; then echo "- 仅源侧存在（目标缺 $n_tbl_del 张表）："; emit_list "$t_only_s"; fi
    if [ "$n_tbl_add" != 0 ]; then echo "- 仅目标侧存在（源缺 $n_tbl_add 张表）："; emit_list "$t_only_d"; fi
  fi

  echo
  echo "### 字段增减（两侧共有的表内）"
  echo
  if [ "$n_col_del" = 0 ] && [ "$n_col_add" = 0 ]; then
    echo '- 无：共有表的字段集合一致'
  else
    if [ "$n_col_del" != 0 ]; then echo "- 源有、目标无（$n_col_del 个）："; emit_list "$f_only_s"; fi
    if [ "$n_col_add" != 0 ]; then echo "- 目标有、源无（$n_col_add 个）："; emit_list "$f_only_d"; fi
  fi

  echo
  echo "### 字段属性差异（字段级，共 $changed 处）"
  echo
  if [ "$changed" = 0 ]; then
    echo '- 无：共有字段的类型、可空性、默认值一致'
  else
    echo '| 表.字段 | 源类型 | 目标类型 | 源可空 | 目标可空 | 源默认值 | 目标默认值 | 差异项 |'
    echo '|---|---|---|---|---|---|---|---|'
    join -t$'\t' -j1 "$sk" "$dk" | awk -F'\t' '
      $2!=$5 || $3!=$6 || $4!=$7 {
        what=""
        if ($2!=$5) what = what "类型 "
        if ($3!=$6) what = what "可空 "
        if ($4!=$7) what = what "默认值 "
        gsub(/ $/, "", what)
        printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n", $1,
          ($2==""?"—":$2), ($5==""?"—":$5), $3, $6,
          ($4==""?"—":$4), ($7==""?"—":$7), what
      }' | head -60
    [ "$changed" -gt 60 ] && printf '| …（另有 %s 处，用 --out 导出完整报告） ||||||||\n' "$((changed-60))"
  fi

  echo
  echo "### 未覆盖范围"
  echo
  echo '- 不比对数据行、索引、约束、序列、注释、触发器、权限与表空间；不生成、不执行任何变更 SQL。'

  rm -rf "$RD"
}

# ---------- 主流程 ----------
emit() {  # 输出报告并设置退出码：0=一致，1=有差异，2=错误
  local rpt
  rpt=$(report "$@")
  if [ -n "$OUT" ]; then
    printf '%s\n' "$rpt" | tee "$OUT"
    echo "报告已写入：$OUT" >&2
  else
    printf '%s\n' "$rpt"
  fi
  if printf '%s' "$rpt" | grep -q '存在差异'; then exit 1; fi
  exit 0
}

case "$MODE" in
  compare)
    [ -f "$C_SRC" ] && [ -f "$C_DST" ] || die "compare 模式需要 --src=<快照> --dst=<快照>，且两个文件都要存在"
    emit "$C_SRC" "$C_DST" "$(basename "$C_SRC")" "$(basename "$C_DST")"
    ;;
  dump)
    check_common; load_sql
    case "$DUMP_SIDE" in src|dst) ;; *) die "dump 模式需要 --side=src|dst" ;; esac
    [ "$DUMP_SIDE" = "dst" ] && [ -z "$DST_HOST" ] && die "必须手动指定 --dst-db=<远程主机名>，无默认值"
    command -v psql >/dev/null 2>&1 || die "本机未安装 psql 客户端"
    locate_service
    of=$(mktemp); trap 'rm -f "$of"' EXIT
    capture_side "$DUMP_SIDE" "$of" || die "抓取失败"
    cat "$of"
    ;;
  run)
    [ -n "$DST_HOST" ] || die "必须手动指定 --dst-db=<远程主机名>：目标环境没有默认值，不允许猜测（源侧默认已是本地开发环境 --src-db=dev）"
    check_common; load_sql
    command -v psql >/dev/null 2>&1 || die "本机未安装 psql 客户端"
    [ "$SRC_HOST" != "$DST_HOST" ] || die "源主机与目标主机相同（$DST_HOST），无需比对"
    locate_service
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    capture_side src "$TMP/src.tsv" || die "源侧抓取失败"
    capture_side dst "$TMP/dst.tsv" || die "目标侧抓取失败"
    SLABEL="${SRC_HOST:-本机}/${SRC_ENV}"; DLABEL="$DST_HOST"
    emit "$TMP/src.tsv" "$TMP/dst.tsv" "$SLABEL" "$DLABEL"
    ;;
esac
