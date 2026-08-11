#!/bin/bash
# <SERVICE_NAME> 部署脚本
# 支持本地和远程（SSH）部署，后端 JAR 由 supervisord 管理，通过 nginx 反向代理对外访问。
# 规范参考：specs/deployment.md（本工程）、specs/deployment-common.md（跨项目通用）
set -euo pipefail

# ==============================================================================
# 服务配置（由 /new-java-project skill 初始化时填入）
# 端口变更需更新 specs/deployment-common.md 的端口分配总表
# ==============================================================================
APP_PORT=<APP_PORT>        # Spring Boot 内部监听端口（只绑 127.0.0.1，不对外暴露）
NGINX_PORT=<NGINX_PORT>    # nginx 对外监听端口
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
Usage:
  bash scripts/deploy.sh [OPTIONS]

Options:
  -t, --target all|backend|web|ssl
                  部署目标。默认: all
  -e, --env dev|test|prod
                  目标环境（影响 nginx 配置、SSL 证书和 env 文件选择）。默认: dev
  -r, --remote USER@HOST
                  部署到远程服务器（SSH 密钥认证）。本地构建，rsync 上传，远程重启。
                  示例: root@192.168.1.100
      --all       同 --target all
      --backend   同 --target backend
      --web       同 --target web
      --ssl       同 --target ssl
  -y, --yes       跳过二次确认
  -h, --help      显示本帮助

目标说明:
  backend   Maven 构建 JAR → supervisord 管理 → 同步 nginx 站点配置
  web       构建前端静态资源（npm）并部署
  ssl       安装 nginx + SSL 证书配置（需先用 scripts/apply-ssl.sh 申请证书；仅支持 test|prod）
  all       backend + web（依次执行），ssl 须单独 --target ssl 触发

环境说明:
  dev   无域名，HTTP，IP+端口访问（deploy-conf/nginx/vhosts/<SERVICE_NAME>.dev.conf）
  test  独立机器，测试域名 + HTTPS（需先申请证书）
  prod  独立机器，生产域名 + HTTPS（需先申请证书）

示例:
  bash scripts/deploy.sh
  bash scripts/deploy.sh --target backend
  bash scripts/deploy.sh --target backend --env test --remote root@192.168.1.100
  bash scripts/deploy.sh --target ssl --env test --remote root@192.168.1.100
  bash scripts/deploy.sh --target ssl --env prod --remote root@192.168.1.100
EOF
}

require_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || fail "缺少必要命令: $cmd"
}

# ── 健康检查 ──────────────────────────────────────────────────────

wait_service_ready() {
    local timeout="${SERVICE_READY_TIMEOUT:-420}"
    local url="http://127.0.0.1:${APP_PORT}/api/<SERVICE_NAME>/health"
    local started_at elapsed http_code

    started_at="$(date +%s)"
    log "等待服务就绪: $url，最长 ${timeout}s，每 5s 检测一次"
    while true; do
        http_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || echo "000")"
        elapsed=$(( $(date +%s) - started_at ))
        if [ "$http_code" = "200" ]; then
            log "服务已就绪（耗时 ${elapsed}s，HTTP $http_code）"
            return 0
        fi
        if [ "$elapsed" -ge "$timeout" ]; then
            supervisorctl -c "$SUPERVISOR_CONF" status "<SERVICE_NAME>" || true
            tail -n 120 "$LOG_DIR/supervisord.log" || true
            fail "服务启动超时，健康检查未通过: $url（最后 HTTP $http_code）"
        fi
        log "检测中: 尚未就绪（已等待 ${elapsed}s / ${timeout}s，HTTP $http_code）"
        sleep 5
    done
}

