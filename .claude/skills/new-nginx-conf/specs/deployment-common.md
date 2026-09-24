# 共享主机部署通用规范（跨项目）

> 定位：这份文档**不针对任何特定工程**——它记录的是"共享主机"本身的部署约定与操作规范。
> 主机上可能同时运行着多个不相关项目，共用同一套 supervisord、nginx、目录结构。
> 任何要在这台主机上部署新服务的人，都应该先读这份文档，而不是各自摸索一套部署方式。
> 项目专属的部署细节（端口分配、数据库名、部署脚本用法）见各项目自己的 `specs/deployment.md`。
> 版本：v1.3 ｜ 日期：2026-09-24

---

## 目录

1. [目录与命名约定](#一目录与命名约定)
2. [端口分配总表](#二端口分配总表)
3. [共享基础设施操作规范（强制）](#三共享基础设施操作规范强制)
4. [部署日志规范](#四部署日志规范)
5. [部署前检查清单模板](#五部署前检查清单模板)
6. [服务启动健康检查（强制）](#六服务启动健康检查强制)
7. [回滚与停止模板](#七回滚与停止模板)
8. [故障案例](#八故障案例)
9. [配置与日志安全约定（强制）](#九配置与日志安全约定强制)

---

## 一、目录与命名约定

主机上所有服务统一沿用以下目录结构，新服务接入时不要另创一套：

| 用途 | 路径 |
|---|---|
| 应用部署目录（jar + `.env`） | `/opt/soft/apps/<service-name>/` |
| 应用日志 | `/data/logs/apps/<service-name>/` |
| supervisord 程序配置 | `/etc/supervisor/conf.d/<service-name>.<后缀>`（后缀见第一节末） |
| nginx 站点配置 | `/etc/nginx/conf.d/<service-name>.conf` |
| nginx 访问日志 | `/data/logs/nginx/<service-name>-access.log` |
| SSL 证书 | `/etc/nginx/ssl/<域名>.pem` + `<域名>.key` |

`<service-name>` 必须在该项目内部保持统一（Maven `artifactId`、`spring.application.name`、supervisord `[program:x]` 名称、数据库名/用户名全部同名）——避免出现"代码里叫 A，部署目录叫 B"的错位，这类错位是排查问题时最容易踩的坑。

**证书按域名命名，不按服务名命名**。一台机器上可能同时挂多个域名（test 与 prod 迁移、
多站点共用），按服务名命名会互相覆盖，且 `deploy.sh` 判断"该环境有没有证书"时也无从对齐。

**supervisord 程序配置的后缀不是固定的 `.conf`，由主机主配置的 `[include] files=` 决定**：
apt 安装默认 include `/etc/supervisor/conf.d/*.conf`，但在跑的主机常被改成只 include `*.ini`。
写错后缀的文件 supervisord 根本不加载，`reread`/`update` 也不报错——服务继续按上一份定义运行，
属于"改了配置不生效且没有任何提示"那类故障（见第八节故障案例 2）。规则：

- 部署脚本必须现问 `$SUPERVISOR_CONF` 的 `[include]` 模式来决定后缀（参照实现
  `detect_supervisor_suffix()`），并可被 `SUPERVISOR_CONF_SUFFIX` 显式覆盖
- 一台主机上同一 program 只允许有一个后缀文件；发现另一后缀的同名文件要告警并给出删除命令，
  不能留着让人对着不被加载的那份排障
- 手工接入的服务同理：先看这台机 include 的是什么后缀，再决定文件名

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

1. **启动/重启 supervisord daemon 前，必须先看一遍 `/etc/supervisor/conf.d/` 下被 include 的那些文件（`*.conf` 或 `*.ini`，以主配置 `[include]` 为准）里的每个程序对应的进程是否已经在跑**（`ps aux` 按 jar 路径核对）。如果某个配置里的程序其实是靠别的方式（手动、别的启动脚本）已经在运行的"影子进程"，supervisord 一启动就会尝试再启动一份，轻则端口冲突启动失败，重则（`autorestart=true`）陷入反复重启的 crash loop，白白消耗资源、刷爆日志

2. **`nginx -s reload` 影响的是全局 nginx 进程**，会重新加载所有项目的 vhost 配置。虽然不会中断现有连接，但如果别的项目的配置本身有问题，这次 reload 可能把那个问题暴露出来。操作前用 `nginx -t` 先过一遍语法检查，但语法对不代表所有项目的行为都不受影响

3. **禁止在没有明确授权的情况下 `stop`/`remove`/修改不属于本项目的 supervisord 程序或 nginx vhost**。发现别的项目的程序状态异常（`EXITED`/`FATAL`/crash loop）时，**先报告现象、说明是否是本次操作引发的，再询问如何处理**，不要自己判断"看起来没事"就动手清理

4. **只删除/修改 `/etc/supervisor/conf.d/` 下与本项目相关的程序配置文件**（后缀按第一节规则，`.conf` 或 `.ini`），即使看到其他明显失效的配置（如指向已被别的进程占用同一端口的重复配置），也只在该配置所属项目的人明确要求时才处理，处理前确认清楚该配置对应的服务是否有其他形式的存活实例，避免误删还在被使用的配置

5. **"完整执行"和"只做自己那部分"要分开设计**——部署脚本必须能只动自己那一份配置，不要一把全上。
   `/new-java-project`、`/new-deploy` 生成的 `deploy.sh` 的落地方式：常规后端部署**只同步本站点**
   的 `/etc/nginx/conf.d/<service-name>.conf`（拷文件 → `nginx -t` 通过才 reload），nginx 未安装时
   跳过并记日志；安装 nginx 本体与主配置是独立的 `--target ssl` 动作，不会跟着常规部署发生

---

## 四、部署日志规范

部署脚本在共享主机上运行，排查问题时经常需要把多个项目的部署日志放在一起对时间线——日志格式不统一会让这件事变得很麻烦。所有项目的部署脚本统一遵循以下格式：

1. **每个部署步骤（模块）开始前打印一个日志头**，日志头必须包含**执行时间**（本地时间，精确到秒）和**模块名称**
2. **模块之间用一个空行分隔**，不要让不同模块的输出无缝粘在一起，也不要每行都留空行
3. 日志头格式统一为：

   ```
   [YYYY-MM-DD HH:MM:SS] [<脚本名>] <消息>
   ```

   阶段（模块）头额外带序号，便于对着时间线判断"卡在第几步"：

   ```
   [YYYY-MM-DD HH:MM:SS] [<脚本名>] ========== Phase <N>/<总步数>: <模块名> ==========
   ```

4. 模块内部的具体命令输出、警告信息紧跟在日志头下面，不额外加格式
5. 脚本结尾输出一行机器可读状态 `[STATUS] OK - <结论>` 或 `[STATUS] ERROR - <原因>`，
   供 CI 与 agent 直接判定结果，不需要去猜最后一段人话

**示例**：

```
[2026-09-22 18:02:15] [deploy.sh] ========== Phase 1/5: Maven 构建 ==========
[2026-09-22 18:02:41] [deploy.sh] ========== Phase 2/5: 部署 JAR → /opt/soft/apps/myservice ==========
[2026-09-22 18:02:41] [deploy.sh] 已部署 JAR: myservice -> /opt/soft/apps/myservice/myservice-1.4.2.jar

[2026-09-22 18:03:12] [deploy.sh] 部署完成
[STATUS] OK - 微服务已部署：myservice
```

各项目部署脚本里做日志打印的辅助函数（`log()` / `log_step()` / `fail()`）都应该实现这个格式，不要各自发明一套。由 `/new-deploy`、`/new-java-project` 生成的 `deploy.sh` 里的这三个函数是这个约定的参照实现，可以直接抄。

---

## 五、部署前检查清单模板

```bash
supervisorctl status                                   # supervisord daemon 是否在跑，别的程序状态是否正常
ls /opt/soft/apps/<service-name>/.env                   # .env 是否已准备好
ss -tln | grep -E ':(<port1>|<port2>)\b'                # 目标端口是否空闲（应为空输出）
nginx -t                                               # nginx 配置当前是否健康（部署前的基线状态）
```

`nginx -t` 是部署前的**基线**：先确认现在是通过的，出问题才知道是不是自己引入的。
源码安装的 nginx（`/opt/soft/nginx/sbin/nginx`）换成对应绝对路径即可。

四项全部确认后再执行具体项目的部署脚本。

---

## 六、服务启动健康检查（强制）

部署脚本在（重）启动服务进程后，**不能假设"进程存在=服务已就绪"**就直接往下走（比如接着去装/重载共享的 nginx 配置）。进程起来了不代表服务真的能处理请求——启动期的结构迁移（Flyway 逐个执行 `db/migration/V*.sql`）、连接池初始化、缓存预热都需要时间，这段时间里如果就去接流量或者对外宣布"部署成功"，故障会在生产流量打进来的那一刻才暴露。

**规则**：

1. 每个服务必须提供一个健康检查端点，**统一路径格式为 `/api/<service-name>/health`**（如 myservice 对应 `/api/myservice/health`）——这是本机所有项目共同遵守的规范，不是各项目自选路径。实现方式两种都可以：写一个只返回 `{status, service}` 的控制器（参照实现采用这种，见 `config/RootController.java`），或用 Actuator 的 `management.endpoints.web.base-path=/api/<service-name>`。含依赖连通性（数据库、磁盘）的深检留在 Actuator 默认 `/actuator/health`，只对本机开放、`show-details=never`

2. 服务对外 API 统一走服务名前缀路径 `/<service-name>/api/`（nginx 剥离前缀后转发到应用内 `/api/`），健康检查经 nginx 即 `/<service-name>/api/health`，可直接用于探活与联调

3. 部署脚本在启动/重启进程后，必须轮询这个端点，**最长等待 420 秒**（应用冷启动含结构迁移与连接池初始化，60 秒对稍大的工程就不够），检测成功后才能继续执行后续步骤（同步/重载 nginx、打印"部署成功"）

4. 420 秒内轮询不到成功，视为**部署失败**，中止脚本（非零退出码），不继续任何后续步骤，并把 `supervisorctl status` 与日志尾部打出来提示去哪里排查——不能静默继续或者只打个警告就往下走

5. 轮询间隔不要太短（避免刷日志）也不要太长（避免明明 2 秒就好了却等了 10 秒），参照实现取 5 秒

6. **`supervisorctl restart`/`start` 本身会阻塞到 supervisord 配置里的 `startsecs` 结束才返回**——`startsecs` 只用来判定"进程有没有立即崩溃"，必须**远小于**应用真实启动耗时（参照实现取 10 秒），把"应用是否真正就绪"完全交给健康检查去判断。如果 `startsecs` 设得接近或超过真实启动耗时，健康检查会在这段阻塞等够之后才开始探测，第一次探测就通过，日志里的"耗时 N 秒"永远趋近 0——这不是健康检查没生效，是两层等待互相掩盖了，真实启动时间从日志里看不出来

**参照实现**：由 `/new-deploy`、`/new-java-project` 生成的 `deploy.sh` 里的 `wait_service_ready()` / `remote_wait_service_ready()` 函数（`SERVICE_READY_TIMEOUT` 可覆盖 420 秒默认值）；supervisord 配置中 `startsecs=10`。

---

## 七、回滚与停止模板

```bash
# 停止服务（不删除部署文件，可随时重启）
supervisorctl stop <service-name>

# 回滚版本：JAR 按 <service-name>-<版本>.jar 版本化落盘，稳定入口是 <service-name>.jar 软链，
# 回滚只要把软链指回上一个文件再重启，不需要重新构建
ls -1 /opt/soft/apps/<service-name>/<service-name>-*.jar
ln -sfn <service-name>-<旧版本>.jar /opt/soft/apps/<service-name>/<service-name>.jar
supervisorctl restart <service-name>

# 完全移除（谨慎，仅在确定不再需要时执行）
supervisorctl stop <service-name>
rm /etc/supervisor/conf.d/<service-name>.<后缀>     # 后缀按第一节规则（.conf 或 .ini）
supervisorctl reread && supervisorctl update
rm /etc/nginx/conf.d/<service-name>.conf               # 如果部署时装过站点配置
nginx -t && nginx -s reload
```

`<service-name>.jar` 软链由部署脚本每次更新指向，回滚利用它就不动脚本与 supervisord 配置；
这也是版本化落盘（而非覆盖同名 JAR）的目的：**保留历史版本，让回滚是一次 ln 而不是一次重建**。

---

## 八、故障案例

### 故障案例 1：启动 supervisord daemon 引发影子进程冲突

记录一次首次部署时在共享主机上遇到的真实故障，作为第三节规则 1 的具体依据——**这是主机历史遗留状态的普遍风险，不是某个项目自己的问题**，后续任何项目部署时都可能重新踩到，放在通用规范里。

**现象**：主机的 supervisord daemon 原本处于停止状态（`inactive (dead)`），`/etc/supervisor/conf.d/` 下已经存在其他项目的 `agents.ini`、`knowledge.ini`（`autostart=true`、`autorestart=true`；这台机 include 的就是 `*.ini`）。这两个服务的真实运行实例其实是通过别的方式手动启动的独立 java 进程，一直稳定运行，从未被 supervisord 管理过。

**触发**：为了让新服务能被 supervisord 管理，执行了 `systemctl start supervisor`。supervisord 启动后按配置尝试启动 `agents`/`knowledge`，与已经占用相同端口的独立进程冲突，新实例启动失败后因 `autorestart=true` 反复重启，陷入 crash loop（不断产生新 PID、消耗 CPU、刷日志），但**原有的独立进程本身没有被打断**。

**处理**：确认原有独立进程未受影响后，执行 `supervisorctl stop <service-a> <service-b>` 止住了 crash loop，未删除其 `.ini` 配置（保留给对应项目自行决定后续处理）。

**结论**：在这类"部分服务由 supervisord 管理、部分服务独立运行"的混合主机上，**任何一次 supervisord daemon 的启动/重启都可能触发未被管理的影子进程与配置冲突**。这条经验对所有后续在这台主机上部署的项目都适用。

### 故障案例 2：程序配置后缀与主机 include 模式不符，部署静默失效

**现象**：一台 `include files = /etc/supervisor/conf.d/*.ini` 的主机上，部署脚本按 apt 默认写法
生成 `<service>.conf`。`supervisorctl status` 里程序正常 RUNNING，健康检查也通过——因为服务确实是
起来了，只是起的是**上一份 `.ini`** 定义（mtime 停在两个月前），脚本这次写入的 `.conf` 从未被加载。

**为什么难发现**：`reread`/`update` 对不在 include 范围内的文件不报错、不提示，命令一律返回成功；
只要 program 名、jar 路径、日志路径这些字段没变化，两份文件内容一致，运行结果也一致，
故障要等到第一次真正改动 JVM 路径、日志轮转或 `startsecs` 才暴露——而那时没人会怀疑到后缀。
新建服务反而暴露得快：`.conf` 不被加载 → program 不存在 → `supervisorctl restart` 报
`no such program`。

**处理**：把 `.conf` 内容落到 `.ini`（与主机 include 一致）后 `reread`+`update` 生效，
删掉不被加载的 `.conf` 避免后续排查走错文件。

**结论**：后缀不是风格问题，是"这台机的 supervisord 到底读哪些文件"的事实。部署脚本必须
现问主配置决定（见第一节），并在发现另一后缀同名文件时告警。

---

## 九、配置与日志安全约定（强制）

这几条是跨项目统一的，不是各项目自选风格——共享主机上排查问题时要横向对比多个项目的配置与日志，
口径不一致会让"看一眼就知道"变成"每个项目重新学一遍"。

1. **被版本控制跟踪的文件里不出现任何真实凭证**。`application*.yml`、nginx 配置、脚本本体
   一律 `${环境变量:空默认}`；真值只存在于目标机器的 `/opt/soft/apps/<service-name>/.env`。
   占位符写 `changeme` 这类明显假值，不要写看起来像真密钥的字符串

2. **每个服务三套环境文件（`.env` / `.env.test` / `.env.prod`）键集必须完全一致**，只改值不改键。
   环境模板缺键的后果不是启动报错，而是**静默失效**——跨服务调用令牌、开关类配置最容易这样丢，
   故障会在链路中间才暴露。部署脚本必须比对键集并打警告（参照实现 `check_env_keyset()`）

3. **令牌不进日志**。访问日志里的 `Authorization` 经 `map` 脱敏，只记 `Bearer` 前 8 位
   （够前缀关联排查，完整令牌不落进一堆人可读、可备份外流的文件）。参照实现见
   `deploy-conf/nginx/<service-name>.dev.conf` 文件头的 `map $http_authorization`

4. **跨域在 nginx 层用白名单处理，后端不参与**。`map $http_origin` 命中才回带
   `Access-Control-Allow-Origin`；用 `*` 等于允许任意站点带着凭据跨域调用。
   来源没命中就一个头都不回，而不是回 `*`

5. **反向代理的超时必须"大于后端超时、小于客户端超时"**。nginx 默认 `proxy_read_timeout` 是 60 秒，
   比后端调用大模型/第三方接口的超时更短时，会由网关先出 504，客户端拿到的是网关错误页而不是
   后端可解析的业务错误码，前端无法区分"服务挂了"和"这次没算出来"。这类长耗时路由单独开
   `location` 放宽超时，不要在通用 `/api/` 上全局放大

6. **静态资源缓存分两类**：带内容哈希的构建产物（如 `_next/static/`）给
   `max-age=31536000, immutable`；HTML 入口给 `no-cache`。入口页长期缓存会导致发版后旧 HTML
   引用的 chunk 已被删除，页面白屏且刷不回来

7. **应用进程只绑 `127.0.0.1`**（`server.address`），对外一律经 nginx。直接绑 `0.0.0.0`
   等于把应用端口暴露在公网，绕过 nginx 层的鉴权、限流、日志与 CORS 口径
