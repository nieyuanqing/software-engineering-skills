#!/usr/bin/env bash
# <SERVICE_NAME> —— 本地构建/部署脚本
#
# 用 --target 区分构建/部署目标（不加 --target 时默认 backend）：
#   - backend（默认）：处理后端服务——用 supervisord 管理 Java 进程，通过 nginx 反向代理对外访问
#   - web：构建 src/web 静态资源并部署，通过共享 nginx 的指定 location 对外提供
#   - all：backend + web 依次执行，nginx 只 reload 一次
#
# 用 --env 区分部署环境（不加 --env 时默认 dev）：
#   - dev（默认）：无域名，HTTP，用 IP+端口直接访问
#   - test：独立机器，绑定测试域名 + HTTPS，证书需先用 scripts/apply-ssl.sh test 申请
#   - prod：独立机器，绑定生产域名 + HTTPS，证书需先用 scripts/apply-ssl.sh prod 申请
#
# 具体规范见：
#   - specs/deployment.md         本工程专属的部署细节
#   - specs/deployment-common.md  跨项目通用的主机操作规范（或引用 software-engineering-skills 仓库）
#
# 用法（backend 目标，默认，需要 sudo）：
#   sudo scripts/deploy.sh                     构建 + 部署 + 启动，安装 nginx（--env=dev）
#   sudo scripts/deploy.sh --env=test           同上，装 test 环境域名+HTTPS 的 nginx 配置
#   sudo scripts/deploy.sh --env=prod           同上，装 prod 环境域名+HTTPS 的 nginx 配置
#   sudo scripts/deploy.sh --no-nginx           只处理 supervisord 管理的服务本身，不改动共享 nginx
#   sudo scripts/deploy.sh --stop               只停止服务，不删除任何部署文件
#   sudo scripts/deploy.sh --remove             完全移除（停止 + 删 supervisord 配置 + 删 nginx vhost）
#   sudo scripts/deploy.sh --remove --yes       同上，跳过二次确认
#
# 用法（web 目标，需要 sudo）：
#   sudo scripts/deploy.sh --target=web              构建 + 部署静态资源，同时安装/重载 nginx（--env=dev）
#   sudo scripts/deploy.sh --target=web --no-nginx    只更新静态资源目录，不动 nginx
#
# 用法（all 目标，需要 sudo）：
#   sudo scripts/deploy.sh --target=all             backend + web，nginx 统一 reload 一次

set -euo pipefail

# ==============================================================================
# 项目配置——由 new-service-deploy skill 在初始化时填入，后续不应频繁改动。
# 端口变更需走 specs/deployment-common.md 第二节「端口分配总表」的登记流程。
# ==============================================================================
SERVICE_NAME="<SERVICE_NAME>"      # 服务名（小写字母+连字符，与 supervisord/nginx/数据库名保持一致）
APP_PORT=<APP_PORT>                # Spring Boot 内部监听端口（只绑 127.0.0.1，不对外暴露）
NGINX_PORT=<NGINX_PORT>            # nginx 对外监听端口
DB_HOST="127.0.0.1"
DB_PORT=<DB_PORT>                  # PostgreSQL 端口
DB_NAME="<DB_NAME>"               # 数据库名（通常与 SERVICE_NAME 相同）
# ==============================================================================

# 健康检查端点（见 specs/deployment-common.md 第六节）：
# 统一格式 /api/<service-name>/health，通过 Spring Boot Actuator 实现，
# 配置 management.endpoints.web.base-path=/api/<service-name>，不使用 /actuator/health。
HEALTH_URL="http://127.0.0.1:${APP_PORT}/api/${SERVICE_NAME}/health"
HEALTH_TIMEOUT_SECONDS=60
HEALTH_POLL_INTERVAL_SECONDS=2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# 部署配置文件（nginx vhost、env.example 等）与脚本分开存放：
#   scripts/ — 怎么部署（脚本逻辑）
#   deploy-conf/ — 部署成什么样（静态配置文件，提前生成好纳入版本管理）
DEPLOY_CONF_DIR="${PROJECT_ROOT}/deploy-conf"
BACKEND_DIR="${PROJECT_ROOT}/src/backend"
WEB_DIR="${PROJECT_ROOT}/src/web"