remote_wait_service_ready() {
    local timeout="${SERVICE_READY_TIMEOUT:-420}"
    local health_path="/api/<SERVICE_NAME>/health"
    local started_at elapsed http_code

    started_at="$(date +%s)"
    log "等待远程服务就绪: ssh $REMOTE_HOST → http://127.0.0.1:${APP_PORT}$health_path，最长 ${timeout}s"
    while true; do
        http_code="$(remote_exec "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:${APP_PORT}$health_path" 2>/dev/null || echo "000")"
        elapsed=$(( $(date +%s) - started_at ))
        if [ "$http_code" = "200" ]; then
            log "远程服务已就绪（耗时 ${elapsed}s，HTTP $http_code）"
            return 0
        fi
        if [ "$elapsed" -ge "$timeout" ]; then
            remote_exec "supervisorctl -c $SUPERVISOR_CONF status <SERVICE_NAME>" || true
            fail "远程服务启动超时: $REMOTE_HOST http://127.0.0.1:${APP_PORT}$health_path（最后 HTTP $http_code）"
        fi
        log "检测中: 远程服务尚未就绪（已等待 ${elapsed}s / ${timeout}s，HTTP $http_code）"
        sleep 5
    done
}

# ── 版本 / JAR ──────────────────────────────────────────────────

read_backend_version() {
    local pom="$1"
    awk '
        /<artifactId><SERVICE_NAME><\/artifactId>/ { found=1; next }
        found && /<version>/ {
            gsub(/.*<version>|<\/version>.*/, "", $0)
            print $0
            exit
        }
    ' "$pom"
}

get_jar_path() {
    find "$BACKEND_DIR/target" -maxdepth 1 -type f -name "<SERVICE_NAME>-*.jar" \
        ! -name "*original*" ! -name "*sources*" ! -name "*javadoc*" | head -1
}

# ── supervisord 配置（inline 生成，不从 deploy-conf/supervisor/ 复制）──

write_supervisor_conf() {
    local app_dir="$APP_DIR"
    local log_dir="$LOG_DIR"
    local conf_file="$SUPERVISOR_CONF_DIR/<SERVICE_NAME>.conf"

    mkdir -p "$log_dir" "$SUPERVISOR_CONF_DIR"
    cat > "$conf_file" <<EOF
[program:<SERVICE_NAME>]
command=/bin/bash -c "[ -f $app_dir/.env ] && { set -a; . $app_dir/.env; set +a; }; exec \${JAVA_EXEC:-/usr/bin/java} -jar $app_dir/<SERVICE_NAME>.jar"
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

# ── env 文件：按环境选择 .env / .env.test / .env.prod ────────────

resolve_env_file() {
    local env_name="${DEPLOY_ENV:-dev}"
    if [ "$env_name" != "dev" ] && [ -f "$BACKEND_DIR/.env.$env_name" ]; then
        echo "$BACKEND_DIR/.env.$env_name"
    else
        echo "$BACKEND_DIR/.env"
    fi
}

# ── 本地部署 ─────────────────────────────────────────────────────

deploy_service_jar() {
    local jar_file
    jar_file="$(get_jar_path)"
    [ -n "$jar_file" ] && [ -f "$jar_file" ] || fail "未找到 <SERVICE_NAME> JAR（target/ 下无匹配文件）"
    local target_jar="$APP_DIR/<SERVICE_NAME>-$BACKEND_VERSION.jar"

    mkdir -p "$APP_DIR"
    cp -f "$jar_file" "$target_jar.tmp"
    mv -f "$target_jar.tmp" "$target_jar"
    ln -sfn "<SERVICE_NAME>-$BACKEND_VERSION.jar" "$APP_DIR/<SERVICE_NAME>.jar"

    local env_file
    env_file="$(resolve_env_file)"
    if [ -f "$env_file" ]; then
        cp -f "$env_file" "$APP_DIR/.env"
        log "已部署 .env（来源: $env_file）"
    else
        log "警告: 未找到 env 文件: $env_file"
    fi

    log "写入 supervisor 配置: $SUPERVISOR_CONF_DIR/<SERVICE_NAME>.conf"
    write_supervisor_conf
    log "已部署 JAR: $target_jar"
}

restart_service() {
    log "重启 supervisor 服务: <SERVICE_NAME>"
    if ! supervisorctl -c "$SUPERVISOR_CONF" restart "<SERVICE_NAME>"; then
        supervisorctl -c "$SUPERVISOR_CONF" start "<SERVICE_NAME>"
    fi
}

# ── 远程部署 ─────────────────────────────────────────────────────

remote_exec() {
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$REMOTE_HOST" "$@"
}

remote_deploy_service_jar() {
    local jar_file
    jar_file="$(get_jar_path)"
    [ -n "$jar_file" ] && [ -f "$jar_file" ] || fail "未找到 <SERVICE_NAME> JAR（target/ 下无匹配文件）"
    local target_jar="$APP_DIR/<SERVICE_NAME>-$BACKEND_VERSION.jar"

    log "上传 JAR 到 $REMOTE_HOST:$target_jar"
    remote_exec "mkdir -p $APP_DIR"
    rsync -az --progress "$jar_file" "$REMOTE_HOST:$target_jar.tmp"
    remote_exec "mv -f $target_jar.tmp $target_jar && ln -sfn <SERVICE_NAME>-$BACKEND_VERSION.jar $APP_DIR/<SERVICE_NAME>.jar"

    local env_file
    env_file="$(resolve_env_file)"
    if [ -f "$env_file" ]; then
        rsync -az "$env_file" "$REMOTE_HOST:$APP_DIR/.env"
        log "已同步 .env（来源: $env_file）"
    else
        log "警告: 未找到 env 文件: $env_file"
    fi

    local app_dir="$APP_DIR"
    local log_dir="$LOG_DIR"
    local conf_file="$SUPERVISOR_CONF_DIR/<SERVICE_NAME>.conf"
    log "写入远程 supervisor 配置: $REMOTE_HOST:$conf_file"
    remote_exec "mkdir -p $log_dir $SUPERVISOR_CONF_DIR"
    remote_exec "cat > $conf_file" <<EOF
[program:<SERVICE_NAME>]
command=/bin/bash -c "[ -f $app_dir/.env ] && { set -a; . $app_dir/.env; set +a; }; exec \${JAVA_EXEC:-/usr/bin/java} -jar $app_dir/<SERVICE_NAME>.jar"
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
    log "已上传 JAR: $REMOTE_HOST:$target_jar"
}

remote_restart_service() {
    log "远程重启 supervisor 服务: <SERVICE_NAME>"
    remote_exec "supervisorctl -c $SUPERVISOR_CONF reread && supervisorctl -c $SUPERVISOR_CONF update"
    if ! remote_exec "supervisorctl -c $SUPERVISOR_CONF restart <SERVICE_NAME>"; then
        remote_exec "supervisorctl -c $SUPERVISOR_CONF start <SERVICE_NAME>"
    fi
}

# ── SSL / Nginx ───────────────────────────────────────────────────

cert_domain_for_env() {
    case "$1" in
        test) echo "<TEST_DOMAIN>" ;;
        prod) echo "<PROD_DOMAIN>" ;;
        *) echo "" ;;
    esac
}

