#!/bin/bash
# <SERVICE_NAME> 部署脚本
# 支持本地和远程（SSH）部署，后端 JAR 由 supervisord 管理，通过 nginx 反向代理对外访问。
# 规范参考：specs/deployment.md（本工程）、specs/deployment-common.md（跨项目通用）
set -euo pipefail

# ==============================================================================
# 服务与端口表（由 /new-java-project skill 初始化时填入）
# 新增微服务时在这里追加条目：SERVICES、SERVICE_PORTS、SERVICE_HEALTH_PATHS、SERVICE_DBS，
# 并在 deploy-conf/nginx/<SERVICE_NAME>.<env>.conf 中为它补一条 location 反代。
# 端口变更需同步更新 specs/deployment-common.md 的端口分配总表。
# ==============================================================================
SITE_NAME="<SERVICE_NAME>"       # 站点名：一个工程一份 nginx 站点配置，多微服务共用该站点
NGINX_PORT=<NGINX_PORT>          # nginx 对外监听端口
SERVICES=("<SERVICE_NAME>")      # 本工程的全部微服务名（与 src/backend/<name> 目录同名）
declare -A SERVICE_PORTS=(
    ["<SERVICE_NAME>"]=<APP_PORT>            # Spring Boot 内部端口（只绑 127.0.0.1）
)
declare -A SERVICE_HEALTH_PATHS=(
    ["<SERVICE_NAME>"]="/api/<SERVICE_NAME>/health"   # 应用内健康检查路径
)
declare -A SERVICE_DBS=(
    ["<SERVICE_NAME>"]="<DB_NAME>"           # 该服务对应的数据库名（--target db 同步范围）
)
# ==============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [deploy.sh] $*"
}

log_step() {
    echo
    log "$*"
}

fail() {
    log "错误: $*"
    echo "[STATUS] ERROR - 部署失败：$*"
    exit 1
}

fail_maven_build() {
    local log_file="$1"
    log "错误: Maven 构建失败，错误日志如下（最后 120 行）:"
    tail -n 120 "$log_file" || true
    echo "[STATUS] ERROR - Maven 构建失败，完整日志: $log_file"
    exit 1
}

usage() {
    cat <<'EOF'
用法:
  bash scripts/deploy.sh [选项]

选项:
  -t, --target all|backend|web|ssl|android|db
                  部署目标。默认: all。支持逗号分隔多值（如 -t backend,web），
                  按书写顺序叠加；出现 all 时先重置为默认组合（backend+web）。
                  android 构建 Android APK：不指定 --env 时三套环境全构；
                  指定 --env dev|test|prod 时只构建该环境。
                  db 将本地 dev 数据库同步到远程（需 --remote；破坏性：drop+recreate）。
  -s, --services NAME[,NAME...]
                  服务名列表（逗号分隔）：本次只部署列出的服务。每个服务对应
                  src/backend/<name> 模块，独立的服务目录、日志目录、数据库与
                  supervisor 进程。可选值见脚本顶部 SERVICES 表。
                  未显式指定 --target 时，指定 --services 即视为只部后端（不部 Web）。
  -e, --env dev|test|prod
                  目标环境（影响 nginx 站点配置、SSL 证书、env 文件选择）。默认: dev
                  env 文件：dev→.env，test→.env.test，prod→.env.prod（缺失时回退 .env）。
                  android target：dev→assembleDevRelease，test→assembleStagingRelease，
                  prod→assembleProdRelease（test 对应 staging flavor，Gradle 限制）。
  -r, --remote USER@HOST
                  部署到远程服务器（SSH 密钥认证）。本地构建，rsync 上传，远程重启。
                  示例: root@192.168.1.100
      --all       同 --target all
      --backend   同 --target backend
      --web       同 --target web
      --ssl       同 --target ssl
      --android   同 --target android
      --db        叠加数据库同步（可与 --target backend 组合：构建完成后先同步库再重启）
  -y, --yes       跳过二次确认（db 同步时跳过 drop/recreate 确认）
  -h, --help      显示本帮助

目标说明:
  backend   Maven 构建 JAR → supervisord 管理 → 同步 nginx 站点配置
  web       构建前端静态资源（npm）并部署
  ssl       安装 nginx + SSL 证书配置（需先用 scripts/apply-ssl.sh 申请证书；仅支持 test|prod）
  android   Gradle 构建 APK，产物输出到 mobile-apps/（无 SDK 时回退源码包）
  db        pg_dump 本地 dev 库 → rsync 上传 → 远程 drop+create+restore（需 --remote）
  all       backend + web（依次执行），ssl/android/db 须单独触发

数据库同步说明:
  源库凭据从 src/backend/${服务}/.env 读取（DB_HOST/DB_PORT/DB_USERNAME/DB_PASSWORD）。
  同步范围 = 本次 --services 选中服务在 SERVICE_DBS 表里对应的库。
  --target db            停止服务 → 同步 → 恢复服务（仅数据库，不部署代码）
  --target backend --db  Maven 构建 → 停止服务 → 同步库 → 上传 JAR → 重启服务

环境说明:
  dev   无域名，HTTP，IP+端口访问（deploy-conf/nginx/${SITE_NAME}.dev.conf）
  test  独立机器，测试域名 + HTTPS（需先申请证书）
  prod  独立机器，生产域名 + HTTPS（需先申请证书）

示例:
  bash scripts/deploy.sh
  bash scripts/deploy.sh --target backend
  bash scripts/deploy.sh -t backend,web --env test --remote root@192.168.1.100
  bash scripts/deploy.sh --target backend --env test --remote root@192.168.1.100
  bash scripts/deploy.sh -s order-service -t backend --remote root@192.168.1.100
  bash scripts/deploy.sh --target ssl --env test --remote root@192.168.1.100
  bash scripts/deploy.sh --target ssl --env prod --remote root@192.168.1.100
  bash scripts/deploy.sh --target android
  bash scripts/deploy.sh --target android --env prod
  bash scripts/deploy.sh --target db --remote root@192.168.1.100
  bash scripts/deploy.sh --target db --remote root@192.168.1.100 --yes
  bash scripts/deploy.sh --target backend --db --env test --remote root@192.168.1.100
EOF
}

require_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || fail "缺少必要命令: $cmd"
}

# ── 服务表校验 ────────────────────────────────────────────────────

is_known_service() {
    local want="$1" known
    for known in "${SERVICES[@]}"; do
        [ "$want" = "$known" ] && return 0
    done
    return 1
}

service_backend_dir() {
    echo "$PROJECT_DIR/src/backend/$1"
}

# ── 健康检查 ──────────────────────────────────────────────────────

wait_service_ready() {
    local service="$1"
    local port="${SERVICE_PORTS[$service]:-}"
    local timeout="${SERVICE_READY_TIMEOUT:-420}"
    local health_path="${SERVICE_HEALTH_PATHS[$service]:-}"
    local url started_at elapsed http_code

    [ -n "$port" ] && [ -n "$health_path" ] || fail "未配置 $service 的健康检查端口或路径"
    url="http://127.0.0.1:$port$health_path"
    started_at="$(date +%s)"

    log "等待服务就绪: $service（$url），最长 ${timeout}s，每 5s 检测一次"
    while true; do
        http_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || echo "000")"
        elapsed=$(( $(date +%s) - started_at ))
        if [ "$http_code" = "200" ]; then
            log "服务已就绪: $service（耗时 ${elapsed}s，HTTP $http_code）"
            return 0
        fi
        if [ "$elapsed" -ge "$timeout" ]; then
            supervisorctl -c "$SUPERVISOR_CONF" status "$service" || true
            tail -n 120 "$LOG_ROOT/$service/supervisord.log" 2>/dev/null || true
            fail "$service 启动超时，健康检查未通过: $url（最后 HTTP $http_code）"
        fi
        log "检测中: $service 尚未就绪（已等待 ${elapsed}s / ${timeout}s，HTTP $http_code）"
        sleep 5
    done
}

remote_wait_service_ready() {
    local service="$1"
    local port="${SERVICE_PORTS[$service]:-}"
    local timeout="${SERVICE_READY_TIMEOUT:-420}"
    local health_path="${SERVICE_HEALTH_PATHS[$service]:-}"
    local started_at elapsed http_code

    [ -n "$port" ] && [ -n "$health_path" ] || fail "未配置 $service 的健康检查端口或路径"
    started_at="$(date +%s)"

    log "等待远程服务就绪: $service（ssh $REMOTE_HOST → http://127.0.0.1:$port$health_path），最长 ${timeout}s"
    while true; do
        http_code="$(remote_exec "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:$port$health_path" 2>/dev/null || echo "000")"
        elapsed=$(( $(date +%s) - started_at ))
        if [ "$http_code" = "200" ]; then
            log "远程服务已就绪: $service（耗时 ${elapsed}s，HTTP $http_code）"
            return 0
        fi
        if [ "$elapsed" -ge "$timeout" ]; then
            remote_exec "supervisorctl -c $SUPERVISOR_CONF status $service" || true
            fail "$service 远程启动超时: ssh $REMOTE_HOST → http://127.0.0.1:$port$health_path（最后 HTTP $http_code）"
        fi
        log "检测中: $service 远程尚未就绪（已等待 ${elapsed}s / ${timeout}s，HTTP $http_code）"
        sleep 5
    done
}

