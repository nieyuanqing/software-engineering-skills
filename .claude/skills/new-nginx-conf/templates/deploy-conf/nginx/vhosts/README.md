# vhosts/

**本目录是"源码安装 nginx"时的站点配置 include 目标**，不是仓库里站点配置的存放处。

`nginx.conf` 里的 `include vhosts/*.conf;` 让本目录下的每个 `.conf` 生效。站点配置本身由
`/new-java-project` 生成在**上一级**目录：`deploy-conf/nginx/<service-name>.{dev,test,prod}.conf`，
部署时 `scripts/deploy.sh` 按 `--env` 选一份安装到 `$NGINX_CONF_DIR/<service-name>.conf`。

按主机上 nginx 的安装方式二选一：

| 主机上 nginx | 部署时怎么指 | 生效路径 |
|---|---|---|
| apt 安装（默认） | 什么都不用设，`NGINX_CONF_DIR` 默认 `/etc/nginx/conf.d` | `/etc/nginx/conf.d/<service>.conf`（apt 的主配置默认 include 这里） |
| 源码安装到 `/opt/soft/nginx` | `NGINX_CONF_DIR=/opt/soft/nginx/conf/vhosts bash scripts/deploy.sh ...` | `/opt/soft/nginx/conf/vhosts/<service>.conf`，由本目录的 `include vhosts/*.conf;` 加载 |

源码安装场景下，`/opt/soft/nginx/conf` 由本仓库 `deploy-conf/nginx/` 整棵目录树安装而来
（`nginx.conf`、`mime.types`、`subconf/`、`upstream/`、`cert/`、`html/` 均由 `/new-nginx-conf` 生成），
证书目录同理用 `NGINX_SSL_DIR`（`deploy.sh`）与 `CERT_DIR`（`apply-ssl.sh`）指到同一处。

**`/new-nginx-conf` 不在本目录生成任何站点配置**，`/new-java-project` 也不往本目录写——
两个 skill 的归属靠文件名区分（站点配置一律是 `<service-name>.<env>.conf`），不靠子目录。