# --target ssl：安装 nginx（apt）+ 主配置 + 站点配置（按证书存在与否选 HTTPS/HTTP）
deploy_nginx_ssl() {
    local env="$DEPLOY_ENV"
    local nginx_main_conf="$DEPLOY_CONF_DIR/nginx/nginx.conf"
    local remote_site_conf="/etc/nginx/conf.d/<SERVICE_NAME>.conf"
    local remote_cert_dir="/etc/nginx/ssl"
    local has_cert=false
    local nginx_conf cert_domain
    cert_domain="$(cert_domain_for_env "$env")"

    [ -f "$nginx_main_conf" ] || fail "nginx 主配置不存在: $nginx_main_conf"

    if [ -n "$cert_domain" ]; then
        if [ -n "$REMOTE_HOST" ]; then
            if remote_exec "test -f $remote_cert_dir/$cert_domain.pem && test -f $remote_cert_dir/$cert_domain.key" 2>/dev/null; then
                has_cert=true
            fi
        else
            if [ -f "$remote_cert_dir/$cert_domain.pem" ] && [ -f "$remote_cert_dir/$cert_domain.key" ]; then
                has_cert=true
            fi
        fi
    fi

    if [ "$has_cert" = true ]; then
        nginx_conf="$DEPLOY_CONF_DIR/nginx/vhosts/<SERVICE_NAME>.$env.conf"
        [ -f "$nginx_conf" ] || fail "nginx 站点配置不存在: $nginx_conf"
    else
        log "警告: 证书未找到（$remote_cert_dir），降级使用 dev 配置（HTTP）"
        nginx_conf="$DEPLOY_CONF_DIR/nginx/vhosts/<SERVICE_NAME>.dev.conf"
        [ -f "$nginx_conf" ] || fail "nginx dev 配置不存在: $nginx_conf"
    fi

    if [ -n "$REMOTE_HOST" ]; then
        log "安装 nginx（apt）: $REMOTE_HOST"
        remote_exec "apt-get update -qq && apt-get install -y -qq nginx >/dev/null 2>&1" || fail "远程安装 nginx 失败"
        log "上传 nginx.conf 主配置到 $REMOTE_HOST:/etc/nginx/nginx.conf"
        rsync -az "$nginx_main_conf" "$REMOTE_HOST:/etc/nginx/nginx.conf"
        log "上传站点配置到 $REMOTE_HOST:$remote_site_conf"
        remote_exec "mkdir -p /etc/nginx/conf.d"
        rsync -az "$nginx_conf" "$REMOTE_HOST:$remote_site_conf"
        remote_exec "rm -f /etc/nginx/sites-enabled/default"
        log "验证并重载 nginx"
        remote_exec "nginx -t" || fail "远程 nginx 配置检测失败"
        remote_exec "systemctl enable nginx && systemctl reload nginx"
    else
        log "安装 nginx（apt）"
        apt-get update -qq && apt-get install -y -qq nginx >/dev/null 2>&1 || fail "安装 nginx 失败"
        log "部署 nginx.conf 主配置到 /etc/nginx/nginx.conf"
        cp -f "$nginx_main_conf" /etc/nginx/nginx.conf
        log "部署站点配置到 $remote_site_conf"
        mkdir -p /etc/nginx/conf.d
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
    local site_conf="/etc/nginx/conf.d/<SERVICE_NAME>.conf"
    local cert_dir="/etc/nginx/ssl"
    local has_cert=false
    local cert_domain
    cert_domain="$(cert_domain_for_env "$env")"

    if [ -n "$REMOTE_HOST" ]; then
        if ! remote_exec "command -v nginx >/dev/null 2>&1"; then
            log "目标主机未安装 nginx，跳过站点配置同步"
            return 0
        fi
        if [ -n "$cert_domain" ] && remote_exec "test -f $cert_dir/$cert_domain.pem && test -f $cert_dir/$cert_domain.key" 2>/dev/null; then
            has_cert=true
        fi
    else
        if ! command -v nginx >/dev/null 2>&1; then
            log "本机未安装 nginx，跳过站点配置同步"
            return 0
        fi
        if [ -n "$cert_domain" ] && [ -f "$cert_dir/$cert_domain.pem" ] && [ -f "$cert_dir/$cert_domain.key" ]; then
            has_cert=true
        fi
    fi

    local nginx_conf
    if [ "$has_cert" = true ]; then
        nginx_conf="$DEPLOY_CONF_DIR/nginx/vhosts/<SERVICE_NAME>.$env.conf"
        [ -f "$nginx_conf" ] || fail "nginx 站点配置不存在: $nginx_conf"
    else
        nginx_conf="$DEPLOY_CONF_DIR/nginx/vhosts/<SERVICE_NAME>.dev.conf"
        [ -f "$nginx_conf" ] || fail "nginx dev 配置不存在: $nginx_conf"
    fi
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

# ── 参数解析 ─────────────────────────────────────────────────────

set_deploy_target() {
    case "$1" in
        all)
            DEPLOY_BACKEND=true
            DEPLOY_WEB=true
            ;;
        backend)
            DEPLOY_BACKEND=true
            DEPLOY_WEB=false
            ;;
        web)
            DEPLOY_BACKEND=false
            DEPLOY_WEB=true
            ;;
        ssl|nginx)
            DEPLOY_BACKEND=false
            DEPLOY_WEB=false
            DEPLOY_SSL=true
            ;;
        *)
            fail "未知部署目标: $1；可选值: all, backend, web, ssl"
            ;;
    esac
}