# ── 版本 / JAR ────────────────────────────────────────────────────

# 从服务 pom.xml 读取版本号：先按 <artifactId>服务名</artifactId> 定位，
# 找不到（多模块子 pom 继承父版本）时退回 </parent> 之后的第一个 <version>。
read_backend_version() {
    local pom="$1" service="$2" version=""
    [ -f "$pom" ] || return 0
    version="$(awk -v svc="$service" '
        index($0, "<artifactId>" svc "</artifactId>") {
            # 同一行就跟着 <version> 的紧凑写法（minify 过的 pom）也要能取到
            if (match($0, /<version>[^<]*<\/version>/)) {
                v = substr($0, RSTART + 9, RLENGTH - 19)
                print v; exit
            }
            found = 1; next
        }
        found && /<version>/ {
            gsub(/.*<version>|<\/version>.*/, "", $0)
            print $0
            exit
        }
    ' "$pom")"
    if [ -z "$version" ]; then
        version="$(awk '
            seen && /<version>/ {
                gsub(/.*<version>|<\/version>.*/, "", $0)
                print $0
                exit
            }
            /<\/parent>/ { seen = 1 }
        ' "$pom")"
    fi
    echo "$version"
}

# JAR 定位：优先 <svc>/target/，其次一层子模块目录 <svc>/*/target/（多模块工程）。
# 同一目录里先认 <服务名>*.jar（正常产物），全都没有才回退任意 jar——
# 否则 target 里的第三方/附属 jar 会被误当成本服务的产物部署。
# find 用 -print -quit 自己停在第一个匹配，不接 head：head 先退出会让 find 收到
# SIGPIPE，pipefail 下整个部署在这里静默中止（没有任何错误行）。
get_jar_path() {
    local service="$1"
    local backend_dir search found pattern
    backend_dir="$(service_backend_dir "$service")"
    for pattern in "$service*.jar" "*.jar"; do
        for search in "$backend_dir/target" "$backend_dir"/*/target; do
            [ -d "$search" ] || continue
            found="$(find "$search" -maxdepth 1 -type f -name "$pattern" \
                ! -name "*original*" ! -name "*sources*" ! -name "*javadoc*" -print -quit 2>/dev/null || true)"
            if [ -n "$found" ]; then
                printf '%s\n' "$found"
                return 0
            fi
        done
    done
    return 0
}

# ── supervisord 配置（inline 生成，不在版本库中维护静态 ini）──────
# 程序配置的后缀由目标主机 supervisord 的 [include] files= 模式决定，不是固定 .conf：
# apt 安装默认 include *.conf，但不少在跑的主机被改成只 include *.ini。写错后缀的文件
# supervisord 根本不读，reread/update 也不报错，服务继续按上一份定义运行——属于
# "改了配置不生效且没有任何提示"那类故障。这里现问主机配置决定后缀，并对未被加载的
# 同名孪生文件给出告警。

supervisor_include_text() {
    if [ -n "$REMOTE_HOST" ]; then
        remote_exec "cat $SUPERVISOR_CONF" 2>/dev/null || true
    elif [ -f "$SUPERVISOR_CONF" ]; then
        cat "$SUPERVISOR_CONF"
    fi
}

# 解析主机 [include] files= 里的后缀；显式 SUPERVISOR_CONF_SUFFIX 优先，解析不到退回 apt 默认 conf
detect_supervisor_suffix() {
    local patterns
    if [ -n "${SUPERVISOR_CONF_SUFFIX:-}" ]; then
        printf '%s\n' "$SUPERVISOR_CONF_SUFFIX"
        return 0
    fi
    # awk 不提前 exit：管道里读 stdin 的命令提前收到退出会拿 SIGPIPE，pipefail 下静默中止部署
    patterns="$(supervisor_include_text | awk '/^[[:space:]]*files[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); print }')"
    # 只匹配 glob 本体（"*.conf" / "*.ini"），不能匹配裸 "conf"——include 路径里就带 conf.d
    case "$patterns" in
        *"*.conf"*) printf 'conf\n' ;;
        *"*.ini"*)  printf 'ini\n' ;;
        *)          printf 'conf\n' ;;
    esac
}

supervisor_program_conf() {
    printf '%s/%s.%s\n' "$SUPERVISOR_CONF_DIR" "$1" "$SUPERVISOR_SUFFIX"
}

# 另一个后缀的同名文件：要么是没被 include 的死文件，要么与本次写入重复定义同一 program
warn_supervisor_twin() {
    local service="$1" twin other
    other="conf"
    [ "$SUPERVISOR_SUFFIX" = "conf" ] && other="ini"
    twin="$SUPERVISOR_CONF_DIR/$service.$other"
    if { [ -n "$REMOTE_HOST" ] && remote_exec "test -f $twin" 2>/dev/null; } \
        || { [ -z "$REMOTE_HOST" ] && [ -f "$twin" ]; }; then
        log "警告: 存在另一后缀的本服务配置 $twin（本次写入的是 .$SUPERVISOR_SUFFIX）"
        log "      两者只有一份会被 supervisord 加载，另一份会误导排查；确认无用后删除：rm $twin"
    fi
}

supervisor_conf_body() {
    local service="$1"
    local app_dir="$APP_ROOT/$service"
    local log_dir="$LOG_ROOT/$service"
    cat <<EOF
[program:$service]
command=/bin/bash -c "[ -f $app_dir/.env ] && { set -a; . $app_dir/.env; set +a; }; exec \${JAVA_EXEC:-/usr/bin/java} -jar $app_dir/$service.jar"
directory=$app_dir
autostart=true
autorestart=true
startsecs=10
startretries=3
stdout_logfile=$log_dir/supervisord.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=30
stdout_capture_maxbytes=1MB
stderr_logfile=$log_dir/supervisord.log
stderr_logfile_maxbytes=10MB
stderr_logfile_backups=30
stderr_capture_maxbytes=1MB
EOF
}

write_supervisor_conf() {
    local service="$1"
    local log_dir="$LOG_ROOT/$service"
    local conf_file
    conf_file="$(supervisor_program_conf "$service")"
    mkdir -p "$log_dir" "$SUPERVISOR_CONF_DIR"
    supervisor_conf_body "$service" >"$conf_file"
    warn_supervisor_twin "$service"
}

# ── env 文件：按环境选择 .env / .env.test / .env.prod ──────────────

resolve_env_file() {
    local service="$1"
    local base_dir env_name
    base_dir="$(service_backend_dir "$service")"
    env_name="${DEPLOY_ENV:-dev}"
    if [ "$env_name" != "dev" ] && [ -f "$base_dir/.env.$env_name" ]; then
        echo "$base_dir/.env.$env_name"
    else
        echo "$base_dir/.env"
    fi
}

env_keys() {
    grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$1" 2>/dev/null | cut -d= -f1 | sort -u || true
}

# 三套 env 文件键集必须一致：环境模板缺键 = 部署后远端缺配置（且往往静默失效，
# 不会启动报错）。dev 的 .env 是键集基准，这里只比对、不阻断部署。
check_env_keyset() {
    local service="$1" env_name="$2"
    local base_dir ref cur missing extra
    [ "$env_name" != "dev" ] || return 0
    base_dir="$(service_backend_dir "$service")"
    ref="$base_dir/.env"
    cur="$base_dir/.env.$env_name"
    { [ -f "$ref" ] && [ -f "$cur" ]; } || return 0

    missing="$(comm -23 <(env_keys "$ref") <(env_keys "$cur") | tr '\n' ' ')"
    extra="$(comm -13 <(env_keys "$ref") <(env_keys "$cur") | tr '\n' ' ')"
    if [ -n "$missing" ]; then
        log "警告: $service 的 .env.$env_name 缺少 dev .env 中的键（部署后该项在 $env_name 环境为空）: $missing"
    fi
    if [ -n "$extra" ]; then
        log "警告: $service 的 .env.$env_name 存在 dev .env 没有的键: $extra"
    fi
}

# ── 本地部署 ─────────────────────────────────────────────────────

deploy_service_jar() {
    local service="$1"
    local app_dir="$APP_ROOT/$service"
    local jar_file target_jar env_file backend_dir version
    backend_dir="$(service_backend_dir "$service")"
    version="${SERVICE_VERSIONS[$service]}"
    target_jar="$app_dir/$service-$version.jar"

    jar_file="$(get_jar_path "$service")"
    [ -n "$jar_file" ] && [ -f "$jar_file" ] || fail "未找到 $service JAR（$backend_dir/target/ 下无匹配文件）"

    mkdir -p "$app_dir"
    cp -f "$jar_file" "$target_jar.tmp"
    mv -f "$target_jar.tmp" "$target_jar"
    ln -sfn "$service-$version.jar" "$app_dir/$service.jar"

    env_file="$(resolve_env_file "$service")"
    check_env_keyset "$service" "${DEPLOY_ENV:-dev}"
    if [ -f "$env_file" ]; then
        cp -f "$env_file" "$app_dir/.env"
        log "已部署 .env: $service（来源: $env_file）"
    else
        log "警告: 未找到 $service 的 env 文件: $env_file"
    fi

    log "写入 supervisor 配置: $(supervisor_program_conf "$service")"
    write_supervisor_conf "$service"
    log "已部署 JAR: $service -> $target_jar"
}

restart_service() {
    local service="$1"
    log "重启 supervisor 服务: $service"
    if ! supervisorctl -c "$SUPERVISOR_CONF" restart "$service"; then
        supervisorctl -c "$SUPERVISOR_CONF" start "$service"
    fi
}

# ── 远程部署 ─────────────────────────────────────────────────────

remote_exec() {
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$REMOTE_HOST" "$@"
}

remote_deploy_service_jar() {
    local service="$1"
    local app_dir="$APP_ROOT/$service"
    local log_dir="$LOG_ROOT/$service"
    local conf_file
    conf_file="$(supervisor_program_conf "$service")"
    local jar_file target_jar env_file backend_dir version
    backend_dir="$(service_backend_dir "$service")"
    version="${SERVICE_VERSIONS[$service]}"
    target_jar="$app_dir/$service-$version.jar"

    jar_file="$(get_jar_path "$service")"
    [ -n "$jar_file" ] && [ -f "$jar_file" ] || fail "未找到 $service JAR（$backend_dir/target/ 下无匹配文件）"

    log "上传 JAR: $service → $REMOTE_HOST:$target_jar"
    remote_exec "mkdir -p $app_dir"
    rsync -az "$jar_file" "$REMOTE_HOST:$target_jar.tmp"
    remote_exec "mv -f $target_jar.tmp $target_jar && ln -sfn $service-$version.jar $app_dir/$service.jar"

    env_file="$(resolve_env_file "$service")"
    check_env_keyset "$service" "${DEPLOY_ENV:-dev}"
    if [ -f "$env_file" ]; then
        rsync -az "$env_file" "$REMOTE_HOST:$app_dir/.env"
        log "已同步 .env: $service（来源: $env_file）"
    else
        log "警告: 未找到 $service 的 env 文件: $env_file"
    fi

    log "写入远程 supervisor 配置: $REMOTE_HOST:$conf_file"
    remote_exec "mkdir -p $log_dir $SUPERVISOR_CONF_DIR"
    # 用进程替换而非管道：pipefail 下 ssh 提前退出会让左侧 cat 收到 SIGPIPE，
    # 整个部署会在这里静默中止（只表现为脚本突然结束，没有任何错误行）
    remote_exec "cat > $conf_file" < <(supervisor_conf_body "$service")
    log "已部署 JAR: $service -> $REMOTE_HOST:$target_jar"
}

remote_restart_service() {
    local service="$1"
    log "远程重启 supervisor 服务: $service"
    remote_exec "supervisorctl -c $SUPERVISOR_CONF reread && supervisorctl -c $SUPERVISOR_CONF update"
    if ! remote_exec "supervisorctl -c $SUPERVISOR_CONF restart $service"; then
        remote_exec "supervisorctl -c $SUPERVISOR_CONF start $service"
    fi
}

remote_deploy_web_app() {
    local source_dir="$1"
    local deploy_path="$2"
    log "上传 Web 静态资源 → $REMOTE_HOST:$deploy_path"
    remote_exec "mkdir -p $deploy_path"
    rsync -az --delete "$source_dir/dist/" "$REMOTE_HOST:$deploy_path/"
    remote_exec "nginx -s reload" || true
    log "Web 已部署到远程: $deploy_path"
}

# ── SSL / Nginx ───────────────────────────────────────────────────

cert_domain_for_env() {
    case "$1" in
        test) echo "<TEST_DOMAIN>" ;;
        prod) echo "<PROD_DOMAIN>" ;;
        *) echo "" ;;
    esac
}

# 证书文件名 = 申请域名（见 apply-ssl.sh 的 CERT_DIR），test/prod 互不覆盖
cert_paths_for_env() {
    local domain
    domain="$(cert_domain_for_env "$1")"
    [ -n "$domain" ] || return 1
    echo "$NGINX_SSL_DIR/$domain.pem $NGINX_SSL_DIR/$domain.key"
}

has_cert_for_env() {
    local env="$1" cert
    cert="$(cert_paths_for_env "$env")" || return 1
    if [ -n "$REMOTE_HOST" ]; then
        remote_exec "test -f ${cert% *} && test -f ${cert#* }" 2>/dev/null
    else
        [ -f "${cert% *}" ] && [ -f "${cert#* }" ]
    fi
}

# 按环境解析可用的站点配置，结果写入 RESOLVED_SITE_CONF / RESOLVED_SITE_HTTPS：
# 有证书用该环境（HTTPS）配置，否则降级 dev（HTTP）配置。
# 不用 echo 返回——降级要在这里打日志，命令替换会把日志吞进变量值。
resolve_site_conf() {
    local env="$1" candidate
    RESOLVED_SITE_HTTPS=false
    if has_cert_for_env "$env"; then
        RESOLVED_SITE_HTTPS=true
        candidate="$DEPLOY_CONF_DIR/nginx/$SITE_NAME.$env.conf"
        [ -f "$candidate" ] || fail "nginx 站点配置不存在: $candidate"
    else
        if [ "$env" != "dev" ]; then
            log "警告: 目标主机未找到 $env 环境证书（$NGINX_SSL_DIR/），降级使用 dev 配置（HTTP）；先跑 scripts/apply-ssl.sh $env"
        fi
        candidate="$DEPLOY_CONF_DIR/nginx/$SITE_NAME.dev.conf"
        [ -f "$candidate" ] || fail "nginx dev 配置不存在: $candidate"
    fi
    RESOLVED_SITE_CONF="$candidate"
}

# --target ssl：安装 nginx（apt）+ 主配置 + 站点配置（按证书存在与否选 HTTPS/HTTP）
deploy_nginx_ssl() {
    local env="$DEPLOY_ENV"
    local nginx_main_conf="$DEPLOY_CONF_DIR/nginx/nginx.conf"
    local remote_site_conf="$NGINX_CONF_DIR/$SITE_NAME.conf"
    resolve_site_conf "$env"
    local nginx_conf="$RESOLVED_SITE_CONF"
    local has_cert="$RESOLVED_SITE_HTTPS"

    if [ ! -f "$nginx_main_conf" ]; then
        log "警告: nginx 主配置不存在: $nginx_main_conf（跳过主配置安装，仅同步站点配置）"
    fi

    if [ -n "$REMOTE_HOST" ]; then
        log "安装 nginx（apt）: $REMOTE_HOST"
        remote_exec "apt-get update -qq && apt-get install -y -qq nginx >/dev/null 2>&1" || fail "远程安装 nginx 失败"
        if [ -f "$nginx_main_conf" ]; then
            log "上传 nginx.conf 主配置 → $REMOTE_HOST:/etc/nginx/nginx.conf"
            rsync -az "$nginx_main_conf" "$REMOTE_HOST:/etc/nginx/nginx.conf"
        fi
        log "上传站点配置 → $REMOTE_HOST:$remote_site_conf"
        remote_exec "mkdir -p $NGINX_CONF_DIR"
        rsync -az "$nginx_conf" "$REMOTE_HOST:$remote_site_conf"
        remote_exec "rm -f /etc/nginx/sites-enabled/default"
        log "验证并重载 nginx"
        remote_exec "nginx -t" || fail "远程 nginx 配置检测失败"
        remote_exec "systemctl enable nginx && systemctl reload nginx"
    else
        log "安装 nginx（apt）"
        apt-get update -qq && apt-get install -y -qq nginx >/dev/null 2>&1 || fail "安装 nginx 失败"
        if [ -f "$nginx_main_conf" ]; then
            log "部署 nginx.conf 主配置到 /etc/nginx/nginx.conf"
            cp -f "$nginx_main_conf" /etc/nginx/nginx.conf
        fi
        log "部署站点配置到 $remote_site_conf"
        mkdir -p "$NGINX_CONF_DIR"
        cp -f "$nginx_conf" "$remote_site_conf"
        rm -f /etc/nginx/sites-enabled/default
        log "验证并重载 nginx"
        nginx -t || fail "nginx 配置检测失败"
        systemctl enable nginx && systemctl reload nginx
    fi

    if [ "$has_cert" = true ]; then
        log "Nginx 部署完成（环境: $env，HTTPS）"
    else
        log "Nginx 部署完成（环境: dev，HTTP）"
    fi
}

# 后端部署时自动同步 nginx 站点配置（目标已装 nginx 则校验+reload，未装则跳过）
sync_nginx_conf() {
    local env="${DEPLOY_ENV:-dev}"
    local site_conf="$NGINX_CONF_DIR/$SITE_NAME.conf"

    if [ -n "$REMOTE_HOST" ]; then
        remote_exec "command -v nginx >/dev/null 2>&1" || {
            log "目标主机未安装 nginx，跳过站点配置同步"
            return 0
        }
    else
        command -v nginx >/dev/null 2>&1 || {
            log "本机未安装 nginx，跳过站点配置同步"
            return 0
        }
    fi

    resolve_site_conf "$env"
    local nginx_conf="$RESOLVED_SITE_CONF"
    log "同步 nginx 站点配置: $nginx_conf → $site_conf"

    if [ -n "$REMOTE_HOST" ]; then
        rsync -az "$nginx_conf" "$REMOTE_HOST:$site_conf"
        remote_exec "nginx -t" || fail "远程 nginx 配置检测失败"
        remote_exec "systemctl reload nginx || nginx -s reload" || fail "远程 nginx 重载失败"
    else
        cp -f "$nginx_conf" "$site_conf"
        nginx -t || fail "nginx 配置检测失败"
        systemctl reload nginx 2>/dev/null || nginx -s reload || fail "nginx 重载失败"
    fi
    log "nginx 站点配置同步完成（来源: $(basename "$nginx_conf")）"
}

# ── Android 构建 ──────────────────────────────────────────────────

build_android_app() {
    local src="$ANDROID_DIR"
    export ANDROID_HOME="${ANDROID_HOME:-/data/android-sdks}"
    export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"

    local gradle_bin=""
    if [ -x "$src/gradlew" ]; then
        gradle_bin="$src/gradlew"
    elif command -v gradle >/dev/null 2>&1; then
        gradle_bin="gradle"
    fi

    # flavor 映射：test 环境对应 staging（Gradle 禁止 flavor 名以 test 开头）
    local envs=() flavors=()
    case "$DEPLOY_ENV" in
        dev|test|prod) envs=("$DEPLOY_ENV") ;;
        *) envs=(dev test prod) ;;
    esac
    local i
    for i in "${envs[@]}"; do
        if [ "$i" = "test" ]; then flavors+=("staging"); else flavors+=("$i"); fi
    done

    if [ -n "$gradle_bin" ] && [ -d "$ANDROID_HOME" ]; then
        local tasks=() f
        for f in "${flavors[@]}"; do
            tasks+=("assemble${f^}Release")
        done

        # 签名凭据来自 src/android/.env（不入库），缺失时回退 debug 签名
        local sign_args=()
        if [ -f "$src/.env" ]; then
            local keystore_env k v
            keystore_env="$(grep -E '^RELEASE_(STORE_FILE|STORE_PASSWORD|KEY_ALIAS|KEY_PASSWORD)=' "$src/.env" 2>/dev/null || true)"
            if [ -n "$keystore_env" ]; then
                while IFS='=' read -r k v; do
                    [ -n "$k" ] && sign_args+=("-P$k=$v")
                done <<< "$keystore_env"
                log "Android 签名: 使用专属 keystore（$(grep '^RELEASE_STORE_FILE=' "$src/.env" | cut -d= -f2-)）"
            fi
        else
            log "警告: 未找到 $src/.env 签名凭据，release APK 将回退 debug 签名"
        fi

        log "Gradle 构建 Android APK（envs: ${envs[*]}）... ANDROID_HOME=$ANDROID_HOME"
        GRADLE_LOG_FILE="$RUNTIME_DIR/deploy-android-build-$(date '+%Y%m%d%H%M%S').log"
        log "Gradle 构建日志: $GRADLE_LOG_FILE"
        if (cd "$src" && "$gradle_bin" "${tasks[@]}" ${sign_args[@]+"${sign_args[@]}"} --no-daemon --console=plain) >"$GRADLE_LOG_FILE" 2>&1; then
            mkdir -p "$MOBILE_APPS_DIR"
            local apk idx
            for idx in "${!envs[@]}"; do
                f="${flavors[$idx]}"
                apk="$(find "$src/app/build/outputs/apk/$f/release" -name "*.apk" -print -quit 2>/dev/null || true)"
                if [ -z "$apk" ]; then
                    fail "未找到 ${envs[$idx]} 环境 APK 产物，请检查 Gradle 构建输出"
                fi
                MOBILE_ANDROID_ARTIFACTS+=("$MOBILE_APPS_DIR/$SITE_NAME-android-${envs[$idx]}-${MOBILE_APP_VERSION}.apk")
                cp -f "$apk" "${MOBILE_ANDROID_ARTIFACTS[-1]}"
                log "Android 产物（${envs[$idx]}）: ${MOBILE_ANDROID_ARTIFACTS[-1]}"
            done
            MOBILE_ANDROID_MODE="APK（Gradle 构建，envs: ${envs[*]}）"
            return
        fi
        log "错误: Android 构建失败，日志最后 120 行:"
        tail -n 120 "$GRADLE_LOG_FILE" || true
        fail "Android 构建失败，完整日志: $GRADLE_LOG_FILE"
    fi

    log "未检测到 Gradle + Android SDK（$ANDROID_HOME），回退为源码打包"
    mkdir -p "$MOBILE_APPS_DIR"
    MOBILE_ANDROID_ARTIFACTS=("$MOBILE_APPS_DIR/android-src-${MOBILE_APP_VERSION}.tar.gz")
    tar -czf "${MOBILE_ANDROID_ARTIFACTS[0]}" -C "$(dirname "$src")" "$(basename "$src")"
    MOBILE_ANDROID_MODE="源码包（本机无 Android 工具链）"
    log "Android 产物: ${MOBILE_ANDROID_ARTIFACTS[0]}"
}

# ── 数据库同步（PostgreSQL） ───────────────────────────────────────

read_env_value() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 0
    awk -v k="$key" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$file"
}

stop_selected_services() {
    local service
    for service in "${SELECTED_SERVICES[@]}"; do
        if [ -n "$REMOTE_HOST" ]; then
            remote_exec "supervisorctl -c $SUPERVISOR_CONF stop $service" || true
        else
            supervisorctl -c "$SUPERVISOR_CONF" stop "$service" || true
        fi
        log "已停止服务: $service"
    done
}

start_selected_services() {
    local service
    for service in "${SELECTED_SERVICES[@]}"; do
        if [ -n "$REMOTE_HOST" ]; then
            remote_exec "supervisorctl -c $SUPERVISOR_CONF reread && supervisorctl -c $SUPERVISOR_CONF update" || true
            remote_exec "supervisorctl -c $SUPERVISOR_CONF start $service" || true
        else
            supervisorctl -c "$SUPERVISOR_CONF" reread
            supervisorctl -c "$SUPERVISOR_CONF" update
            supervisorctl -c "$SUPERVISOR_CONF" start "$service" || true
        fi
        log "已启动服务: $service"
    done
}

# 本地 dev 库 pg_dump → 上传 → 远程断开连接并 drop+create+restore（破坏性）
sync_databases() {
    [ -n "$REMOTE_HOST" ] || fail "--target db 需要指定 --remote USER@HOST"

    local db_list=() service
    for service in "${SELECTED_SERVICES[@]}"; do
        db_list+=("${SERVICE_DBS[$service]:-$service}")
    done

    if [ "$AUTO_CONFIRM" != true ]; then
        log "警告: 此操作将删除并重建 $REMOTE_HOST 上的数据库: ${db_list[*]}"
        printf "输入 yes 确认继续: "
        local confirm
        read -r confirm
        [ "$confirm" = "yes" ] || fail "已取消数据库同步"
    fi

    # 源库凭据取第一个选中服务的 dev .env（同主机部署共用一套 PostgreSQL）
    local src_service src_env_file src_host src_port src_user src_password
    src_service="${SELECTED_SERVICES[0]}"
    src_env_file="$(service_backend_dir "$src_service")/.env"
    [ -f "$src_env_file" ] || fail "源库 env 文件不存在: $src_env_file（数据库同步需要 dev .env）"
    src_host="$(read_env_value "$src_env_file" DB_HOST)";      src_host="${src_host:-127.0.0.1}"
    src_port="$(read_env_value "$src_env_file" DB_PORT)";      src_port="${src_port:-<DB_PORT>}"
    src_user="$(read_env_value "$src_env_file" DB_USERNAME)";  src_user="${src_user:-postgres}"
    src_password="$(read_env_value "$src_env_file" DB_PASSWORD)"
    [ -n "$src_password" ] || fail "无法从 $src_env_file 读取 DB_PASSWORD"

    local ts dump_dir dbname dump_file
    ts="$(date '+%Y%m%d%H%M%S')"
    dump_dir="$RUNTIME_DIR/db-sync-$ts"
    mkdir -p "$dump_dir"

    for dbname in "${db_list[@]}"; do
        dump_file="$dump_dir/$dbname.sql"
        log "导出本地数据库: $dbname（$src_host:$src_port）"
        PGPASSWORD="$src_password" pg_dump -h "$src_host" -p "$src_port" -U "$src_user" \
            -d "$dbname" --no-owner --no-privileges -f "$dump_file" || fail "pg_dump 失败: $dbname"

        log "上传 dump → $REMOTE_HOST:/tmp/$dbname.sql"
        rsync -az "$dump_file" "$REMOTE_HOST:/tmp/$dbname.sql"
        remote_exec "chmod 644 /tmp/$dbname.sql"

        log "远程重建数据库: $dbname（断开连接 → drop → create → restore）"
        remote_exec "sudo -u postgres psql -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$dbname' AND pid<>pg_backend_pid();\" >/dev/null 2>&1" || true
        remote_exec "sudo -u postgres dropdb --if-exists $dbname" || fail "远程 dropdb 失败: $dbname"
        remote_exec "sudo -u postgres createdb $dbname" || fail "远程 createdb 失败: $dbname"
        remote_exec "sudo -u postgres psql -v ON_ERROR_STOP=1 -d $dbname -f /tmp/$dbname.sql >/dev/null" \
            || fail "远程恢复失败: $dbname"
        remote_exec "rm -f /tmp/$dbname.sql"
        log "数据库同步完成: $dbname"
    done
    log "全部数据库同步完成: ${db_list[*]} → $REMOTE_HOST"
}

# ── 参数解析 ─────────────────────────────────────────────────────

set_deploy_target() {
    case "$1" in
        all)
            # all = 重置为默认组合（backend + web），供逗号多值场景归位
            DEPLOY_BACKEND=true
            DEPLOY_WEB=true
            ;;
        backend|services|microservices)
            DEPLOY_BACKEND=true
            ;;
        web)
            DEPLOY_WEB=true
            ;;
        ssl|nginx)
            DEPLOY_SSL=true
            ;;
        android)
            DEPLOY_ANDROID=true
            ;;
        db|database)
            DEPLOY_DB=true
            DB_ONLY=true
            ;;
        *)
            fail "未知部署目标: $1；可选值: all, backend, web, ssl, android, db（可逗号分隔多值）"
            ;;
    esac
}

parse_service_list() {
    local raw="$1" items=() item
    [ -n "$raw" ] || fail "--services 不能为空"
    IFS=',' read -r -a items <<< "$raw"
    SELECTED_SERVICES=()
    for item in "${items[@]}"; do
        item="${item//[[:space:]]/}"
        [ -n "$item" ] || fail "--services 包含空服务名: $raw"
        is_known_service "$item" || fail "未知微服务: $item；可选值: ${SERVICES[*]}"
        local known duplicate=false
        for known in "${SELECTED_SERVICES[@]}"; do
            [ "$known" = "$item" ] && duplicate=true
        done
        [ "$duplicate" = true ] || SELECTED_SERVICES+=("$item")
    done
    [ "${#SELECTED_SERVICES[@]}" -gt 0 ] || fail "--services 解析后为空: $raw"
}

parse_deploy_args() {
    local target_set=false
    local services_set=false

    DEPLOY_BACKEND=true
    DEPLOY_WEB="$HAS_WEB"
    DEPLOY_SSL=false
    DEPLOY_ANDROID=false
    DEPLOY_DB=false
    DB_ONLY=false
    AUTO_CONFIRM=false
    SELECTED_SERVICES=("${SERVICES[@]}")

    # 首个显式目标出现时重置默认组合，之后逐个累积（支持逗号多值）
    apply_target() {
        if [ "$target_set" = false ]; then
            DEPLOY_BACKEND=false
            DEPLOY_WEB=false
            DEPLOY_SSL=false
            DEPLOY_ANDROID=false
            DEPLOY_DB=false
            DB_ONLY=false
            target_set=true
        fi
        local _tarr=() _t
        IFS=',' read -r -a _tarr <<< "$1"
        for _t in "${_tarr[@]}"; do
            _t="${_t//[[:space:]]/}"
            [ -n "$_t" ] && set_deploy_target "$_t"
        done
    }

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -t|--target)
                [ "$#" -ge 2 ] || fail "$1 缺少参数"
                apply_target "$2"
                shift 2
                ;;
            --all)         apply_target "all";     shift ;;
            --backend|--microservices) apply_target "backend"; shift ;;
            --web)         apply_target "web";     shift ;;
            --ssl|--nginx) apply_target "ssl";     shift ;;
            --android)     apply_target "android"; shift ;;
            --db|--database)
                DEPLOY_DB=true
                shift
                ;;
            -s|--services|--service)
                [ "$#" -ge 2 ] || fail "$1 缺少参数"
                parse_service_list "$2"
                services_set=true
                shift 2
                ;;
            -e|--env)
                [ "$#" -ge 2 ] || fail "$1 缺少参数"
                case "$2" in
                    dev|test|prod) DEPLOY_ENV="$2" ;;
                    *) fail "--env 可选值: dev, test, prod" ;;
                esac
                shift 2
                ;;
            -r|--remote)
                [ "$#" -ge 2 ] || fail "$1 缺少参数"
                REMOTE_HOST="$2"
                shift 2
                ;;
            -y|--yes)
                AUTO_CONFIRM=true
                shift
                ;;
            *)
                usage
                fail "未知参数: $1"
                ;;
        esac
    done

    # 只指定了 --services（没指定 --target）时按"只部后端"处理
    if [ "$services_set" = true ] && [ "$target_set" = false ]; then
        DEPLOY_WEB=false
    fi

    if [ "$DB_ONLY" = true ]; then
        DEPLOY_BACKEND=false
        DEPLOY_WEB=false
        DEPLOY_SSL=false
        DEPLOY_ANDROID=false
    fi
    if [ "$DEPLOY_DB" = true ]; then
        [ -n "$REMOTE_HOST" ] || fail "--db / --target db 需要指定 --remote USER@HOST"
    fi
    if [ "$DEPLOY_SSL" = true ] && [ -z "$DEPLOY_ENV" ]; then
        if [ "$DEPLOY_BACKEND" = false ] && [ "$DEPLOY_WEB" = false ]; then
            fail "--target ssl 需要指定 --env test|prod"
        fi
        log "未指定 --env，跳过 SSL/Nginx 部署"
        DEPLOY_SSL=false
    fi
    if [ "$DEPLOY_SSL" = true ] && [ "${DEPLOY_ENV:-}" = "dev" ]; then
        fail "--target ssl 仅支持 --env test|prod（dev 为 HTTP 明文环境，无证书部署）"
    fi
    if [ "$HAS_WEB" = false ] && [ "$DEPLOY_WEB" = true ]; then
        fail "本服务无前端（脚本顶部 HAS_WEB=false），--target web / all 不适用"
    fi
    if [ "$services_set" = true ] && [ "$DEPLOY_BACKEND" = false ]; then
        fail "--services 只作用于后端部署，不能与 --target web/ssl/android/db 单独组合"
    fi
    if [ "$DEPLOY_BACKEND" = false ] && [ "$DEPLOY_WEB" = false ] && [ "$DEPLOY_SSL" = false ] && [ "$DEPLOY_ANDROID" = false ] && [ "$DEPLOY_DB" = false ]; then
        fail "未选择任何部署内容"
    fi
}

# ── 早期帮助 ─────────────────────────────────────────────────────
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

# ── 工程目录校验（必须在项目根目录执行）──────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
CURRENT_DIR="$(pwd -P)"

if [ "$CURRENT_DIR" != "$PROJECT_DIR" ]; then
    fail "请在项目根目录执行: cd $PROJECT_DIR && bash scripts/deploy.sh；当前目录: $CURRENT_DIR"
fi

# ── 变量声明 ─────────────────────────────────────────────────────
REMOTE_HOST=""
DEPLOY_ENV=""
HAS_WEB=true                       # 本服务无前端时（--has-web=false）改为 false
APP_ROOT="${APP_ROOT:-/opt/soft/apps}"
LOG_ROOT="${LOG_ROOT:-/data/logs/apps}"
ANDROID_DIR="$PROJECT_DIR/src/android"
MOBILE_APPS_DIR="$PROJECT_DIR/mobile-apps"
DEPLOY_CONF_DIR="$PROJECT_DIR/deploy-conf"
RUNTIME_DIR="$PROJECT_DIR/runtime"
SUPERVISOR_CONF="${SUPERVISOR_CONF:-/etc/supervisor/supervisord.conf}"
SUPERVISOR_CONF_DIR="${SUPERVISOR_CONF_DIR:-/etc/supervisor/conf.d}"
SUPERVISOR_SUFFIX=""               # 实际后缀在部署前按目标主机 [include] 模式解析后填入
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx/conf.d}"
NGINX_SSL_DIR="${NGINX_SSL_DIR:-/etc/nginx/ssl}"
SELECTED_SERVICES=("${SERVICES[@]}")

# ==============================================================================
# 前端表（HAS_WEB=false 时把 WEB_APPS 置空即可，下面四张表不会被用到）
# 一个前端一行：源码目录 / 部署目录 / 路由前缀（须与 nginx location 一致）/ 归档标识。
# 多前端（如 boss + 门店端）时把 WEB_APPS 换成多项并填齐四张表，
# 每个前端的 basePath 由 NEXT_BASE_PATH 传给构建，构建框架不认该变量时忽略。
# ==============================================================================
WEB_APPS=("<SERVICE_NAME>")
declare -A WEB_APP_SOURCE=(
    ["<SERVICE_NAME>"]="$PROJECT_DIR/src/web"
)
declare -A WEB_APP_DEPLOY=(
    ["<SERVICE_NAME>"]="${WEB_DEPLOY_PATH:-$APP_ROOT/<SERVICE_NAME>/web}"
)
declare -A WEB_APP_BASE_PATH=(
    ["<SERVICE_NAME>"]="<WEB_PATH>"
)
declare -A WEB_APP_PROJECT_ID=(
    ["<SERVICE_NAME>"]="<SERVICE_NAME>"
)
# ==============================================================================
declare -A WEB_APP_VERSION=()

parse_deploy_args "$@"

# 手工往 WEB_APPS 里追加、但没填表的前端，按目录约定兜底补全
for _app in ${WEB_APPS[@]+"${WEB_APPS[@]}"}; do
    : "${WEB_APP_SOURCE[$_app]:=$PROJECT_DIR/src/web/$_app}"
    : "${WEB_APP_DEPLOY[$_app]:=$APP_ROOT/$SITE_NAME/web-$_app}"
    : "${WEB_APP_BASE_PATH[$_app]:=/$_app}"
    : "${WEB_APP_PROJECT_ID[$_app]:=$SITE_NAME-$_app}"
done

# ── 依赖检查 ─────────────────────────────────────────────────────
if [ "$DEPLOY_BACKEND" = true ]; then
    require_command mvn
    if [ -n "$REMOTE_HOST" ]; then
        require_command ssh
        require_command rsync
    else
        require_command supervisorctl
        require_command curl
    fi
fi
if [ "$DEPLOY_WEB" = true ]; then
    require_command node
    require_command npm
    if [ -n "$REMOTE_HOST" ]; then
        require_command rsync
    fi
fi
if [ "$DEPLOY_ANDROID" = true ]; then
    [ -d "$ANDROID_DIR" ] || fail "Android 项目目录不存在: $ANDROID_DIR"
    if [ ! -x "$ANDROID_DIR/gradlew" ]; then
        require_command gradle
    fi
fi
if [ "$DEPLOY_DB" = true ]; then
    require_command pg_dump
    require_command psql
    require_command ssh
    require_command rsync
fi

# ── 版本读取 ─────────────────────────────────────────────────────
# 各服务版本独立读取（多模块仓库里子模块版本可以不同），JAR 按各自版本命名
declare -A SERVICE_VERSIONS=()
if [ "$DEPLOY_BACKEND" = true ]; then
    for service in "${SELECTED_SERVICES[@]}"; do
        _v="$(read_backend_version "$(service_backend_dir "$service")/pom.xml" "$service")"
        [ -n "$_v" ] || fail "无法从 $service 的 pom.xml 读取版本号"
        SERVICE_VERSIONS["$service"]="$_v"
    done
fi

MOBILE_APP_VERSION="1.0.0"
MOBILE_ANDROID_ARTIFACTS=()
MOBILE_ANDROID_MODE=""
if [ "$DEPLOY_ANDROID" = true ] && [ -f "$ANDROID_DIR/app/build.gradle" ]; then
    _ver="$(grep -E 'versionName[[:space:]]+"[^"]+"' "$ANDROID_DIR/app/build.gradle" 2>/dev/null \
        | sed -E 's/.*versionName[[:space:]]+"([^"]+)".*/\1/' | head -1 || true)"
    [ -n "$_ver" ] && MOBILE_APP_VERSION="$_ver"
fi

# 后端部署后自动同步 nginx 站点配置（--target ssl 完整安装流程除外）
NEED_NGINX_SYNC=false
if [ "$DEPLOY_BACKEND" = true ] && [ "$DEPLOY_SSL" = false ]; then
    NEED_NGINX_SYNC=true
fi
NGINX_DEPLOY_EFFECTIVE="$DEPLOY_SSL"
[ "$NEED_NGINX_SYNC" = true ] && NGINX_DEPLOY_EFFECTIVE=true

# ── 部署前参数回显 ───────────────────────────────────────────────
DEPLOY_TARGETS=()
[ "$DEPLOY_BACKEND" = true ] && DEPLOY_TARGETS+=("backend")
[ "$DEPLOY_WEB" = true ]     && DEPLOY_TARGETS+=("web")
[ "$DEPLOY_SSL" = true ]     && DEPLOY_TARGETS+=("ssl")
[ "$DEPLOY_ANDROID" = true ] && DEPLOY_TARGETS+=("android")
[ "$DEPLOY_DB" = true ]      && DEPLOY_TARGETS+=("db")

log "======================================================"
log "本次部署目标   : ${DEPLOY_TARGETS[*]:-（无）}"
log "  目标环境       : ${DEPLOY_ENV:-dev}"
if [ "$DEPLOY_BACKEND" = true ] || [ "$DEPLOY_DB" = true ]; then
    log "  服务范围       : ${SELECTED_SERVICES[*]}"
fi
if [ "$DEPLOY_ANDROID" = true ]; then
    if [ -n "$DEPLOY_ENV" ]; then
        log "  Android 环境   : 仅 $DEPLOY_ENV"
    else
        log "  Android 环境   : 全部（dev test prod）"
    fi
fi
log "  部署主机       : ${REMOTE_HOST:-本机}"
log "======================================================"
log "脚本开始执行"
log "  项目根目录     : $PROJECT_DIR"
[ -n "$REMOTE_HOST" ] && log "  远程服务器     : $REMOTE_HOST"
log "  部署后端       : $DEPLOY_BACKEND"
if [ "$DEPLOY_BACKEND" = true ]; then
    for service in "${SELECTED_SERVICES[@]}"; do
        log "    $service 源码  : $(service_backend_dir "$service")"
        log "    $service 端口  : ${SERVICE_PORTS[$service]:-?}  健康检查: ${SERVICE_HEALTH_PATHS[$service]:-?}"
        log "    $service 版本  : ${SERVICE_VERSIONS[$service]:-?}"
    done
fi
log "  同步数据库     : $DEPLOY_DB"
if [ "$DEPLOY_DB" = true ]; then
    _dbs=()
    for service in "${SELECTED_SERVICES[@]}"; do _dbs+=("${SERVICE_DBS[$service]:-$service}"); done
    log "  同步库范围     : ${_dbs[*]}（停止服务 → 同步 → 恢复）"
fi
log "  部署 Web       : $DEPLOY_WEB"
if [ "$DEPLOY_WEB" = true ]; then
    for _app in ${WEB_APPS[@]+"${WEB_APPS[@]}"}; do
        log "    $_app 源码     : ${WEB_APP_SOURCE[$_app]}"
        log "    $_app 部署目录 : ${WEB_APP_DEPLOY[$_app]}"
    done
fi
log "  部署 Nginx     : $NGINX_DEPLOY_EFFECTIVE"
[ "$NEED_NGINX_SYNC" = true ] && log "  Nginx 方式     : 站点配置随后端部署自动同步"
[ "$DEPLOY_SSL" = true ] && log "  Nginx 环境     : $DEPLOY_ENV"
log "======================================================"

mkdir -p "$RUNTIME_DIR"

# ── supervisord 程序配置后缀（跟随目标主机的 [include] 模式）──────
if [ "$DEPLOY_BACKEND" = true ]; then
    SUPERVISOR_SUFFIX="$(detect_supervisor_suffix)"
    log "supervisor 程序配置写入后缀: .$SUPERVISOR_SUFFIX（来源: 目标主机 $SUPERVISOR_CONF 的 [include] files=，可用 SUPERVISOR_CONF_SUFFIX 强制指定）"
fi

# ── 部署前自检：Web 工程与 env 文件（只提示，不阻断）─────────────
if [ "$DEPLOY_WEB" = true ]; then
    for _app in ${WEB_APPS[@]+"${WEB_APPS[@]}"}; do
        [ -f "${WEB_APP_SOURCE[$_app]}/package.json" ] || fail "package.json 不存在: ${WEB_APP_SOURCE[$_app]}/package.json"
        _pkg_ver="$(node -p "require(process.argv[1]).version || ''" "${WEB_APP_SOURCE[$_app]}/package.json" 2>/dev/null || true)"
        [ -n "$_pkg_ver" ] || fail "无法从 ${WEB_APP_SOURCE[$_app]}/package.json 读取 version"
        WEB_APP_VERSION[$_app]="$_pkg_ver"
    done
fi
if [ "$DEPLOY_BACKEND" = true ]; then
    for service in "${SELECTED_SERVICES[@]}"; do
        _envf="$(resolve_env_file "$service")"
        [ -f "$_envf" ] || log "警告: $service 缺少 env 文件 ${_envf}（部署后服务将因缺配置启动失败，请先按 specs/deployment.md 准备）"
    done
fi

# ── 初始化部署目录（纯数据库同步时跳过，避免创建无关目录）────────
if [ "$DEPLOY_DB" = false ] || [ "$DEPLOY_BACKEND" = true ]; then
    _web_paths=()
    if [ "$DEPLOY_WEB" = true ]; then
        for _app in ${WEB_APPS[@]+"${WEB_APPS[@]}"}; do _web_paths+=("${WEB_APP_DEPLOY[$_app]}"); done
    fi
    if [ -n "$REMOTE_HOST" ]; then
        log "初始化远程目录: $APP_ROOT, $LOG_ROOT, $SUPERVISOR_CONF_DIR"
        remote_exec "mkdir -p $APP_ROOT $LOG_ROOT $SUPERVISOR_CONF_DIR /data/logs/nginx ${_web_paths[*]}"
        log "部署 apply-ssl.sh → $REMOTE_HOST:$APP_ROOT/$SITE_NAME/"
        remote_exec "mkdir -p $APP_ROOT/$SITE_NAME"
        rsync -az "$SCRIPT_DIR/apply-ssl.sh" "$REMOTE_HOST:$APP_ROOT/$SITE_NAME/apply-ssl.sh"
        remote_exec "chmod +x $APP_ROOT/$SITE_NAME/apply-ssl.sh"
    else
        log "初始化本地目录: $APP_ROOT, $LOG_ROOT, $SUPERVISOR_CONF_DIR"
        mkdir -p "$APP_ROOT" "$LOG_ROOT" "$SUPERVISOR_CONF_DIR" /data/logs/nginx ${_web_paths[@]+"${_web_paths[@]}"}
        log "部署 apply-ssl.sh 到 $APP_ROOT/$SITE_NAME/"
        mkdir -p "$APP_ROOT/$SITE_NAME"
        cp -f "$SCRIPT_DIR/apply-ssl.sh" "$APP_ROOT/$SITE_NAME/apply-ssl.sh"
        chmod +x "$APP_ROOT/$SITE_NAME/apply-ssl.sh"
    fi
fi

# ── Phase 计数 ───────────────────────────────────────────────────
PHASE_TOTAL=0
[ "$DEPLOY_BACKEND" = true ]  && PHASE_TOTAL=$((PHASE_TOTAL + 3))
[ "$DEPLOY_WEB" = true ]      && PHASE_TOTAL=$((PHASE_TOTAL + 1))
[ "$DEPLOY_SSL" = true ]      && PHASE_TOTAL=$((PHASE_TOTAL + 1))
[ "$NEED_NGINX_SYNC" = true ] && PHASE_TOTAL=$((PHASE_TOTAL + 1))
[ "$DEPLOY_ANDROID" = true ]  && PHASE_TOTAL=$((PHASE_TOTAL + 1))
[ "$DEPLOY_DB" = true ]       && PHASE_TOTAL=$((PHASE_TOTAL + 1))
PHASE_INDEX=1

# ── 仅数据库同步（不部署后端）：停止服务 → 同步 → 恢复 ───────────
if [ "$DEPLOY_DB" = true ] && [ "$DB_ONLY" = true ]; then
    log_step "========== Phase $PHASE_INDEX/$PHASE_TOTAL: 同步数据库 → $REMOTE_HOST =========="
    PHASE_INDEX=$((PHASE_INDEX + 1))
    stop_selected_services
    sync_databases
    start_selected_services
fi

# ── 后端部署 ─────────────────────────────────────────────────────
if [ "$DEPLOY_BACKEND" = true ]; then
    log_step "========== Phase $PHASE_INDEX/$PHASE_TOTAL: Maven 构建 =========="
    PHASE_INDEX=$((PHASE_INDEX + 1))
    MVN_LOG_FILE="$RUNTIME_DIR/deploy-maven-build-$(date '+%Y%m%d%H%M%S').log"
    log "Maven 构建日志: $MVN_LOG_FILE"
    for service in "${SELECTED_SERVICES[@]}"; do
        log "构建服务: $service"
        if ! mvn -f "$(service_backend_dir "$service")/pom.xml" clean package -DskipTests --batch-mode >>"$MVN_LOG_FILE" 2>&1; then
            fail_maven_build "$MVN_LOG_FILE"
        fi
    done
    log "Maven 构建完成"

    if [ "$DEPLOY_DB" = true ]; then
        log_step "========== Phase $PHASE_INDEX/$PHASE_TOTAL: 停止服务并同步数据库 → $REMOTE_HOST =========="
        PHASE_INDEX=$((PHASE_INDEX + 1))
        stop_selected_services
        sync_databases
    fi

    if [ -n "$REMOTE_HOST" ]; then
        log_step "========== Phase $PHASE_INDEX/$PHASE_TOTAL: 上传 JAR → $REMOTE_HOST =========="
        PHASE_INDEX=$((PHASE_INDEX + 1))
        for service in "${SELECTED_SERVICES[@]}"; do
            echo
            remote_deploy_service_jar "$service"
        done

        log_step "========== Phase $PHASE_INDEX/$PHASE_TOTAL: 远程重启 supervisor 服务 =========="
        PHASE_INDEX=$((PHASE_INDEX + 1))
        for service in "${SELECTED_SERVICES[@]}"; do
            echo
            remote_restart_service "$service"
            remote_wait_service_ready "$service"
        done
    else
        log_step "========== Phase $PHASE_INDEX/$PHASE_TOTAL: 部署 JAR → $APP_ROOT =========="
        PHASE_INDEX=$((PHASE_INDEX + 1))
        for service in "${SELECTED_SERVICES[@]}"; do
            echo
            deploy_service_jar "$service"
        done

        log_step "========== Phase $PHASE_INDEX/$PHASE_TOTAL: 刷新并重启 supervisor 服务 =========="
        PHASE_INDEX=$((PHASE_INDEX + 1))
        supervisorctl -c "$SUPERVISOR_CONF" reread
        supervisorctl -c "$SUPERVISOR_CONF" update
        for service in "${SELECTED_SERVICES[@]}"; do
            echo
            restart_service "$service"
            supervisorctl -c "$SUPERVISOR_CONF" status "$service"
            wait_service_ready "$service"
        done
    fi

    if [ "$NEED_NGINX_SYNC" = true ]; then
        log_step "========== Phase $PHASE_INDEX/$PHASE_TOTAL: 同步 nginx 站点配置 =========="
        PHASE_INDEX=$((PHASE_INDEX + 1))
        sync_nginx_conf
    fi
fi

# ── 前端部署 ─────────────────────────────────────────────────────
if [ "$DEPLOY_WEB" = true ]; then
    log_step "========== Phase $PHASE_INDEX/$PHASE_TOTAL: 构建并部署前端静态资源（${#WEB_APPS[@]} 个）=========="
    PHASE_INDEX=$((PHASE_INDEX + 1))
    runtime_env="${DEPLOY_ENV:-dev}"
    for _app in ${WEB_APPS[@]+"${WEB_APPS[@]}"}; do
        web_src="${WEB_APP_SOURCE[$_app]}"
        web_deploy="${WEB_APP_DEPLOY[$_app]}"
        web_base="${WEB_APP_BASE_PATH[$_app]}"
        web_ver="${WEB_APP_VERSION[$_app]}"
        WEB_LOG_FILE="$RUNTIME_DIR/deploy-web-build-${_app}-$(date '+%Y%m%d%H%M%S').log"

        # 路由前缀：Next.js 静态导出按 basePath 生成资源链接，必须与 nginx location 一致
        if [ -n "$web_base" ] && [ "$web_base" != "/" ]; then
            export NEXT_BASE_PATH="$web_base"
        else
            unset NEXT_BASE_PATH || true
        fi
        log "构建前端: $_app（$web_src，版本 $web_ver，basePath=${NEXT_BASE_PATH:-/}）"
        log "前端构建日志: $WEB_LOG_FILE"
        if [ -f "$web_src/package-lock.json" ]; then
            _npm_install=(npm ci --no-audit --no-fund)
        else
            _npm_install=(npm install --no-progress)
        fi
        if ! (cd "$web_src" && "${_npm_install[@]}" && npm run build) >"$WEB_LOG_FILE" 2>&1; then
            log "错误: 前端构建失败，日志最后 120 行:"
            tail -n 120 "$WEB_LOG_FILE" || true
            fail "前端构建失败，完整日志: $WEB_LOG_FILE"
        fi
        [ -d "$web_src/dist" ] || fail "未找到前端构建产物: $web_src/dist"

        if [ -n "$REMOTE_HOST" ]; then
            remote_deploy_web_app "$web_src" "$web_deploy"
        else
            mkdir -p "$web_deploy"
            rsync -a --delete "$web_src/dist/" "$web_deploy/"
            nginx -s reload 2>/dev/null || true
            log "前端已部署到: $web_deploy"
        fi

        # 按环境覆盖前端运行时配置：public/runtime-config.<env>.js → runtime-config.js
        _runtime_src="$web_src/public/runtime-config.$runtime_env.js"
        if [ -f "$_runtime_src" ]; then
            log "部署前端环境配置: $_app runtime-config.$runtime_env.js"
            if [ -n "$REMOTE_HOST" ]; then
                remote_exec "cp -f $web_deploy/runtime-config.$runtime_env.js $web_deploy/runtime-config.js"
            else
                cp -f "$web_deploy/runtime-config.$runtime_env.js" "$web_deploy/runtime-config.js"
            fi
        fi
    done
fi

# ── Android 构建 ─────────────────────────────────────────────────
if [ "$DEPLOY_ANDROID" = true ]; then
    log_step "========== Phase $PHASE_INDEX/$PHASE_TOTAL: 构建 Android 应用 =========="
    PHASE_INDEX=$((PHASE_INDEX + 1))
    build_android_app
fi

# ── SSL / Nginx 部署 ──────────────────────────────────────────────
if [ "$DEPLOY_SSL" = true ]; then
    log_step "========== Phase $PHASE_INDEX/$PHASE_TOTAL: 部署 SSL 证书和 Nginx 配置（$DEPLOY_ENV）=========="
    deploy_nginx_ssl
fi

# ── [STATUS] 机器可读输出 ─────────────────────────────────────────
log "部署完成"
if [ "$DEPLOY_DB" = true ] && [ "$DB_ONLY" = true ]; then
    echo "[STATUS] OK - 数据库已同步 → $REMOTE_HOST（${SELECTED_SERVICES[*]} 对应库）"
elif [ "$DEPLOY_ANDROID" = true ]; then
    echo "[STATUS] OK - Android 构建完成，产物见 mobile-apps/"
elif [ -n "$REMOTE_HOST" ]; then
    echo "[STATUS] OK - 已远程部署 → $REMOTE_HOST（${DEPLOY_TARGETS[*]}）"
elif [ "$DEPLOY_SSL" = true ] && [ "$DEPLOY_BACKEND" = false ] && [ "$DEPLOY_WEB" = false ]; then
    echo "[STATUS] OK - SSL/Nginx 已部署（环境: $DEPLOY_ENV）"
elif [ "$DEPLOY_BACKEND" = true ] && [ "$DEPLOY_WEB" = true ]; then
    echo "[STATUS] OK - 微服务已部署（${SELECTED_SERVICES[*]}），前端已部署"
elif [ "$DEPLOY_BACKEND" = true ]; then
    echo "[STATUS] OK - 微服务已部署：${SELECTED_SERVICES[*]}"
elif [ "$DEPLOY_WEB" = true ]; then
    echo "[STATUS] OK - 前端已部署"
fi

# ── 部署摘要：访问地址 + 产物位置 ─────────────────────────────────
detect_public_ip() {
    local ip="" source
    for source in "https://ifconfig.me" "https://api.ipify.org" "https://ipinfo.io/ip"; do
        ip="$(curl -s -m 3 "$source" 2>/dev/null | tr -d '[:space:]')"
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# 访问地址用的主机：远程部署时取 REMOTE_HOST 的 host 部分（root@ 是登录用户，
# 留在 URL 里会变成 userinfo，粘进浏览器/curl 就是错的）；本机部署用 PUBLIC_IP 或公网探测
SUMMARY_HOST="${REMOTE_HOST:+${REMOTE_HOST#*@}}"
[ -n "$SUMMARY_HOST" ] || SUMMARY_HOST="${PUBLIC_IP:-}"
if [ -z "$SUMMARY_HOST" ]; then
    SUMMARY_HOST="$(detect_public_ip || true)"
fi
[ -n "$SUMMARY_HOST" ] || SUMMARY_HOST="127.0.0.1"
# 产物位置用 "host:/路径" 形式，带登录用户更方便直接 scp/登录核对
SUMMARY_HOST_PREFIX=""
[ -n "$REMOTE_HOST" ] && SUMMARY_HOST_PREFIX="$REMOTE_HOST:"

# 占位符值本身以 / 开头，端口后不再补斜杠
API_URL_DEV="http://$SUMMARY_HOST:$NGINX_PORT<API_PATH_PREFIX>/health"
API_URL_TEST="https://<TEST_DOMAIN>:$NGINX_PORT<API_PATH_PREFIX>/health"
API_URL_PROD="https://<PROD_DOMAIN>:$NGINX_PORT<API_PATH_PREFIX>/health"

echo
echo "══════════════════════ 部署摘要 ══════════════════════"
echo "  ▍访问地址（本次环境: ${DEPLOY_ENV:-dev}）"
echo "    API     dev  : $API_URL_DEV"
if [ "$DEPLOY_WEB" = true ]; then
    for _app in ${WEB_APPS[@]+"${WEB_APPS[@]}"}; do
        echo "    Web     dev  : http://$SUMMARY_HOST:$NGINX_PORT${WEB_APP_BASE_PATH[$_app]}/"
    done
fi
echo "    API     test : $API_URL_TEST"
echo "    API     prod : $API_URL_PROD"
echo
echo "  ▍应用位置"
if [ "$DEPLOY_BACKEND" = true ]; then
    for service in "${SELECTED_SERVICES[@]}"; do
        echo "    $service JAR   : ${SUMMARY_HOST_PREFIX}${APP_ROOT}/${service}/${service}-${SERVICE_VERSIONS[$service]}.jar"
    done
    echo "    应用日志       : ${SUMMARY_HOST_PREFIX}${LOG_ROOT}"
    echo "    环境变量       : ${SUMMARY_HOST_PREFIX}${APP_ROOT}/${SELECTED_SERVICES[0]}/.env"
fi
if [ "$DEPLOY_WEB" = true ]; then
    for _app in ${WEB_APPS[@]+"${WEB_APPS[@]}"}; do
        echo "    $_app 静态资源 : ${SUMMARY_HOST_PREFIX}${WEB_APP_DEPLOY[$_app]}"
    done
fi
if [ "$NGINX_DEPLOY_EFFECTIVE" = true ]; then
    echo "    Nginx 站点配置 : ${SUMMARY_HOST_PREFIX}${NGINX_CONF_DIR}/$SITE_NAME.conf"
fi
if [ "$DEPLOY_DB" = true ]; then
    echo "    数据库同步     : 本机 dev → $REMOTE_HOST（dump 缓存: $RUNTIME_DIR/db-sync-*/）"
fi
if [ "$DEPLOY_ANDROID" = true ] && [ "${#MOBILE_ANDROID_ARTIFACTS[@]}" -gt 0 ]; then
    echo
    echo "  ▍Android 产物（mobile-apps/）"
    for artifact in "${MOBILE_ANDROID_ARTIFACTS[@]}"; do
        echo "    Android    : $artifact"
    done
    echo "    构建模式   : $MOBILE_ANDROID_MODE"
fi
echo "══════════════════════════════════════════════════════"
