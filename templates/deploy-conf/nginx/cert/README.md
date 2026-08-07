# cert/

SSL 证书文件（`.pem` / `.key`）放在这里，证书本身**不纳入版本管理**——已在仓库根目录的
`.gitignore` 里加入 `templates/deploy-conf/nginx/cert/*.pem`、`templates/deploy-conf/nginx/cert/*.key`
及生成目标 `deploy-conf/nginx/cert/` 下的对应规则，避免误提交私钥。

`subconf/ssl.conf` 里的 `ssl_certificate`/`ssl_certificate_key` 使用占位符路径
`cert/<DOMAIN>.pem`/`cert/<DOMAIN>.key`——使用时把 `<DOMAIN>` 替换为实际证书对应的域名，并把证书
文件放到这里同名。如果不同服务需要各自独立的证书，改为在各自 vhost 里单独声明
`ssl_certificate`/`ssl_certificate_key`（见 `templates/deploy-conf/nginx/vhosts/service.test.conf`、
`vhosts/service.prod.conf`），不 include `subconf/ssl.conf` 的证书路径部分即可。本目录本身不预置
任何证书。申请流程可参考 `templates/scripts/apply-ssl.sh`（Let's Encrypt + acme.sh，HTTP-01 webroot 验证）。