parse_deploy_args() {
    local target_set=false

    DEPLOY_BACKEND=true
    DEPLOY_WEB=true
    DEPLOY_SSL=false
    AUTO_CONFIRM=false

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -t|--target)
                [ "$#" -ge 2 ] || fail "$1 缺少参数"
                set_deploy_target "$2"
                target_set=true
                shift 2
                ;;
            --all)         set_deploy_target "all";     target_set=true; shift ;;
            --backend)     set_deploy_target "backend"; target_set=true; shift ;;
            --web)         set_deploy_target "web";     target_set=true; shift ;;
            --ssl|--nginx) set_deploy_target "ssl";     target_set=true; shift ;;
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

    if [ "$DEPLOY_SSL" = true ] && [ -z "$DEPLOY_ENV" ]; then
        if [ "$DEPLOY_BACKEND" = false ] && [ "$DEPLOY_WEB" = false ]; then
            fail "--target ssl 需要指定 --env test|prod"
        fi
        log "未指定 --env，跳过 SSL/Nginx 部署"
        DEPLOY_SSL=false
    fi
    if [ "$DEPLOY_SSL" = true ] && [ "${DEPLOY_ENV:-}" = "dev" ]; then
        fail "--target ssl 仅支持 --env test|prod（dev 为 HTTP 明文环境）"
    fi
    if [ "$DEPLOY_BACKEND" = false ] && [ "$DEPLOY_WEB" = false ] && [ "$DEPLOY_SSL" = false ]; then
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
BACKEND_DIR="$PROJECT_DIR/src/backend/<SERVICE_NAME>"
WEB_DIR="$PROJECT_DIR/src/web"
DEPLOY_CONF_DIR="$PROJECT_DIR/deploy-conf"
APP_DIR="/opt/soft/apps/<SERVICE_NAME>"
LOG_DIR="/data/logs/apps/<SERVICE_NAME>"
WEB_DEPLOY_PATH="${WEB_DEPLOY_PATH:-$APP_DIR/web}"
RUNTIME_DIR="$PROJECT_DIR/runtime"
SUPERVISOR_CONF="${SUPERVISOR_CONF:-/etc/supervisor/supervisord.conf}"
SUPERVISOR_CONF_DIR="/etc/supervisor/conf.d"

