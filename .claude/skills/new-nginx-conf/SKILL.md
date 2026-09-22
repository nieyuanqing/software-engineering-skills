---
name: new-nginx-conf
description: 生成标准、通用的 nginx 主机级基础配置（nginx.conf + subconf/ + upstream/ + cert/ + html 错误页），合并进 deploy-conf/nginx/ 目录，与 /new-java-project 生成的 <service>.{dev,test,prod}.conf 站点配置共存于同一目录。当用户要求"生成 nginx 配置"、"初始化 nginx 主配置"、"新建 nginx-conf"时触发。支持 /new-nginx-conf -h 查看帮助。
---

# new-nginx-conf

在**当前目录**下的 `deploy-conf/nginx/` 生成一份标准、通用、可直接作为共享主机 nginx 安装基座的
主机级基础配置。内容来自本 skill 目录下的 `templates/deploy-conf/nginx/`（随 skill 一起分发，
不依赖任何仓库克隆或本地工程），提炼自一台生产主机的 `/opt/soft/nginx/conf`。

**触发条件**：用户要求生成 nginx 配置、初始化 nginx 主配置、新建 `nginx-conf`。

**与 `/new-java-project` 的关系**：两个 skill 共同拥有 `deploy-conf/nginx/` 这一棵目录树，
**靠文件名区分归属**（不再是子目录），各自只处理自己负责的文件，互不覆盖：
- `/new-nginx-conf`（本 skill）生成**这台主机的 nginx 本身**——`nginx.conf`、`mime.types`、
  `subconf/`、`upstream/`、`cert/README.md`、`html/` 错误页，以及 `vhosts/README.md`。
  一台主机通常只需要执行一次。
- `/new-java-project` 生成**单个站点**的配置，扁平放在同一目录下：
  `deploy-conf/nginx/<service-name>.{dev,test,prod}.conf`。每接入一个新服务执行一次。
  部署时由 `scripts/deploy.sh` 按 `--env` 选一份装到主机的 `$NGINX_CONF_DIR/<service-name>.conf`
  （默认 `/etc/nginx/conf.d/`，apt 安装的 nginx 默认 include 这里）。

本 skill 模板里的 `vhosts/` 是给**源码安装 nginx**（`/opt/soft/nginx`）的 include 目标目录，
不是仓库里站点配置的存放处：那种主机上把 `deploy.sh` 的 `NGINX_CONF_DIR` 指到
`/opt/soft/nginx/conf/vhosts` 即可复用同一套站点配置。

先执行 `/new-nginx-conf` 搭好主机级基座，再对每个服务执行 `/new-java-project`。
目标目录里已有 `<service-name>.*.conf` 站点配置时，本 skill 只补齐/覆盖自己负责的文件。

---

## 零、参数处理

**如果用户传入 `-h` 或 `--help`**，不执行任何文件操作，直接把下面的帮助信息**原样输出在本次回复正文里**后结束（斜杠命令把 SKILL.md 注入我的上下文不等于已展示给用户，正文里只回一句"已输出"就是没输出）。`-h` 与其它参数或说明文字同时出现时，一律**只出帮助、忽略其余参数**：本轮不猜附加要求，需要同时执行就把 `-h` 去掉分两次调用：

---

```
用法: /new-nginx-conf [-h]

功能
  在当前目录的 deploy-conf/nginx/ 下生成标准、通用的 nginx 主机级基础配置，内容取自
  本 skill 目录下的 templates/deploy-conf/nginx/。
  与 /new-java-project 生成的 deploy-conf/nginx/<service>.*.conf 站点配置共存于同一目录，
  两个 skill 分别只处理各自负责的文件（靠文件名区分，不靠子目录）。

生成产物（均在 ./deploy-conf/nginx/ 下）
  nginx.conf                主配置（worker/事件/http 层通用参数 + include 链）
  mime.types                标准 MIME 类型表
  subconf/global.conf       扩展点（第三方模块指令占位，默认全部注释）
  subconf/log.conf          标准公参访问日志格式（request_id/XFF/请求细节/设备 id/userid 请求头，Token/Authorization 经 map 脱敏）
  subconf/ssl.conf          通用 SSL 参数（ciphers/协议/session 缓存，证书路径为占位符 <DOMAIN>）
  subconf/cross_domain.conf 通用 CORS 片段
  subconf/geo.conf          IP 名单扩展点（默认空白名单）
  subconf/error_pages.conf  统一错误页映射（404/405/500/502/503/504）
  upstream/upstream.conf    upstream 扩展点（默认空，按需声明负载均衡组）
  vhosts/README.md          源码安装 nginx 时的 include 目标目录说明（站点配置本身由
                             /new-java-project 生成在上一级目录，本 skill 不在这里生成配置）
  cert/README.md            说明 SSL 证书应放在这里（不纳入版本管理）
  html/{404,405,500,502,503,504}.html  通用错误页

示例
  /new-nginx-conf       在当前目录生成 deploy-conf/nginx/
  /new-nginx-conf -h    显示本帮助（出现即忽略其它参数，只出帮助）

注意
  - 如当前目录已存在 deploy-conf/nginx/，会展示将被覆盖的文件列表并询问是否继续，不会静默覆盖，
    且绝不触碰上一级目录里 /new-java-project 生成的 <service>.*.conf 站点配置
  - 域名、证书、业务专属请求头等需按目标主机实际情况在站点配置与 cert/ 下补充具体项目配置
  - 本 skill 只生成配置文件，不会自动安装 nginx、不会执行 nginx -t / nginx -s reload
```

