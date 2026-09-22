#!/usr/bin/env bash
# <SERVICE_NAME> —— SSL 证书申请脚本（Let's Encrypt，HTTP-01 webroot 验证）
#
# 用途：为 test/prod 环境申请免费 SSL 证书，装到 /etc/nginx/ssl/<域名>.{pem,key}，
#       由 deploy-conf/nginx/ 下对应环境的站点配置引用（文件名按域名，test/prod 互不覆盖）。
# test/prod 各是一台独立机器，一台机器只会用到其中一个域名，因此不支持"all"一次申请两套。
#
# 使用方式：
#   bash scripts/apply-ssl.sh -h     查看帮助
#   bash scripts/apply-ssl.sh test   # 在 test 机器上申请 test 环境域名证书
#   bash scripts/apply-ssl.sh prod   # 在 prod 机器上申请 prod 环境域名证书
#
# 前提：
#   1. 已安装 acme.sh（curl https://get.acme.sh | sh）
#   2. nginx 已部署且 80 端口可从公网访问（只用于 ACME 验证，不承载业务流量）
#      站点配置里的 /.well-known/acme-challenge/ 需指向本脚本的 WEBROOT
#   3. 对应域名已解析到本机（见下方 issue_cert() 的域名配置）
#
# 执行顺序：先跑本脚本申请好证书，再执行 scripts/deploy.sh --target ssl --env=test（或 prod）
# 安装站点配置。deploy.sh 不会自己申请证书，只负责把已存在证书对应的站点配置装上去；
# 证书缺失时 deploy.sh 会降级部署 dev（HTTP）配置并在日志里告警。

set -euo pipefail

# ==============================================================================
# 项目配置——由 /new-java-project skill 在初始化时填入
# ==============================================================================
SERVICE_NAME="<SERVICE_NAME>"
TEST_DOMAIN="<TEST_DOMAIN>"   # test 环境域名，与 deploy-conf/nginx/<SERVICE_NAME>.test.conf 的 server_name 保持一致
PROD_DOMAIN="<PROD_DOMAIN>"   # prod 环境域名，与 deploy-conf/nginx/<SERVICE_NAME>.prod.conf 的 server_name 保持一致
# ==============================================================================

# 证书目录与文件名口径必须与 deploy.sh 的 cert_domain_for_env/has_cert_for_env 一致
CERT_DIR="${CERT_DIR:-/etc/nginx/ssl}"
ACME_SH="${ACME_SH:-$HOME/.acme.sh/acme.sh}"
WEBROOT="${WEBROOT:-/var/www/acme-challenge}"
NGINX_BIN="${NGINX_BIN:-nginx}"

usage() {
    cat <<'EOF'
用法:
  bash scripts/apply-ssl.sh <环境>

环境:
  test   申请 test 环境域名证书（Let's Encrypt，HTTP-01 webroot 验证）
  prod   申请 prod 环境域名证书

说明:
  证书装到 /etc/nginx/ssl/<域名>.pem 与 <域名>.key，文件名按实际申请域名命名，
  test/prod 互不覆盖。重复执行会重新签发（--force），用于证书续期或换机重装。
  申请到的证书由 scripts/deploy.sh --target ssl --env <环境> 安装到 nginx 后生效。

前提:
  1. 已安装 acme.sh（curl https://get.acme.sh | sh）
  2. nginx 正在运行且 80 端口公网可达，/.well-known/acme-challenge/ 指向 /var/www/acme-challenge
  3. 对应域名已解析到本机

可用环境变量: ACME_SH（acme.sh 路径）、CERT_DIR（证书目录）、WEBROOT、NGINX_BIN
  -h, --help   显示本帮助
EOF
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [apply-ssl] $*"; }
fail() {
	log "错误: $*"
	exit 1
}

check_prerequisites() {
    [ -x "$ACME_SH" ] || fail "acme.sh 未安装（或不在 $ACME_SH），请执行: curl https://get.acme.sh | sh"
    command -v "$NGINX_BIN" >/dev/null 2>&1 || fail "未找到 nginx 可执行文件: $NGINX_BIN（先完成 nginx 部署）"
    mkdir -p "$WEBROOT" "$CERT_DIR"
}

issue_cert() {
	local env="$1"
	local domain

	# 域名需要和对应的 deploy-conf/nginx/<SERVICE_NAME>.$env.conf 里的 server_name 保持一致
	case "$env" in
	test) domain="${TEST_DOMAIN}" ;;
	prod) domain="${PROD_DOMAIN}" ;;
	*) fail "未知环境: $env；可选值: test, prod" ;;
	esac
	[ -n "$domain" ] || fail "$env 环境未配置域名（请检查本脚本顶部的 TEST_DOMAIN/PROD_DOMAIN）"

	local key_file="$CERT_DIR/$domain.key"
	local cert_file="$CERT_DIR/$domain.pem"

	log "申请证书: $domain（环境: $env）"
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

	log "证书已就绪: $cert_file"
	log "下一步: bash scripts/deploy.sh --target ssl --env $env（把 HTTPS 站点配置装到 nginx）"
}

case "${1:-}" in
-h | --help)
	usage
	exit 0
	;;
esac

if [ "${1:-}" = "" ]; then
	usage
	fail "缺少环境参数"
fi

check_prerequisites
issue_cert "$1"
log "完成"