parse_deploy_args "$@"

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
    [ -f "$WEB_DIR/package.json" ] || fail "package.json 不存在: $WEB_DIR/package.json"
fi

# ── 版本读取 ─────────────────────────────────────────────────────
BACKEND_VERSION="-"
if [ "$DEPLOY_BACKEND" = true ]; then
    BACKEND_VERSION="$(read_backend_version "$BACKEND_DIR/pom.xml")"
    [ -n "$BACKEND_VERSION" ] || fail "无法从 pom.xml 读取 <SERVICE_NAME> 版本"
fi

# 后端部署后自动同步 nginx 站点配置（--target ssl 完整安装流程除外）
NEED_NGINX_SYNC=false
if [ "$DEPLOY_BACKEND" = true ] && [ "$DEPLOY_SSL" = false ]; then
    NEED_NGINX_SYNC=true
fi

log "======================================================"
DEPLOY_TARGETS=()
[ "$DEPLOY_BACKEND" = true ] && DEPLOY_TARGETS+=("backend")
[ "$DEPLOY_WEB" = true ]     && DEPLOY_TARGETS+=("web")
[ "$DEPLOY_SSL" = true ]     && DEPLOY_TARGETS+=("ssl")
log "本次部署目标   : ${DEPLOY_TARGETS[*]:-（无）}"
log "  目标环境       : ${DEPLOY_ENV:-dev}"
log "  部署位置       : ${REMOTE_HOST:-本机}"
log "======================================================"
log "  项目根目录     : $PROJECT_DIR"
[ -n "$REMOTE_HOST" ] && log "  远程服务器     : $REMOTE_HOST"
if [ "$DEPLOY_BACKEND" = true ]; then
    log "  后端目录       : $BACKEND_DIR"
    log "  后端版本       : $BACKEND_VERSION"
fi
[ "$DEPLOY_WEB" = true ] && log "  前端目录       : $WEB_DIR"
log "======================================================"

mkdir -p "$RUNTIME_DIR"

# ── 初始化部署目录 ────────────────────────────────────────────────
if [ -n "$REMOTE_HOST" ]; then
    log "初始化远程目录: $APP_DIR, $LOG_DIR, $SUPERVISOR_CONF_DIR"
    remote_exec "mkdir -p $APP_DIR $LOG_DIR $WEB_DEPLOY_PATH $SUPERVISOR_CONF_DIR /data/logs/nginx"
    log "部署 apply-ssl.sh 到 $REMOTE_HOST:$APP_DIR/"
    rsync -az "$SCRIPT_DIR/apply-ssl.sh" "$REMOTE_HOST:$APP_DIR/apply-ssl.sh"
    remote_exec "chmod +x $APP_DIR/apply-ssl.sh"
