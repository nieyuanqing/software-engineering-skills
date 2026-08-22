# 部署规范（<SERVICE_NAME> 专属）

> 定位：本工程（<SERVICE_NAME>）的部署约定与操作细节。
> **主机层面、跨项目通用的规则（目录/命名约定、端口登记总表、共享 supervisord/nginx 的操作规范、
> 故障案例）都在 [共享主机部署通用规范](./deployment-common.md) 里，本文档不重复，只写
> <SERVICE_NAME> 自己的部分**。执行任何部署操作前，先确认已经读过那份通用规范。
> 适用范围：`scripts/deploy.sh`（含 `scripts/apply-ssl.sh`）部署脚本与 `deploy-conf/` 下的部署配置。

---

## 目录

1. [部署架构](#一部署架构)
2. [部署环境（dev/test/prod）](#二部署环境devtestprod)
3. [目录与端口分配](#三目录与端口分配)
4. [部署流程](#四部署流程)
5. [数据库部署约定](#五数据库部署约定)
6. [部署前检查清单](#六部署前检查清单)
7. [回滚与停止](#七回滚与停止)

---

## 一、部署架构

```
用户请求
   │
   ▼
nginx（对外监听 <NGINX_PORT>）
   │  反向代理 /<SERVICE_NAME>/api/；/<SERVICE_NAME>/web/ 直接从磁盘提供静态资源（如有前端）
   ▼
Spring Boot 应用（127.0.0.1:<APP_PORT>，只绑定本机地址，不直接对外）
   │
   ▼
PostgreSQL <DB_PORT>（本机私有实例）
```

- 应用进程由 **supervisord** 管理（`autostart`/`autorestart`，进程异常退出后自动拉起）
- 对外访问**必须**经过 nginx，应用端口不对外暴露——这是架构约束，不是可选项
- dev 环境下 supervisord 与 nginx 是主机上多个项目共用的基础设施，操作规范见 [共享主机部署通用规范](./deployment-common.md) 第三节

---

## 二、部署环境（dev/test/prod）

三套环境是**三台完全独立的机器**，不是同一台机器跑三份：

| 环境 | 机器 | 域名 / 协议 | 用途 |
|---|---|---|---|
| `dev`（默认） | 与其他项目共用的主机 | 无域名，HTTP，直接用 IP+端口访问 | 日常开发验证 |
| `test` | 独立机器 | `<TEST_DOMAIN>`，HTTPS | 集成测试/验收 |
| `prod` | 独立机器 | `<PROD_DOMAIN>`，HTTPS | 生产 |

对应的 nginx vhost 是提前生成好的静态文件：
- `deploy-conf/nginx/vhosts/<SERVICE_NAME>.dev.conf`
- `deploy-conf/nginx/vhosts/<SERVICE_NAME>.test.conf`（`server_name <TEST_DOMAIN>`）
- `deploy-conf/nginx/vhosts/<SERVICE_NAME>.prod.conf`（`server_name <PROD_DOMAIN>`）

`deploy-conf/nginx/` 下除 `vhosts/`（本服务专属，由 `/new-java-project` 生成）之外的其余内容
（`nginx.conf`、`subconf/`、`mime.types` 等）是主机级共享 nginx 基础配置，由 `/new-nginx-conf`
生成，通常整台主机只需要生成一次，不随每个服务重复生成。

首次在 test/prod 机器上部署：
1. 确认域名已经解析到这台机器
2. 在目标机器上执行 `scripts/apply-ssl.sh test`（或 `prod`）申请证书
3. 证书就位后再执行 `scripts/deploy.sh --env=test`（或 `prod`）

---

## 三、目录与端口分配

按 [共享主机部署通用规范](./deployment-common.md) 第一节的目录模板：

| 用途 | 路径 |
|---|---|
| 应用部署目录 | `/opt/soft/apps/<SERVICE_NAME>/` |
| 应用日志 | `/data/logs/apps/<SERVICE_NAME>/` |
| supervisord 配置（部署产物） | `/etc/supervisor/conf.d/<SERVICE_NAME>.ini` |
| nginx vhost 配置（部署产物） | `/opt/soft/nginx/conf/vhosts/<SERVICE_NAME>.conf` |
| 前端静态资源目录（如有） | `/opt/soft/apps/<SERVICE_NAME>/web/`（`vite build` 产物） |
| SSL 证书（test/prod） | `/opt/soft/nginx/ssl/<SERVICE_NAME>.pem` / `<SERVICE_NAME>.key` |

端口分配（dev/test/prod 三台机器上都一样）：

| 用途 | 端口 |
|---|---|
| nginx 对外反向代理 | `<NGINX_PORT>` |
| Spring Boot 应用内部监听（仅 `127.0.0.1`） | `<APP_PORT>` |

---

## 四、部署流程

```bash
# 1. 准备数据库连接信息（首次部署）
cp deploy-conf/env.example /opt/soft/apps/<SERVICE_NAME>/.env
vim /opt/soft/apps/<SERVICE_NAME>/.env   # 填入真实的 DB_URL / DB_USERNAME / DB_PASSWORD 等

# 2.（仅 test/prod 需要）申请 SSL 证书
bash scripts/apply-ssl.sh test    # 或 prod

# 3. 执行部署
sudo scripts/deploy.sh                      # 完整部署（--env=dev）
sudo scripts/deploy.sh --env=test           # 装 test 环境 nginx 配置
sudo scripts/deploy.sh --no-nginx           # 只处理 supervisord/静态资源，不改动共享 nginx
```

`deploy.sh` 做的事：构建 jar → 拷贝到 `/opt/soft/apps/<SERVICE_NAME>/` → 写 supervisord 配置
（从 `deploy-conf/supervisor/<SERVICE_NAME>.ini` 拷贝）→ `supervisorctl reread/update/restart`
→ **健康检查通过后**才继续 → （非 `--no-nginx` 时）按 `--env` 选择对应 nginx vhost 安装并 reload。

脚本会在 `.env` 缺失时**主动报错退出**，不会用占位默认值静默启动。

**健康检查**：
- 端点：`http://127.0.0.1:<APP_PORT>/api/<SERVICE_NAME>/health`
- 启动/重启后轮询，每 2 秒一次，最长等待 60 秒
- 60 秒内未探活成功 → 部署脚本以非零退出码中止，提示去看 `/data/logs/apps/<SERVICE_NAME>/supervisord.log`

---

## 五、数据库部署约定

- 数据库名、角色名与服务名保持一致：`<DB_NAME>` / `<DB_NAME>`
- Schema 由应用启动时的 Flyway 自动迁移管理，部署时不需要手工建表
- 生产凭证只存在于目标主机的 `/opt/soft/apps/<SERVICE_NAME>/.env`，不进代码库
- dev/test/prod 三台机器各自独立的 PostgreSQL 实例，互不共享数据

---

## 六、部署前检查清单

```bash
supervisorctl status                                               # supervisord daemon 是否在跑
ls /opt/soft/apps/<SERVICE_NAME>/.env                              # .env 是否已准备好
ss -tln | grep -E ':(<NGINX_PORT>|<APP_PORT>)\b'                   # 目标端口是否空闲
/opt/soft/nginx/sbin/nginx -t                                      # nginx 配置当前是否健康
```

test/prod 额外确认：
```bash
ls /opt/soft/nginx/ssl/<SERVICE_NAME>.pem /opt/soft/nginx/ssl/<SERVICE_NAME>.key   # 证书是否就绪
```

全部确认后再执行 `scripts/deploy.sh`。

---

## 七、回滚与停止

```bash
# 停止服务（不删除部署文件，可随时重启）
supervisorctl stop <SERVICE_NAME>

# 完全移除（谨慎，仅在确定不再需要时执行）
supervisorctl stop <SERVICE_NAME>
rm /etc/supervisor/conf.d/<SERVICE_NAME>.ini
supervisorctl reread && supervisorctl update
rm /opt/soft/nginx/conf/vhosts/<SERVICE_NAME>.conf
/opt/soft/nginx/sbin/nginx -t && /opt/soft/nginx/sbin/nginx -s reload
```
