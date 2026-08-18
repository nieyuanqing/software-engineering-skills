#!/usr/bin/env bash
# <SERVICE_NAME> —— SSL 证书申请脚本（Let's Encrypt，HTTP-01 webroot 验证）
#
# 用途：为 test/prod 环境申请免费 SSL 证书，证书装到 /opt/soft/nginx/ssl/ 后由 nginx vhost 引用。
# test/prod 各是一台独立机器，一台机器只会用到其中一个域名，因此不支持"all"一次申请两套。
#
# 使用方式：
#   bash scripts/apply-ssl.sh test   # 在 test 机器上申请 test 环境域名证书
#   bash scripts/apply-ssl.sh prod   # 在 prod 机器上申请 prod 环境域名证书
#
# 前提：
#   1. 已安装 acme.sh（curl https://get.acme.sh | sh）
#   2. nginx 已部署且 80 端口可从公网访问（只用于 ACME 验证，不承载业务流量）
#   3. 对应域名已解析到本机（见下方 issue_cert() 的域名配置）
#
# 执行顺序：先跑本脚本申请好证书，再执行 scripts/deploy.sh --env=test（或 prod）安装 nginx vhost。
# deploy.sh 不会自己申请证书，只负责把已经存在的证书对应的 vhost 装上去。

set -euo pipefail

# ==============================================================================
# 项目配置——由 new-service-deploy skill 在初始化时填入
# ==============================================================================
SERVICE_NAME="<SERVICE_NAME>"
TEST_DOMAIN="<TEST_DOMAIN>"   # test 环境域名，与 deploy-conf/nginx/vhosts/<SERVICE_NAME>.test.conf 的 server_name 保持一致
PROD_DOMAIN="<PROD_DOMAIN>"   # prod 环境域名，与 deploy-conf/nginx/vhosts/<SERVICE_NAME>.prod.conf 的 server_name 保持一致
# ==============================================================================

CERT_DIR="/opt/soft/nginx/ssl"
ACME_SH="${ACME_SH:-$HOME/.acme.sh/acme.sh}"
WEBROOT="/var/www/acme-challenge"
NGINX_BIN="/opt/soft/nginx/sbin/nginx"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [apply-ssl] $*"; }
fail() {
	log "错误: $*"
	exit 1
}

check_prerequisites() {
	[ -x "$ACME_SH" ] || fail "acme.sh 未安装，请执行: curl https://get.acme.sh | sh"
	[ -x "$NGINX_BIN" ] || fail "未找到 nginx 可执行文件: $NGINX_BIN（先完成 nginx 部署）"
	mkdir -p "$WEBROOT"
}

issue_cert() {
	local env="$1"
	local domain

	case "$env" in
	# 域名需要和对应的 deploy-conf/nginx/vhosts/<SERVICE_NAME>.$env.conf 里的 server_name 保持一致
	test) domain="${TEST_DOMAIN}" ;;
	prod) domain="${PROD_DOMAIN}" ;;
	*) fail "未知环境: $env；可选值: test, prod" ;;
	esac

	local key_file="$CERT_DIR/${SERVICE_NAME}.key"
	local cert_file="$CERT_DIR/${SERVICE_NAME}.pem"

	mkdir -p "$CERT_DIR"

	log "申请证书: $domain (环境: $env)"
	"$ACME_SH" --issue \
		--server letsencrypt \
		--webroot "$WEBROOT" \
		-d "$domain" \
		--keylength ec-256 \
		--force ||
		fail "证书申请失败: $domain"

	log "安装证书到: $cert_file"
	"$ACME_SH" --install-cert \
		-d "$domain" \
		--ecc \
		--key-file "$key_file" \
		--fullchain-file "$cert_file" \
		--reloadcmd "$NGINX_BIN -s reload" ||
		fail "证书安装失败: $domain"

	log "证书已就绪: $cert_file（下一步: scripts/deploy.sh --env=$env）"
}

check_prerequisites

case "${1:-}" in
test | prod)
	issue_cert "$1"
	;;
*)
	echo "Usage: bash scripts/apply-ssl.sh test|prod"
	exit 1
	;;
esac

log "完成"