else
    log "初始化本地目录: $APP_DIR, $LOG_DIR, $SUPERVISOR_CONF_DIR"
    mkdir -p "$APP_DIR" "$LOG_DIR" "$WEB_DEPLOY_PATH" "$SUPERVISOR_CONF_DIR" /data/logs/nginx
    log "部署 apply-ssl.sh 到 $APP_DIR/"
    cp -f "$SCRIPT_DIR/apply-ssl.sh" "$APP_DIR/apply-ssl.sh"
    chmod +x "$APP_DIR/apply-ssl.sh"
fi

# ── Phase 计数 ───────────────────────────────────────────────────
PHASE_TOTAL=0
[ "$DEPLOY_BACKEND" = true ]    && PHASE_TOTAL=$((PHASE_TOTAL + 3))
[ "$DEPLOY_WEB" = true ]        && PHASE_TOTAL=$((PHASE_TOTAL + 1))
[ "$DEPLOY_SSL" = true ]        && PHASE_TOTAL=$((PHASE_TOTAL + 1))
[ "$NEED_NGINX_SYNC" = true ]   && PHASE_TOTAL=$((PHASE_TOTAL + 1))
PHASE_INDEX=1

# ── 后端部署 ─────────────────────────────────────────────────────
if [ "$DEPLOY_BACKEND" = true ]; then
    log_step "========== Phase $PHASE_INDEX/$PHASE_TOTAL: Maven 构建 =========="
    PHASE_INDEX=$((PHASE_INDEX + 1))
    MVN_LOG_FILE="$RUNTIME_DIR/deploy-maven-$(date '+%Y%m%d%H%M%S').log"
    log "Maven 构建日志: $MVN_LOG_FILE"
    if ! mvn -f "$BACKEND_DIR/pom.xml" clean package -DskipTests --batch-mode >"$MVN_LOG_FILE" 2>&1; then
        fail_maven_build "$MVN_LOG_FILE"
    fi
    log "Maven 构建完成"

    if [ -n "$REMOTE_HOST" ]; then
        log_step "========== Phase $PHASE_INDEX/$PHASE_TOTAL: 上传 JAR 到 $REMOTE_HOST =========="
        PHASE_INDEX=$((PHASE_INDEX + 1))
        remote_deploy_service_jar

        log_step "========== Phase $PHASE_INDEX/$PHASE_TOTAL: 远程重启 supervisor 服务 =========="
        PHASE_INDEX=$((PHASE_INDEX + 1))
        remote_restart_service
        remote_wait_service_ready
    else
        log_step "========== Phase $PHASE_INDEX/$PHASE_TOTAL: 部署 JAR 到 $APP_DIR =========="
        PHASE_INDEX=$((PHASE_INDEX + 1))
        deploy_service_jar

        log_step "========== Phase $PHASE_INDEX/$PHASE_TOTAL: 刷新并重启 supervisor 服务 =========="
        PHASE_INDEX=$((PHASE_INDEX + 1))
        supervisorctl -c "$SUPERVISOR_CONF" reread
        supervisorctl -c "$SUPERVISOR_CONF" update
        restart_service
        supervisorctl -c "$SUPERVISOR_CONF" status "<SERVICE_NAME>"
        wait_service_ready
    fi

    if [ "$NEED_NGINX_SYNC" = true ]; then
        log_step "========== Phase $PHASE_INDEX/$PHASE_TOTAL: 同步 nginx 站点配置 =========="
        PHASE_INDEX=$((PHASE_INDEX + 1))
        sync_nginx_conf
    fi
fi