APP_DIR="/opt/soft/apps/${SERVICE_NAME}"
LOG_DIR="/data/logs/apps/${SERVICE_NAME}"
WEB_APP_DIR="${APP_DIR}/web"                            # 前端静态资源部署目录
SUPERVISOR_CONF="/etc/supervisor/conf.d/${SERVICE_NAME}.ini"
NGINX_BIN="/opt/soft/nginx/sbin/nginx"
NGINX_VHOST_DST="/opt/soft/nginx/conf/vhosts/${SERVICE_NAME}.conf"

TARGET="backend"
ACTION="deploy"
ENV="dev"
INSTALL_NGINX=true
SKIP_CONFIRM=false

usage() {
	cat <<EOF
用法: $(basename "$0") [选项]

目标（--target 缺省为 backend）：
  --target=backend   （默认）处理后端服务，见下方 backend 选项
  --target=web       构建部署前端静态资源，见下方 web 选项
  --target=all       backend + web 依次执行，nginx 统一 reload 一次

环境（--env 缺省为 dev，决定装哪份 nginx vhost）：
  --env=dev          （默认）无域名/HTTP，deploy-conf/nginx/${SERVICE_NAME}.dev.conf
  --env=test         域名 + HTTPS，证书需先用 scripts/apply-ssl.sh test 申请
  --env=prod         域名 + HTTPS，证书需先用 scripts/apply-ssl.sh prod 申请

backend 选项（需要 sudo）：
  --no-nginx         只处理 supervisord 管理的服务本身，不改动共享 nginx 配置
  --stop             只停止服务，不删除任何部署文件
  --remove           完全移除（停止 + 删 supervisord 配置 + 删 nginx vhost + reload）
  --yes              配合 --remove 跳过二次确认

web 选项（需要 sudo）：
  --no-nginx         只更新静态资源目录，不改动共享 nginx 配置

  -h, --help         显示本帮助
EOF
}

for arg in "$@"; do
	case "${arg}" in
	--target=backend) TARGET="backend" ;;
	--target=web) TARGET="web" ;;
	--target=all) TARGET="all" ;;
	--env=dev) ENV="dev" ;;
	--env=test) ENV="test" ;;
	--env=prod) ENV="prod" ;;
	--no-nginx) INSTALL_NGINX=false ;;
	--stop) ACTION="stop" ;;
	--remove) ACTION="remove" ;;
	--yes) SKIP_CONFIRM=true ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "未知参数: ${arg}" >&2
		usage >&2
		exit 1
		;;
	esac
done

# 日志格式按 specs/deployment-common.md 第四节「部署日志规范」：
# 每个模块开头打印一次带执行时间的日志头，模块之间空一行。
step() {
	echo
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== $* ====="
}
info() { echo "$*"; }
warn() { echo "!! $*" >&2; }

require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "缺少依赖命令: $1" >&2
		exit 1
	fi
}

if [ "${TARGET}" = "backend" ] || [ "${TARGET}" = "all" ]; then
	require_cmd supervisorctl
	require_cmd curl
	require_cmd mvn
	require_cmd java
fi

if [ "${TARGET}" = "web" ] || [ "${TARGET}" = "all" ]; then
	require_cmd npm
	[ -f "${WEB_DIR}/package.json" ] || {
		echo "找不到 web 工程: ${WEB_DIR}/package.json" >&2
		exit 1
	}
fi

if [ "$(id -u)" -ne 0 ]; then
	echo "需要 root 权限（写 /opt/soft/apps、/etc/supervisor/conf.d 等），请用 sudo 运行" >&2
	exit 1
fi

# ── supervisord daemon 可达性检查（见 specs/deployment-common.md 第三节规则 1）──────
#
# 本脚本绝不自行执行 systemctl start/restart supervisor：如果 daemon 没在跑，说明操作者
# 需要先手动确认 /etc/supervisor/conf.d/*.ini 里的其他项目程序是否有"影子进程"已经在跑
# （ps aux 按 jar 路径核对），确认安全后才手动启动 daemon，而不是让部署脚本代劳。
check_supervisord_daemon() {
	# 用 `supervisorctl pid` 而不是 `status` 判断 daemon 是否可达：`status` 只要有任何
	# 程序不是 RUNNING 就返回非零，会把"程序没在跑"误判成"daemon 连不上"。
	if ! supervisorctl pid >/dev/null 2>&1; then
		warn "supervisord daemon 当前不可达（无法连接 supervisorctl）。"
		warn "本脚本不会自动执行 systemctl start supervisor——这台机器上曾经因为"
		warn "supervisord 重启导致其他项目的服务反复重启（见 specs/deployment-common.md 第八节）。"
		warn "请先手动执行以下检查，确认安全后再手动启动 daemon："
		warn "  1. systemctl status supervisor"
		warn "  2. 核对 /etc/supervisor/conf.d/*.ini 里每个程序对应的 jar 是否已经"
		warn "     以其他方式（非 supervisord）独立运行（ps aux | grep <jar路径>）"
		warn "  3. 确认安全后: systemctl start supervisor"
		exit 1
	fi
}

