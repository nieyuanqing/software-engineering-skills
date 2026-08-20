# software-engineering-skills

软件工程 Skill 集合，为 Java/Spring Boot 工程与共享主机 nginx 基础设施提供标准化的配置生成能力。

---

## Skills 列表

| Skill | 说明 |
|:------------------------------------------------------|---|
| [`/new‑java‑project`](#new-java-project) | 为 Java/Spring Boot 工程生成完整的标准化部署配置（deploy.sh、nginx vhost、env、Spring Boot yml、specs 文档） |
| [`/new‑deploy`](#new-deploy) | 单独为已有工程生成或更新 `scripts/deploy.sh` 和 `scripts/apply-ssl.sh` |
| [`/new‑nginx‑conf`](#new-nginx-conf) | 在当前目录生成标准、通用的 nginx 主机级基础配置 `deploy-conf/nginx/` |
| [`/new‑android‑build`](#new-android-build) | 为含 Android 工程的仓库生成 `scripts/android-build.sh` 编译校验脚本 |
| [`/new‑macos‑build`](#new-macos-build) | 为含 iOS 工程的仓库生成 `scripts/macos-build.sh` 构建校验与打包脚本 |
| [`/common‑rules`](#common-rules) | 激活通用行为规范（任务摘要、v0 文档只读保护、禁止硬编码敏感信息） |
| [`/aibug`](#aibug) | 连接 aibug Bug 管理系统，循环自动修复 PENDING 状态的 Bug |
| [`/api‑test`](#api-test) | 全端（web 管理后台 / 小程序 / Android / iOS）扫描后端 API 生成 URL 清单，逐个验证 HTTP 200，非 200 与业务不合理处均定位修复 |
| [`/do‑test`](#do-test) | 测试场景总驱动：调用 /api-test 完成 API 基本功能验证，并执行 test/cases/ 下的场景用例，汇总测试报告 |
| [`/new‑test‑case`](#new-test-case) | 在 test/cases/ 下新增一个测试用例文件（TEST-CASE-{4位递增编号}.md），一次执行生成一个 |

逐个 skill 的详细用法见下方对应章节。

---

## 目录结构

每个 skill 是 `.claude/skills/<name>/` 下的**自包含目录**（SKILL.md + 所需模板/规范副本），安装即整目录复制，与任何本地工程无关。

```
software-engineering-skills/
├── CLAUDE.md                          项目维护规则（自包含布局、共享副本同步、路径禁令）
├── README.md
└── .claude/skills/
    ├── aibug/SKILL.md                 连接 aibug 系统，自动循环修复 Bug
    ├── common-rules/SKILL.md          通用行为规范（任务摘要、v0 文档保护、禁止硬编码）
    ├── api-test/SKILL.md              全端扫描后端 API 生成 URL 清单，逐个验证 HTTP 200 并修复
    ├── do-test/SKILL.md               测试总驱动：API 验证（委托 api-test）+ test/cases/ 场景用例
    ├── new-test-case/SKILL.md         新增单个测试用例 TEST-CASE-{4位编号}.md 到 test/cases/
    ├── new-android-build/             生成 Android 编译校验脚本 android-build.sh
    │   ├── SKILL.md
    │   └── templates/scripts/android-build.sh
    ├── new-macos-build/               生成 iOS 构建校验与打包脚本 macos-build.sh
    │   ├── SKILL.md
    │   └── templates/scripts/macos-build.sh
    ├── new-deploy/                    单独生成/更新 deploy.sh 和 apply-ssl.sh
    │   ├── SKILL.md
    │   └── templates/scripts/
    │       ├── deploy.sh              部署脚本模板（共享副本①，与 new-java-project 保持一致）
    │       └── apply-ssl.sh           SSL 证书申请脚本模板（共享副本①）
    ├── new-nginx-conf/                生成标准通用的 nginx 主机级基础配置
    │   ├── SKILL.md
    │   ├── specs/deployment-common.md 共享主机部署通用规范（共享副本②，与 new-java-project 保持一致）
    │   └── templates/deploy-conf/nginx/   仅主机级文件（不含 vhost 服务模板）：
    │       ├── nginx.conf             主配置（worker/事件/http 层通用参数 + include 链）
    │       ├── mime.types             标准 MIME 类型表
    │       ├── subconf/               global/log/ssl/cross_domain/geo/error_pages 六个通用片段
    │       ├── upstream/upstream.conf upstream 扩展点，默认空
    │       ├── cert/README.md         说明 SSL 证书应放在这里，不纳入版本管理
    │       ├── html/                  通用错误页 404/405/500/502/503/504
    │       └── vhosts/README.md       说明本目录用途（落地一次）
    └── new-java-project/              为 Java/Spring Boot 工程生成完整部署配置
        ├── SKILL.md
        ├── specs/
        │   ├── deployment-common.md   共享主机部署通用规范（共享副本②，目录约定、端口登记、
        │   │                          supervisord/nginx 操作安全规范、健康检查强制规则）
        │   ├── deployment-template.md       项目专属 specs/deployment.md 的填空模板
        │   └── baseline-versions-template.md 项目专属 specs/baseline-versions.md 的填空模板
        └── templates/
            ├── scripts/
            │   ├── deploy.sh          部署脚本模板（共享副本①，与 new-deploy 保持一致）
            │   └── apply-ssl.sh       SSL 证书申请脚本模板（共享副本①）
            ├── deploy-conf/
            │   ├── env.dev/test/prod  环境变量模板三套（含 SPRING_PROFILES_ACTIVE）
            │   └── nginx/vhosts/service.{dev,test,prod}.conf  vhost 模板三套（按服务名渲染）
            └── src/main/resources/
                ├── application.yml    Spring Boot 公共配置（端口、数据源、Actuator 健康检查端点）
                ├── application-dev.yml    dev profile（show-sql=true，DEBUG 日志，Swagger 开启）
                ├── application-test.yml   test profile（INFO 日志，Swagger 开启）
                └── application-prod.yml   prod profile（WARN 日志，Swagger 关闭）
```

> 目标工程里的 `deploy-conf/nginx/` 这棵目录树仍由 `/new-nginx-conf`（主机级文件）与
> `/new-java-project`（vhost 片段）共同拥有，只是模板副本按职责拆分存放在两个 skill 目录中。
> 标注"共享副本"的文件修改任一份必须同步另一份（见 CLAUDE.md）。

---

## 已安装的 Skills

### `/new-java-project`

为 Java/Spring Boot 工程一键生成完整的标准化部署配置。

**用法**

```bash
/new-java-project                          # 交互式向导，以当前目录名为默认服务名
/new-java-project my-service               # 直接指定服务名
/new-java-project my-service \
  --nginx-port=50000 --app-port=50001 \
  --db-port=5432 --db-name=my-service \
  --test-domain=svc.test.example.com \
  --prod-domain=svc.example.com \
  --has-web=false                          # 全参数指定，无需交互
/new-java-project -h                       # 查看帮助
```

**生成产物**

| 文件 | 说明 |
|---|---|
| `scripts/deploy.sh` | 部署脚本（见下方"deploy.sh 能力"） |
| `scripts/apply-ssl.sh` | SSL 证书申请（Let's Encrypt + acme.sh，HTTP-01 webroot 验证） |
| `deploy-conf/nginx/vhosts/<name>.dev.conf` | nginx vhost — dev 环境（HTTP，无域名） |
| `deploy-conf/nginx/vhosts/<name>.test.conf` | nginx vhost — test 环境（HTTPS，绑定测试域名） |
| `deploy-conf/nginx/vhosts/<name>.prod.conf` | nginx vhost — prod 环境（HTTPS，绑定生产域名） |
| `deploy-conf/env.{dev,test,prod}.example` | 环境变量模板三套（含 `SPRING_PROFILES_ACTIVE`，复制为 `.env` 后填入真实值） |
| `src/backend/<name>/src/main/resources/application.yml` | Spring Boot 公共配置（端口、数据源、Actuator 健康检查端点） |
| `src/backend/<name>/src/main/resources/application-{dev,test,prod}.yml` | Spring Boot profile 配置三套（日志级别、SQL 调试、Swagger 开关） |
| `specs/deployment.md` | 本工程专属部署规范文档 |
| `specs/baseline-versions.md` | 基线版本规范（JDK、PostgreSQL、Spring Boot 等） |

**deploy.sh 能力**（见下方 [`/new-deploy`](#new-deploy) 节的详细说明）：
- `-t/--target all|backend|web|ssl`，`-e/--env dev|test|prod`
- `-r/--remote USER@HOST` 远程部署（本地构建，rsync 上传，SSH 重启）
- `--target ssl` 安装 nginx（apt）+ SSL 证书配置
- supervisord 配置在部署时 inline 生成，Spring 环境通过 `.env` 中的 `SPRING_PROFILES_ACTIVE` 传递
- Phase N/M 阶段日志，`[STATUS] OK/ERROR` 机器可读输出，420s 健康检查

**所有产物遵循的通用规范**（见 `specs/deployment-common.md`）：
- 目录约定：`/opt/soft/apps/<name>/`、`/data/logs/apps/<name>/`
- 健康检查端点：`/api/<name>/health`（Spring Boot Actuator，`startsecs=10`，最长等待 420s）
- 部署日志格式：`[YYYY-MM-DD HH:MM:SS] [deploy.sh] ...`，阶段编号：`Phase N/M`
- 共享主机安全规范：不自动 `systemctl start supervisor`，不随意改动其他项目配置

---

### `/new-deploy`

单独为已有工程生成或更新 `scripts/deploy.sh` 和 `scripts/apply-ssl.sh`。适用于只需要更新部署脚本、不需要重新生成完整配置套件的场景。

**用法**

```bash
/new-deploy                                # 交互式，以当前目录名为默认服务名
/new-deploy my-service                     # 直接指定服务名
/new-deploy my-service \
  --app-port=8080 --nginx-port=9090 \
  --test-domain=svc.test.example.com \
  --prod-domain=svc.example.com \
  --has-web=false                          # 全参数指定，无需交互
/new-deploy -h                             # 查看帮助
```

**生成产物**

| 文件 | 说明 |
|---|---|
| `scripts/deploy.sh` | 部署脚本 |
| `scripts/apply-ssl.sh` | SSL 证书申请脚本（deploy.sh 初始化目录时一并上传到服务器） |

**deploy.sh 主要能力**

| 能力 | 说明 |
|---|---|
| `--target all\|backend\|web\|ssl` | 部署目标（`-t` 简写） |
| `--env dev\|test\|prod` | 目标环境（`-e` 简写），默认 `dev` |
| `--remote USER@HOST` | 远程部署（`-r` 简写）：本地 Maven 构建，rsync 上传 JAR，SSH 远程重启 |
| `--target ssl` | 完整 nginx 安装（apt）+ 主配置 + 站点配置；仅支持 `test\|prod` |
| 自动 nginx 同步 | backend 部署后自动同步站点配置并 reload（目标已装 nginx 时） |
| inline supervisord 配置 | 部署时写入 `/etc/supervisor/conf.d/<name>.conf`，不依赖静态 ini 文件 |
| env 文件按环境选择 | 自动选取 `.env` / `.env.test` / `.env.prod`（来自 `src/backend/<name>/`） |
| Phase N/M 日志 | 编号阶段日志，`[STATUS] OK/ERROR` 机器可读输出行 |
| 健康检查 | `http://127.0.0.1:<APP_PORT>/api/<name>/health`，最长等待 420s |
| 版本化 JAR + 软链接 | `<name>-<version>.jar` + `<name>.jar` 软链接，支持手动回滚 |
| 部署摘要 | 自动探测公网 IP，输出三套环境的访问地址和产物位置 |

---

### `/new-nginx-conf`

在当前目录生成标准、通用的 nginx 主机级基础配置到 `deploy-conf/nginx/`，内容随 skill 目录分发
（skill 自带 `templates/deploy-conf/nginx/` 副本），提炼自一台生产主机的 `/opt/soft/nginx/conf`。

`deploy-conf/nginx/` 这棵目录树由 `/new-nginx-conf` 与 `/new-java-project` 共同拥有，但各自只处理
自己负责的文件：`/new-nginx-conf` 生成主机级的 nginx 本身（`nginx.conf`、`subconf/`、`upstream/`、
`cert/README.md`、`html/`、`vhosts/README.md`），一台主机通常只需要执行一次；`/new-java-project`
生成单个服务的 vhost 片段（`vhosts/<name>.{dev,test,prod}.conf`），每接入一个新服务执行一次。两者
互不覆盖对方的产物。

**用法**

```bash
/new-nginx-conf       # 在当前目录生成 deploy-conf/nginx/
/new-nginx-conf -h    # 查看帮助
```

**生成产物**

| 文件 | 说明 |
|---|---|
| `deploy-conf/nginx/nginx.conf` | 主配置（worker/事件/http 层通用参数 + include 链） |
| `deploy-conf/nginx/mime.types` | 标准 MIME 类型表 |
| `deploy-conf/nginx/subconf/log.conf` | 标准公参访问日志格式（request_id/XFF/请求细节/设备 id/userid 请求头，Token/Authorization 经 map 脱敏） |
| `deploy-conf/nginx/subconf/ssl.conf` | 通用 SSL 参数（ciphers/协议/session 缓存），证书路径为占位符 `<DOMAIN>` |
| `deploy-conf/nginx/subconf/cross_domain.conf` | 通用 CORS 片段 |
| `deploy-conf/nginx/subconf/{global,geo,error_pages}.conf` | 扩展点 / IP 名单 / 统一错误页映射 |
| `deploy-conf/nginx/upstream/upstream.conf` | upstream 扩展点（默认空，按需声明负载均衡组） |
| `deploy-conf/nginx/vhosts/README.md` | 说明各服务 vhost 配置放在这里（`<name>.*.conf` 由 `/new-java-project` 生成） |
| `deploy-conf/nginx/cert/README.md` | 说明 SSL 证书应放在这里（不纳入版本管理） |
| `deploy-conf/nginx/html/{404,405,500,502,503,504}.html` | 通用错误页 |

**注意**：本 skill 只生成配置文件，不会自动安装 nginx、不会执行 `nginx -t` / `nginx -s reload`——
是否覆盖主机上现有的 `/opt/soft/nginx/conf` 需要用户自行确认后操作（见
`specs/deployment-common.md` 第三节共享基础设施操作规范）。

---

### `/new-android-build`

为含 Android 工程的仓库生成 `scripts/android-build.sh`——Android 编译校验脚本。脚本内容随 skill
目录分发（skill 自带 `templates/scripts/android-build.sh` 副本，工程路径按标准约定 `src/android/`
推导，SDK 与签名凭据走环境变量），直接原样复制、无需传参。

**定位**：只管"本机改完代码后编译能不能过"，不签名、不产出可安装 APK；正式打包/签名/产物分发
由工程自己的发布流程负责。

**用法**

```bash
/new-android-build       # 在当前工程生成 scripts/android-build.sh
/new-android-build -h    # 查看帮助
```

**android-build.sh 主要能力**

| 能力 | 说明 |
|---|---|
| 默认 task | `compileDebugKotlin`（只编译校验），`-t/--task` 可指定其他 task（如 `assembleDebug`） |
| SDK 定位 | 优先 `src/android/local.properties` 的 `sdk.dir`（本机配置，不提交版本库），其次 `ANDROID_HOME` |
| gradle | 优先 `src/android/gradlew`，回退系统 `gradle` |
| 签名校验 | task 含 release 时提前校验 `ANDROID_KEYSTORE_PATH` / `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD` |
| 日志与状态 | 构建日志落盘 `runtime/build-android-<时间戳>.log`，失败摘最后 120 行；`[STATUS] SUCCESS/ERROR` 机器可读输出 |

---

### `/new-macos-build`

为含 iOS 工程的仓库生成 `scripts/macos-build.sh`——iOS 构建校验与打包脚本（仅在 macOS + Xcode
环境运行）。脚本内容随 skill 目录分发（skill 自带 `templates/scripts/macos-build.sh` 副本）：
工程自动查找或 `-p` 指定，产物名 / Bundle ID / 版本号全部从 `xcodebuild -showBuildSettings`
动态读取，签名凭据走环境变量，直接原样复制、无需传参。

**用法**

```bash
/new-macos-build       # 在当前工程生成 scripts/macos-build.sh
/new-macos-build -h    # 查看帮助
```

**macos-build.sh 主要能力**

| 能力 | 说明 |
|---|---|
| 编译校验 | `xcodebuild build`，`destination=generic/platform=iOS Simulator`，`CODE_SIGN_IDENTITY="-"`（ad-hoc 签名，无需证书；iOS 17+ 模拟器对未签名 App 的 Keychain 访问会静默失败，ad-hoc 可规避） |
| 工程定位 | `-p/--project` 显式指定；否则当前目录自动查找（优先 `.xcworkspace`，其次 `.xcodeproj`，多个则报错） |
| scheme / 配置 | `-s/--scheme` 指定或读工程第一个 scheme；`-c/--configuration` 默认 Debug，分发包建议 Release |
| 产物归档 | 模拟器 `.app` zip 归档到 `mobile-apps/<产品名>-ios-<配置>-<版本>.zip`（与 Android APK 同目录） |
| `--run` | 安装到可用 iPhone 模拟器并启动（Bundle ID 动态读取，界面验证用） |
| `--ipa` | `archive` + `exportArchive` 打真机 `.ipa`；Team ID 必须显式提供（`-t/--team` 或 `IOS_TEAM_ID`），导出方式走 `IOS_EXPORT_METHOD`；签名账号未就绪时提示并跳过，不视为构建失败 |
| 日志与状态 | 构建日志落盘 `runtime/build-ios-<时间戳>.log`，失败摘 error 行（最多 40 条）；`[STATUS] SUCCESS/ERROR/SKIPPED` 机器可读输出 |

**注意**：生成的脚本只能在 macOS 上运行（脚本内部有 `uname -s` 校验），在 Linux 开发机上生成后
需到 Mac 上执行；`--ipa` 前需在 Xcode → Settings → Accounts 登录对应 Apple 开发者账号。

---

### `/common-rules`

通用行为规范，调用后对当前会话的所有任务生效：

- **任务摘要**：每次任务完成后输出结果清单、影响范围（新增/修改/删除文件）、开始和结束时间
- **v0 文档保护**：工程根目录 `v0/` 下的原始产品设计文档只读，禁止修改（`src/web/v0/` 为 AI 生成代码目录，不受此限制）
- **禁止硬编码**：密码、密钥、Token 等敏感信息必须通过环境变量或占位符处理
- **自动压缩上下文**：上下文窗口使用率达到 70% 时自动执行 `/compact`

**用法**

```bash
/common-rules    # 激活通用规范，对后续所有任务生效
```

---

### `/aibug`

自动连接 aibug Bug 管理系统，循环获取并修复 PENDING 状态的 Bug，直到队列为空。必须配合 aibug 系统使用。

**用法**

```bash
/aibug --host=http://your-server:8082 \
  --username=admin --password=secret \
  --project-id=1                         # 全参数指定，直接开始
/aibug                                   # 交互式，逐一询问参数
/aibug -h                                # 查看帮助
```

**所有参数均为必填，无默认值：**

| 参数 | 说明 |
|---|---|
| `--host` | aibug 系统 Base URL |
| `--username` | 登录账号 |
| `--password` | 登录密码 |
| `--project-id` | 项目 ID |

**工作流程**

1. `POST {host}/aibug/api/auth/login` — 登录获取 token
2. `GET {host}/aibug/api/bugs/next?projectId=N` — 获取下一个 PENDING Bug
3. 标记为 `IN_PROGRESS`，防止重复领取
4. 分析 Bug 描述（`content`）及附件（`fileUrls`），定位并修复代码
5. 修复成功 → `FIXED`；无法修复 → `FAILED`（附失败原因）
6. 循环回到第 2 步，直到队列清空

完成后输出汇总：处理总数、FIXED 数量、FAILED 数量及原因。

---

### `/api-test`

完整扫描工程中所有客户端（web 管理后台、小程序、Android、iOS）代码，静态收集后端 API 调用，
整理成 URL 清单后逐个实际请求验证：HTTP 非 200 的定位前后端原因并修复；200 但返回内容业务层面
明显不合理的也一并修复。产物为 `test/api/url-list.md`（清单）与 `test/api/test-result.md`（结果）。

**用法**

```bash
/api-test                                  # 扫描全部端，自动探测后端地址，检查并修复
/api-test --client=web                     # 只扫描 web 管理后台（可多次传入）
/api-test --base-url=http://localhost:8080/api/mall --allow-write
/api-test --no-fix                         # 只出报告，不改代码
/api-test -h                               # 查看帮助
```

**可选参数**

| 参数 | 说明 |
|---|---|
| `--base-url` | 后端 API 基础地址；不传则自动探测（各端 env / proxy 配置 / nginx vhost / specs） |
| `--client` | 只扫描指定端（web / miniapp / android / ios），可多次传入；不传则扫描实际存在的所有端 |
| `--allow-write` | 允许直接探测 POST/PUT/DELETE 写操作 API（默认逐个询问） |
| `--no-fix` | 只检查并输出报告，不修改代码 |

**工作流程**

1. 前置检查：识别工程中存在的客户端目录、探测后端 base url、健康检查确认后端在线、确认鉴权 token 获取方式
2. 全端扫描：静态收集各端代码调用的后端 API（方法 + 路径 + 参数），写入 `test/api/url-list.md`
3. 逐个验证：curl 实际请求，首先判断 HTTP 响应码是否 200；GET 直接探测，写操作默认需用户确认
4. 诊断修复：非 200 按状态码（404/405/400/401/403/500）先查客户端（路径/方法/参数/鉴权头），再查后端（mapping/参数绑定/安全白名单/异常日志），最小化修复后复验
5. 业务合理性检查：对 200 响应检查返回内容（业务错误码、数据缺失/矛盾、与客户端预期不符），明显不合理的分析并修复
6. 结果输出：汇总写入 `test/api/test-result.md` 并输出中文摘要

---

### `/do-test`

测试场景总驱动：先调用 /api-test 完成所有客户端调用 API 的基本功能验证，
再逐个执行 `test/cases/` 目录下定义的测试场景用例，最终汇总输出 `test/test-report.md`。

**用法**

```bash
/do-test                                   # 完整执行：API 验证 + 全部场景用例
/do-test --skip-api                        # 只跑场景用例
/do-test --case=下单流程                   # 只执行指定场景（可多次传入）
/do-test --no-fix                          # 只出报告，不改代码
/do-test -h                                # 查看帮助
```

**可选参数**

| 参数 | 说明 |
|---|---|
| `--skip-api` | 跳过 API 基本功能验证（/api-test 部分） |
| `--skip-cases` | 跳过 test/cases/ 场景用例验证 |
| `--case` | 只执行指定场景用例（文件名或场景名），可多次传入 |
| `--no-fix` | 只检查并输出报告，不修改代码 |

**工作流程**

1. 前置检查：确认工程结构、扫描 `test/cases/` 用例清单
2. API 验证：调用 /api-test（透传 `--no-fix`、`--base-url`），产出 `test/api/url-list.md` 与 `test/api/test-result.md`
3. 场景验证：按用例定义逐步执行判定，步骤类型 API（curl）/ UI（支持 Playwright 时自动转写执行，否则标记需人工）/ 人工，执行后核对结果验证与善后清理
4. 汇总报告：合并两部分结果写入 `test/test-report.md` 并输出中文摘要

---

### `/new-test-case`

在工程的 `test/cases/` 目录下新增一个测试场景用例文件。一次执行只生成一个文件，
命名 `TEST-CASE-{4位递增编号}.md`（自动取现有最大编号 +1，从 0001 开始），
采用专业用例模板，与 /do-test 的用例格式兼容，生成后可直接被 /do-test 执行。

**用例模板结构**

元信息（编号/测试类型/优先级）→ 前置条件 → 测试数据 → 测试步骤表（每步类型：
`API` 接口请求 / `UI` Playwright 页面操作 / `人工`，含操作、输入参数、预期结果）
→ 结果验证（整体断言）→ 善后清理。

**用法**

```bash
/new-test-case 下单流程：登录后可用商品1创建订单并查询订单详情
/new-test-case                             # 交互询问场景内容后生成
/new-test-case -h                          # 查看帮助
```

**工作流程**

1. 确定 `test/cases/` 目录（不存在则创建）与下一个 4 位编号
2. 收集场景信息：场景名、测试类型与优先级、前置条件、测试数据、步骤、结果验证（命令行已给描述则结合工程代码整理，缺项一次性交互补齐）
3. 按模板写入 `TEST-CASE-NNNN.md` 并输出摘要，提示可用 `/do-test --case=<场景名>` 立即执行

---

## 安装

在 Claude Code、Codex、Qoder 等智能编程助手中，直接把以下内容发给智能体即可完成安装：

```
安装 skill：https://github.com/nieyuanqing/software-engineering-skills.git
```

本机已配置 GitHub SSH key 时（HTTPS 拉取受限或较慢的网络环境推荐），改用 SSH 地址：

```
安装 skill：git@github.com:nieyuanqing/software-engineering-skills.git
```