# ── 前端部署 ─────────────────────────────────────────────────────
if [ "$DEPLOY_WEB" = true ]; then
    log_step "========== Phase $PHASE_INDEX/$PHASE_TOTAL: 构建并部署前端静态资源 =========="
    PHASE_INDEX=$((PHASE_INDEX + 1))
    log "构建前端: $WEB_DIR"
    (cd "$WEB_DIR" && npm ci --no-audit --no-fund && npm run build)
    [ -d "$WEB_DIR/dist" ] || fail "未找到前端构建产物: $WEB_DIR/dist"
    if [ -n "$REMOTE_HOST" ]; then
        rsync -az --delete "$WEB_DIR/dist/" "$REMOTE_HOST:$WEB_DEPLOY_PATH/"
        remote_exec "nginx -s reload" || true
    else
        rsync -a --delete "$WEB_DIR/dist/" "$WEB_DEPLOY_PATH/"
        nginx -s reload 2>/dev/null || true
    fi
    log "前端已部署到: $WEB_DEPLOY_PATH"
fi

# ── SSL / Nginx 部署 ──────────────────────────────────────────────
if [ "$DEPLOY_SSL" = true ]; then
    log_step "========== Phase $PHASE_INDEX/$PHASE_TOTAL: 部署 SSL 证书和 Nginx 配置（${DEPLOY_ENV}）=========="
    deploy_nginx_ssl
fi

# ── [STATUS] 机器可读输出 ─────────────────────────────────────────
log "部署完成"
if [ -n "$REMOTE_HOST" ]; then
    echo "[STATUS] OK - 已远程部署到 $REMOTE_HOST（${DEPLOY_TARGETS[*]}）"
elif [ "$DEPLOY_SSL" = true ] && [ "$DEPLOY_BACKEND" = false ] && [ "$DEPLOY_WEB" = false ]; then
    echo "[STATUS] OK - SSL/Nginx 已部署（环境: ${DEPLOY_ENV}）"
elif [ "$DEPLOY_BACKEND" = true ] && [ "$DEPLOY_WEB" = true ]; then
    echo "[STATUS] OK - 已部署：后端 + 前端"
elif [ "$DEPLOY_BACKEND" = true ]; then
    echo "[STATUS] OK - 已部署：后端"
elif [ "$DEPLOY_WEB" = true ]; then
    echo "[STATUS] OK - 已部署：前端至 $WEB_DEPLOY_PATH"
fi

# ── 部署摘要 ─────────────────────────────────────────────────────
detect_public_ip() {
    local ip=""
    local source
    for source in "https://ifconfig.me" "https://api.ipify.org" "https://ipinfo.io/ip"; do
        ip="$(curl -s -m 3 "$source" 2>/dev/null | tr -d '[:space:]')"
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

SUMMARY_HOST="${REMOTE_HOST:-}"
[ -z "$SUMMARY_HOST" ] && SUMMARY_HOST="$(detect_public_ip || true)"
[ -z "$SUMMARY_HOST" ] && SUMMARY_HOST="<host>"
SUMMARY_HOST_PREFIX=""
[ -n "$REMOTE_HOST" ] && SUMMARY_HOST_PREFIX="$REMOTE_HOST:"

echo
echo "══════════════════════ 部署摘要 ══════════════════════"
echo "  ▍访问地址（本次环境: ${DEPLOY_ENV:-dev}）"
echo "    dev   http://$SUMMARY_HOST:${NGINX_PORT}/api/<SERVICE_NAME>/health"
echo "    test  https://<TEST_DOMAIN>:${NGINX_PORT}/api/<SERVICE_NAME>/health"
echo "    prod  https://<PROD_DOMAIN>:${NGINX_PORT}/api/<SERVICE_NAME>/health"
echo
echo "  ▍应用位置"
if [ "$DEPLOY_BACKEND" = true ]; then
    echo "    JAR          : ${SUMMARY_HOST_PREFIX}${APP_DIR}/<SERVICE_NAME>-${BACKEND_VERSION}.jar"
    echo "    日志目录      : ${SUMMARY_HOST_PREFIX}${LOG_DIR}"
fi
if [ "$DEPLOY_WEB" = true ]; then
    echo "    前端静态资源  : ${SUMMARY_HOST_PREFIX}${WEB_DEPLOY_PATH}"
fi
if [ "$DEPLOY_SSL" = true ]; then
    echo "    Nginx 站点配置: ${SUMMARY_HOST_PREFIX}/etc/nginx/conf.d/<SERVICE_NAME>.conf"
fi
echo "══════════════════════════════════════════════════════"