# ── 部署前检查清单（见 specs/deployment.md 第六节）────────────────────────────
preflight_checks() {
	step "0/6 部署前检查（specs/deployment.md 第六节）"
	check_supervisord_daemon
	info "[1/4] supervisord daemon 可达 ✓"

	if [ ! -f "${APP_DIR}/.env" ]; then
		warn "[2/4] 未找到 ${APP_DIR}/.env —— 服务启动时会因缺少数据库连接信息而失败。"
		warn "      请先执行： cp ${DEPLOY_CONF_DIR}/env.${ENV}.example ${APP_DIR}/.env 并填入真实凭证。"
		exit 1
	fi
	info "[2/4] ${APP_DIR}/.env 存在 ✓"

	if ss -tln 2>/dev/null | grep -qE ":(${NGINX_PORT}|${APP_PORT})\b"; then
		# 首次部署端口应为空闲；重新部署时端口已被本服务自己占用是正常情况，
		# 这里只做提示，不阻断——真正的冲突会在 supervisorctl restart 阶段暴露。
		info "[3/4] 端口 ${NGINX_PORT}/${APP_PORT} 已被占用（如果是本服务上次部署留下的，属正常）"
	else
		info "[3/4] 端口 ${NGINX_PORT}/${APP_PORT} 空闲 ✓"
	fi

	if [ -x "${NGINX_BIN}" ] && "${NGINX_BIN}" -t >/dev/null 2>&1; then
		info "[4/4] nginx 配置当前健康 ✓"
	else
		warn "[4/4] nginx -t 检查未通过或找不到 ${NGINX_BIN}，共享 nginx 当前状态不健康"
		warn "      （如果只想部署应用本身不碰 nginx，加 --no-nginx 重试）"
		exit 1
	fi
}

# ── 启动/重启后的健康检查（见 specs/deployment-common.md 第六节）────────────────
#
# 探活失败不代表进程一定挂了，也可能是 Flyway 迁移/Hibernate 校验还没跑完，
# 所以给足 60 秒轮询而不是探一次就判定失败；超时必须阻断后续步骤。
wait_for_health() {
	local elapsed=0
	while [ "${elapsed}" -lt "${HEALTH_TIMEOUT_SECONDS}" ]; do
		if curl -sf -o /dev/null "${HEALTH_URL}"; then
			info "健康检查通过（${HEALTH_URL}，耗时 ${elapsed} 秒）"
			return 0
		fi
		sleep "${HEALTH_POLL_INTERVAL_SECONDS}"
		elapsed=$((elapsed + HEALTH_POLL_INTERVAL_SECONDS))
	done
	warn "健康检查在 ${HEALTH_TIMEOUT_SECONDS} 秒内未通过（${HEALTH_URL}）"
	warn "部署已中止，不会继续安装/重载 nginx。排查启动日志："
	warn "  tail -100 ${LOG_DIR}/supervisord.log"
	exit 1
}

do_stop() {
	step "停止 ${SERVICE_NAME}（不删除部署文件）"
	supervisorctl stop "${SERVICE_NAME}"
	# stop 后程序状态是 STOPPED（非 RUNNING），supervisorctl status 对此返回非零退出码——
	# 这里是预期状态不是错误，用 || true 避免让脚本以失败退出码收尾。
	supervisorctl status "${SERVICE_NAME}" || true
}

