# 共享主机部署通用规范（跨项目）

> 定位：这份文档**不针对任何特定工程**——它记录的是"共享主机"本身的部署约定与操作规范。
> 主机上可能同时运行着多个不相关项目，共用同一套 supervisord、nginx、目录结构。
> 任何要在这台主机上部署新服务的人，都应该先读这份文档，而不是各自摸索一套部署方式。
> 项目专属的部署细节（端口分配、数据库名、部署脚本用法）见各项目自己的 `specs/deployment.md`。
> 版本：v1.0 ｜ 日期：2026-08-05

---

## 目录

1. [目录与命名约定](#一目录与命名约定)
2. [端口分配总表](#二端口分配总表)
3. [共享基础设施操作规范（强制）](#三共享基础设施操作规范强制)
4. [部署日志规范](#四部署日志规范)
5. [部署前检查清单模板](#五部署前检查清单模板)
6. [服务启动健康检查（强制）](#六服务启动健康检查强制)
7. [回滚与停止模板](#七回滚与停止模板)
8. [故障案例：启动 supervisord 引发的连带故障](#八故障案例启动-supervisord-引发的连带故障)

---

## 一、目录与命名约定

主机上所有服务统一沿用以下目录结构，新服务接入时不要另创一套：

| 用途 | 路径 |
|---|---|
| 应用部署目录（jar + `.env`） | `/opt/soft/apps/<service-name>/` |
| 应用日志 | `/data/logs/apps/<service-name>/` |
| supervisord 程序配置 | `/etc/supervisor/conf.d/<service-name>.ini` |
| nginx vhost 配置 | `/opt/soft/nginx/conf/vhosts/<service-name>.conf` |

`<service-name>` 必须在该项目内部保持统一（Maven `artifactId`、`spring.application.name`、supervisord `[program:x]` 名称、数据库名/用户名全部同名）——避免出现"代码里叫 A，部署目录叫 B"的错位，这类错位是排查问题时最容易踩的坑。

---

## 二、端口分配总表

这是一张**持续维护的全局登记表**，任何新项目部署前必须先查一遍当前占用，部署后必须把新分配的端口回填到这里（或回填到自己项目的 `specs/baseline-versions.md` 并在本表加一行索引），不允许部署时临时改动而不回写文档。

| 端口段 | 占用方 |
|---|---|
| （由各主机维护，在这台主机的项目仓库中登记） | |

**新服务接入规则**：执行 `ss -tln` 确认当前实际占用情况（不要只看这张表——表可能滞后于实际状态），延续序列向上取整数段分配，分配后同步更新本表和自己项目的基线文档。

---

## 三、共享基础设施操作规范（强制）

以下规则源自实际部署中踩过的坑（见第八节故障案例），**任何项目在这台主机上执行涉及 supervisord 或 nginx 的操作前都要过一遍**：

1. **启动/重启 supervisord daemon 前，必须先看一遍 `/etc/supervisor/conf.d/*.ini` 里的每个程序对应的进程是否已经在跑**（`ps aux` 按 jar 路径核对）。如果某个 `.ini` 里的程序其实是靠别的方式（手动、别的启动脚本）已经在运行的"影子进程"，supervisord 一启动就会尝试再启动一份，轻则端口冲突启动失败，重则（`autorestart=true`）陷入反复重启的 crash loop，白白消耗资源、刷爆日志

2. **`nginx -s reload` 影响的是全局 nginx 进程**，会重新加载所有项目的 vhost 配置。虽然不会中断现有连接，但如果别的项目的配置本身有问题，这次 reload 可能把那个问题暴露出来。操作前用 `nginx -t` 先过一遍语法检查，但语法对不代表所有项目的行为都不受影响

3. **禁止在没有明确授权的情况下 `stop`/`remove`/修改不属于本项目的 supervisord 程序或 nginx vhost**。发现别的项目的程序状态异常（`EXITED`/`FATAL`/crash loop）时，**先报告现象、说明是否是本次操作引发的，再询问如何处理**，不要自己判断"看起来没事"就动手清理

4. **只删除/修改 `/etc/supervisor/conf.d/` 下与本项目相关的 `.ini` 文件**，即使看到其他明显失效的配置（如指向已被别的进程占用同一端口的重复配置），也只在该配置所属项目的人明确要求时才处理，处理前确认清楚该配置对应的服务是否有其他形式的存活实例，避免误删还在被使用的配置

5. **"完整执行"和"只做自己那部分"要分开设计**——涉及共享 nginx/supervisord 的部署脚本应该提供类似 `--no-nginx` 的选项，让"先只部署应用本身、暂不碰共享 nginx"成为一个明确、独立的选项，而不是必须一把全上

---

## 四、部署日志规范

部署脚本在共享主机上运行，排查问题时经常需要把多个项目的部署日志放在一起对时间线——日志格式不统一会让这件事变得很麻烦。所有项目的部署脚本统一遵循以下格式：

1. **每个部署步骤（模块）开始前打印一个日志头**，日志头必须包含**执行时间**（本地时间，精确到秒）和**模块名称**
2. **模块之间用一个空行分隔**，不要让不同模块的输出无缝粘在一起，也不要每行都留空行
3. 日志头格式统一为：

   ```
   [YYYY-MM-DD HH:MM:SS] ===== <模块名> =====
   ```

4. 模块内部的具体命令输出、警告信息紧跟在日志头下面，不额外加格式

**示例**：

```
[2026-07-28 18:02:15] ===== 1/5 构建后端 jar =====
[INFO] BUILD SUCCESS

[2026-07-28 18:02:41] ===== 2/5 部署 jar 到目标目录 =====
构建产物: /opt/soft/apps/myservice/myservice.jar

[2026-07-28 18:02:42] ===== 3/5 写入 supervisord 配置 =====
```

各项目部署脚本里做日志打印的辅助函数（通常叫 `log()` 或 `step()`）都应该实现这个格式，不要各自发明一套。`templates/scripts/deploy.sh` 里的 `step()/info()/warn()` 函数是这个约定的参照实现，可以直接抄。

---

## 五、部署前检查清单模板

```bash
supervisorctl status                                  # supervisord daemon 是否在跑，别的程序状态是否正常
ls /opt/soft/apps/<service-name>/.env                  # .env 是否已准备好
ss -tln | grep -E ':(<port1>|<port2>)\b'               # 目标端口是否空闲（应为空输出）
/opt/soft/nginx/sbin/nginx -t                          # nginx 配置当前是否健康（部署前的基线状态）
```

四项全部确认后再执行具体项目的部署脚本。

---

## 六、服务启动健康检查（强制）

部署脚本在（重）启动服务进程后，**不能假设"进程存在=服务已就绪"**就直接往下走（比如接着去装/重载共享的 nginx 配置）。进程起来了不代表服务真的能处理请求——Flyway 迁移、连接池初始化、缓存预热都需要时间，这段时间里如果就去接流量或者对外宣布"部署成功"，故障会在生产流量打进来的那一刻才暴露。

**规则**：

1. 每个服务必须提供一个健康检查端点，**统一路径格式为 `/api/<service-name>/health`**（如 myservice 对应 `/api/myservice/health`）——这是本机所有项目共同遵守的规范，不是各项目自选路径；Spring Boot 项目通过 `management.endpoints.web.base-path=/api/<service-name>` 配置 Actuator 实现，不使用 Actuator 默认的 `/actuator/health`。健康检查端点只对内网/本机可达，不通过共享 nginx 对外转发

2. 部署脚本在启动/重启进程后，必须轮询这个端点，**最长等待 60 秒**，检测成功后才能继续执行后续步骤（安装/重载 nginx、打印"部署成功"）

3. 60 秒内轮询不到成功，视为**部署失败**，中止脚本（非零退出码），不继续任何后续步骤，并提示去哪里看启动日志——不能静默继续或者只打个警告就往下走

4. 轮询间隔不要太短（避免刷日志）也不要太长（避免明明 2 秒就好了却等了 10 秒），推荐 2 秒间隔

5. **`supervisorctl restart`/`start` 本身会阻塞到 supervisord 配置里的 `startsecs` 结束才返回**——如果 `startsecs` 设得接近或超过应用真实启动耗时，健康检查会在这段阻塞已经等够之后才开始探测，第一次探测就通过，日志里的"耗时 N 秒"会永远趋近 0。这不是健康检查没生效，是两层等待时间重叠、互相掩盖了。`startsecs` 应该设得**小**（够用来判断"进程有没有立即崩溃"就行，如 3 秒），把"应用是否真正就绪"这件事完全交给健康检查去判断——这样日志里的耗时才反映应用真实的启动时间，而不是被 supervisord 的等待"吃掉"

**参照实现**：`templates/scripts/deploy.sh` 里的 `wait_for_health()` 函数与 `templates/deploy-conf/supervisor/service.ini`（`startsecs=3`）。

---

## 七、回滚与停止模板

```bash
# 停止服务（不删除部署文件，可随时重启）
supervisorctl stop <service-name>

# 完全移除（谨慎，仅在确定不再需要时执行）
supervisorctl stop <service-name>
rm /etc/supervisor/conf.d/<service-name>.ini
supervisorctl reread && supervisorctl update
rm /opt/soft/nginx/conf/vhosts/<service-name>.conf     # 如果部署时装过 nginx vhost
/opt/soft/nginx/sbin/nginx -t && /opt/soft/nginx/sbin/nginx -s reload
```

---

## 八、故障案例：启动 supervisord 引发的连带故障

记录一次首次部署时在共享主机上遇到的真实故障，作为第三节规则 1 的具体依据——**这是主机历史遗留状态的普遍风险，不是某个项目自己的问题**，后续任何项目部署时都可能重新踩到，放在通用规范里。

**现象**：主机的 supervisord daemon 原本处于停止状态（`inactive (dead)`），`/etc/supervisor/conf.d/` 下已经存在其他项目的 `agents.ini`、`knowledge.ini`（`autostart=true`、`autorestart=true`）。这两个服务的真实运行实例其实是通过别的方式手动启动的独立 java 进程，一直稳定运行，从未被 supervisord 管理过。

**触发**：为了让新服务能被 supervisord 管理，执行了 `systemctl start supervisor`。supervisord 启动后按配置尝试启动 `agents`/`knowledge`，与已经占用相同端口的独立进程冲突，新实例启动失败后因 `autorestart=true` 反复重启，陷入 crash loop（不断产生新 PID、消耗 CPU、刷日志），但**原有的独立进程本身没有被打断**。

**处理**：确认原有独立进程未受影响后，执行 `supervisorctl stop <service-a> <service-b>` 止住了 crash loop，未删除其 `.ini` 配置（保留给对应项目自行决定后续处理）。

**结论**：在这类"部分服务由 supervisord 管理、部分服务独立运行"的混合主机上，**任何一次 supervisord daemon 的启动/重启都可能触发未被管理的影子进程与配置冲突**。这条经验对所有后续在这台主机上部署的项目都适用。
