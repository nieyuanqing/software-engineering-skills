# vhosts/

本服务的 nginx vhost 配置放在这里，由 `/new-java-project` skill 生成
（`<service-name>.{dev,test,prod}.conf`），部署脚本 `scripts/deploy.sh` 按 `--env` 选择对应文件
拷贝到主机的 `/opt/soft/nginx/conf/vhosts/<service-name>.conf` 并生效（见
`specs/deployment-common.md` 第一节的目录约定）。

本 README 由 `/new-nginx-conf` 生成（与上一级 `deploy-conf/nginx/` 下的 `nginx.conf`、`subconf/`
等主机级基础配置同属该 skill），只在首次初始化时落地一次；`/new-java-project` 之后往本目录添加
的具体服务 vhost 文件不会被 `/new-nginx-conf` 覆盖，两个 skill 各自只处理自己负责的文件。