do_remove() {
	if [ "${SKIP_CONFIRM}" != true ]; then
		read -r -p "将完全移除 ${SERVICE_NAME}（停止进程 + 删 supervisord 配置 + 删 nginx vhost + 全局 reload），确认？[y/N] " reply
		case "${reply}" in
		[yY]*) ;;
		*)
			echo "已取消"
			exit 0
			;;
		esac
	fi

	step "1/2 停止并移除 supervisord 配置"
	supervisorctl stop "${SERVICE_NAME}" 2>/dev/null || true
	rm -f "${SUPERVISOR_CONF}"
	supervisorctl reread
	supervisorctl update

	if [ -f "${NGINX_VHOST_DST}" ]; then
		step "2/2 移除 nginx vhost 并 reload（共享基础设施，将执行一次全局 reload）"
		rm -f "${NGINX_VHOST_DST}"
		"${NGINX_BIN}" -t
		"${NGINX_BIN}" -s reload
	else
		step "2/2 未安装过 nginx vhost，跳过"
	fi

	step "移除完成"
}

# ── nginx vhost 安装（backend/web 共用，见 specs/deployment-common.md 第三节强制规范）──────
# 装哪份 vhost 由 --env 决定：dev 无域名/HTTP，test/prod 域名+HTTPS（各自独立机器）。
# test/prod 需要先跑 scripts/apply-ssl.sh 申请好证书，本函数只装 vhost，不申请证书。
install_nginx_vhost() {
	local nginx_conf_src="${DEPLOY_CONF_DIR}/nginx/${SERVICE_NAME}.${ENV}.conf"
	if [ ! -x "${NGINX_BIN}" ]; then
		echo "未找到 nginx 可执行文件: ${NGINX_BIN}" >&2
		exit 1
	fi
	if [ ! -f "${nginx_conf_src}" ]; then
		echo "未找到 --env=${ENV} 对应的 nginx 配置: ${nginx_conf_src}" >&2
		exit 1
	fi
	if [ "${ENV}" != "dev" ]; then
		info "使用 --env=${ENV}，确认已经用 scripts/apply-ssl.sh ${ENV} 申请好证书（/opt/soft/nginx/ssl/），"
		info "且域名已解析到本机——这两步不是本脚本负责的（见 ${nginx_conf_src} 的 server_name）。"
	fi
	cp "${nginx_conf_src}" "${NGINX_VHOST_DST}"
	"${NGINX_BIN}" -t
	"${NGINX_BIN}" -s reload
}

# 探测对外访问地址（只用于 dev 环境提示，test/prod 有固定域名）。
EXTERNAL_IP=""
detect_external_ip() {
	if [ -z "${EXTERNAL_IP}" ]; then
		EXTERNAL_IP="$(curl -s --max-time 3 https://icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
		if [ -z "${EXTERNAL_IP}" ]; then
			EXTERNAL_IP="$(curl -s --max-time 3 https://ifconfig.me 2>/dev/null || true)"
		fi
		if [ -z "${EXTERNAL_IP}" ]; then
			EXTERNAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
		fi
		EXTERNAL_IP="${EXTERNAL_IP:-<host>}"
	fi
	echo "${EXTERNAL_IP}"
}

access_url() {
	local path="$1"
	# test/prod 域名在 deploy-conf/nginx/<SERVICE_NAME>.{test,prod}.conf 的 server_name 是唯一真实来源，
	# 下方只是打印提示用，改域名时两处要同步。
	case "${ENV}" in
	test) echo "https://<TEST_DOMAIN>:${NGINX_PORT}${path}" ;;
	prod) echo "https://<PROD_DOMAIN>:${NGINX_PORT}${path}" ;;
	*) echo "http://$(detect_external_ip):${NGINX_PORT}${path}" ;;
	esac
}