---

## 一、确认生成位置

生成目标固定为**当前工作目录**下的 `deploy-conf/nginx/`（路径固定，不提供改名参数——与
`/new-java-project` 共用同一棵目录树，保持跨项目的一致性）。

## 二、冲突检查

如果当前目录已存在 `deploy-conf/nginx/`：
1. 列出模板中本 skill 负责的每个文件（见下方清单）与现有对应文件的差异
   （`diff`，不存在则视为新增）。`<service>.*.conf` 站点配置不属于本 skill，不比对、不覆盖。
2. 汇总展示后询问用户是否继续生成（覆盖有差异的文件，新增缺失的文件）。
3. 用户确认前不做任何写入。
4. 全程不触碰 `deploy-conf/nginx/` 下形如 `<service>.dev|test|prod.conf` 的站点配置文件
   （除本 skill 自己负责的 `nginx.conf` 等之外）——那些属于 `/new-java-project` 的产物。

如果不存在，直接生成，无需确认。

## 三、生成文件清单

将**本 skill 目录**下的 `templates/deploy-conf/nginx/` 目录树整树复制到当前目录下的
`deploy-conf/nginx/`。本副本**不含** `service.dev.conf`、`service.test.conf`、`service.prod.conf`
这三个站点配置模板——它们属于 `/new-java-project`，只在执行该 skill 时按服务名渲染复制到
`deploy-conf/nginx/` 下，不随本 skill 分发。不做占位符替换：

```
deploy-conf/nginx/
├── nginx.conf
├── mime.types
├── subconf/
│   ├── global.conf
│   ├── log.conf
│   ├── ssl.conf
│   ├── cross_domain.conf
│   ├── geo.conf
│   └── error_pages.conf
├── upstream/
│   └── upstream.conf
├── vhosts/
│   └── README.md                  # 源码安装 nginx 的 include 目标；站点配置在上一级目录
├── cert/
│   └── README.md
└── html/
    ├── 404.html
    ├── 405.html
    ├── 500.html
    ├── 502.html
    ├── 503.html
    └── 504.html
```

## 四、生成后处理

1. 提示用户：站点配置需要为具体服务执行 `/new-java-project` 生成（落在 `deploy-conf/nginx/`
   下的 `<service>.*.conf`）；`cert/` 目录只有说明文档，需要补充 SSL 证书（可用 `/new-deploy`
   或 `/new-java-project` 生成的 `scripts/apply-ssl.sh` 申请，证书按域名命名）。
2. 提示用户：如果这台主机计划把 `deploy-conf/nginx/` 安装为实际生效的 nginx 配置目录，需要自行
   确认安装路径（约定为 `/opt/soft/nginx/conf`，见本 skill 目录下 `specs/deployment-common.md`
   第一节），本 skill 不会自动执行安装、`nginx -t`、`nginx -s reload`。
3. **不要**自动执行任何 `nginx -s reload` 或覆盖 `/opt/soft/nginx/conf` 下的现有文件——那是全局共享
   基础设施，涉及安装/重载必须由用户在确认目标主机状态后自己执行（见本 skill 目录下
   `specs/deployment-common.md` 第三节共享基础设施操作规范）。

## 五、完成提示

生成完成后，向用户输出：
1. 已生成/覆盖的文件列表（逐行列出路径）。
2. 下一步操作提示：
   ```
   ## 下一步操作

   1. 为具体服务生成站点配置：/new-java-project <service-name> ...
      生成结果落在 deploy-conf/nginx/<service-name>.{dev,test,prod}.conf；
      部署时由 scripts/deploy.sh 装到 $NGINX_CONF_DIR/<service-name>.conf
      （apt nginx 用默认 /etc/nginx/conf.d；源码安装 nginx 把 NGINX_CONF_DIR
      指到 /opt/soft/nginx/conf/vhosts，即本 skill 的 include vhosts/*.conf）
   2. 准备 SSL 证书：放进 deploy-conf/nginx/cert/，或用 /new-deploy、/new-java-project
      生成的 scripts/apply-ssl.sh 申请
   3. 确认目标主机上的安装路径与本机现有 nginx 配置的关系后再决定是否覆盖安装
   ```

---

## 六、注意事项

- **不要修改本 skill 目录下 `templates/deploy-conf/nginx/`** 中的模板内容作为本次
  任务的副产品——如果模板本身需要更新，那是独立的一次修改（并同步更新本 skill 文件的说明），
  不要在给某个目标工程生成配置的过程中顺带改模板。
- 生成的文件如果目标路径已存在且有差异，**先展示差异，询问用户是否覆盖**，不要直接覆盖。
- `cert/` 目录不预置任何证书，`vhosts/` 目录不预置任何具体站点的配置——两者都只有说明文档，
  避免把某次生成时机器上偶然存在的证书或 vhost 误当作"通用模板"打包进去。
- **绝不生成或覆盖 `deploy-conf/nginx/<service-name>.*.conf`**——这些站点配置文件完全属于
  `/new-java-project`；本 skill 的模板副本中不含任何站点服务模板，目标工程里已有的站点配置
  也一律不触碰。