do_deploy() {
	preflight_checks

	step "1/6 构建后端 jar（${BACKEND_DIR}）"
	(cd "${BACKEND_DIR}" && mvn -q clean package -DskipTests)

	JAR_FILE=$(find "${BACKEND_DIR}/target" -maxdepth 1 -name "${SERVICE_NAME}-*.jar" ! -name "*sources*" | head -n1)
	if [ -z "${JAR_FILE}" ]; then
		echo "未找到构建产物 jar，中止部署" >&2
		exit 1
	fi
	info "构建产物: ${JAR_FILE}"

	step "2/6 部署 jar 到 ${APP_DIR}"
	mkdir -p "${APP_DIR}" "${LOG_DIR}"
	cp "${JAR_FILE}" "${APP_DIR}/${SERVICE_NAME}.jar"

	step "3/6 写入 supervisord 配置 ${SUPERVISOR_CONF}"
	# 从 deploy-conf/supervisor/<SERVICE_NAME>.${ENV}.ini 拷贝，不在部署时用 heredoc 现场拼接——
	# 提前生成好、纳入版本管理，更容易审查和追踪变更。
	cp "${DEPLOY_CONF_DIR}/supervisor/${SERVICE_NAME}.${ENV}.ini" "${SUPERVISOR_CONF}"

	step "4/6 重新加载 supervisord 并（重）启动服务"
	supervisorctl reread
	supervisorctl update
	supervisorctl restart "${SERVICE_NAME}" 2>/dev/null || supervisorctl start "${SERVICE_NAME}"
	supervisorctl status "${SERVICE_NAME}"

	step "5/6 健康检查（${HEALTH_URL}，最长等待 ${HEALTH_TIMEOUT_SECONDS} 秒）"
	wait_for_health

	if [ "${INSTALL_NGINX}" = true ] && [ "${TARGET}" != "all" ]; then
		step "6/6 安装 nginx 反向代理配置"
		install_nginx_vhost
	else
		step "6/6 跳过 nginx 配置安装（$([ "${TARGET}" = "all" ] && echo "--target=all 统一在最后安装一次" || echo "--no-nginx")）"
	fi

	step "部署完成"
	info "应用部署路径: ${APP_DIR}/${SERVICE_NAME}.jar"
	info "应用内部端口: 127.0.0.1:${APP_PORT}（不对外暴露）"
	if [ "${INSTALL_NGINX}" = true ]; then
		info "对外访问端口: ${NGINX_PORT}（经 nginx 反向代理，如 $(access_url "/api/${SERVICE_NAME}/health")）"
	fi
	info "查看日志: tail -f ${LOG_DIR}/supervisord.log"
	info "查看进程状态: supervisorctl status ${SERVICE_NAME}"
}

do_web_build_and_deploy() {
	step "1/3 构建前端静态资源（${WEB_DIR}）"
	(cd "${WEB_DIR}" && npm ci --no-audit --no-fund && npm run build)
	if [ ! -d "${WEB_DIR}/dist" ]; then
		echo "未找到 web 构建产物: ${WEB_DIR}/dist" >&2
		exit 1
	fi

	step "2/3 部署静态资源到 ${WEB_APP_DIR}"
	rm -rf "${WEB_APP_DIR}"
	mkdir -p "${WEB_APP_DIR}"
	cp -r "${WEB_DIR}/dist/." "${WEB_APP_DIR}/"
	info "静态资源部署路径: ${WEB_APP_DIR}"

	if [ "${INSTALL_NGINX}" = true ] && [ "${TARGET}" != "all" ]; then
		step "3/3 安装 nginx 反向代理配置"
		install_nginx_vhost
	else
		step "3/3 跳过 nginx 配置安装（$([ "${TARGET}" = "all" ] && echo "--target=all 统一在最后安装一次" || echo "--no-nginx")）"
	fi
}

if [ "${TARGET}" = "backend" ]; then
	case "${ACTION}" in
	deploy) do_deploy ;;
	stop) do_stop ;;
	remove) do_remove ;;
	esac
	exit 0
fi

if [ "${TARGET}" = "web" ]; then
	case "${ACTION}" in
	deploy) do_web_build_and_deploy ;;
	stop | remove)
		info "--target=web 没有\"停止/移除\"的概念（只是静态构建产物），忽略 ${ACTION}"
		;;
	esac
	exit 0
fi

if [ "${TARGET}" = "all" ]; then
	case "${ACTION}" in
	deploy)
		do_deploy
		do_web_build_and_deploy
		if [ "${INSTALL_NGINX}" = true ]; then
			step "统一安装 nginx 反向代理配置（backend + web 均已部署完成，只 reload 一次）"
			install_nginx_vhost
		fi
		step "全量部署完成"
		info "后端应用: ${APP_DIR}/${SERVICE_NAME}.jar"
		info "前端静态资源: ${WEB_APP_DIR}"
		info "对外访问: $(access_url "/")"
		;;
	stop)
		info "--target=all 的 --stop 只作用于 backend（web 只是构建产物，没有"停止"的概念）"
		do_stop
		;;
	remove)
		info "--target=all 的 --remove 只作用于 backend（web 只是构建产物，没有"移除"的概念）"
		do_remove
		;;
	esac
	exit 0
fi
