---
name: new-nginx-conf
description: 生成标准、通用的 nginx 主机级基础配置（nginx.conf + subconf/ + upstream/ + cert/ + html 错误页），合并进 deploy-conf/nginx/ 目录，与 /new-java-project 生成的 vhosts/ 服务配置共存，去除任何与具体项目相关的定制内容（域名、证书、专属请求头、专属 API 门户页等）。当用户要求"生成 nginx 配置"、"初始化 nginx 主配置"、"新建 nginx-conf"时触发。支持 /new-nginx-conf -h 查看帮助。
---

# new-nginx-conf

在**当前目录**下的 `deploy-conf/nginx/` 生成一份标准、通用、可直接作为共享主机 nginx 安装基座的
主机级基础配置。内容来自 `software-engineering-skills` 仓库的 `templates/deploy-conf/nginx/`——
这份模板本身是从一台已在生产环境跑过的主机的 `/opt/soft/nginx/conf` 提炼而来，**已经剔除了该主机
上所有具体项目的定制内容**（项目域名、证书私钥、专属业务请求头、专属 API 门户页面等），只保留跨
项目通用、可复用的部分。

**触发条件**：用户要求生成 nginx 配置、初始化 nginx 主配置、新建 `nginx-conf`。

**与 `/new-java-project` 的关系**：两个 skill 共同拥有 `deploy-conf/nginx/` 这一棵目录树，但各自
只处理自己负责的文件，互不覆盖：
- `/new-nginx-conf`（本 skill）生成**这台主机的 nginx 本身**——`nginx.conf`、`mime.types`、
  `subconf/`、`upstream/`、`cert/README.md`、`html/` 错误页，以及 `vhosts/README.md`。
  一台主机通常只需要执行一次。
- `/new-java-project` 生成**单个服务**的 vhost 片段
  （`deploy-conf/nginx/vhosts/<service-name>.{dev,test,prod}.conf`），放进 `vhosts/` 目录里，
  由 `nginx.conf` 的 `include vhosts/*.conf;` 自动生效。每接入一个新服务执行一次。

先执行 `/new-nginx-conf` 搭好主机级基座，再对每个服务执行 `/new-java-project`。若 `vhosts/` 下
已经有 `/new-java-project` 生成的服务配置，本 skill 只补齐/覆盖自己负责的文件，不会触碰
`vhosts/<service-name>.*.conf`。

---

## 零、参数处理

**如果用户传入 `-h` 或 `--help`**，不执行任何文件操作，直接输出以下帮助信息后结束：

---

```
用法: /new-nginx-conf [-h]

功能
  在当前目录的 deploy-conf/nginx/ 下生成标准、通用的 nginx 主机级基础配置，内容取自
  software-engineering-skills/templates/deploy-conf/nginx/，不含任何具体项目的定制信息。
  与 /new-java-project 生成的 deploy-conf/nginx/vhosts/<service>.*.conf 共存于同一目录树，
  两个 skill 分别只处理各自负责的文件。

生成产物（均在 ./deploy-conf/nginx/ 下）
  nginx.conf                主配置（worker/事件/http 层通用参数 + include 链）
  mime.types                标准 MIME 类型表
  subconf/global.conf       扩展点（第三方模块指令占位，默认全部注释）
  subconf/log.conf          标准公参访问日志格式（request_id/XFF/请求细节/设备 id/userid 请求头，Token/Authorization 经 map 脱敏）
  subconf/ssl.conf          通用 SSL 参数（ciphers/协议/session 缓存，证书路径为占位符 <DOMAIN>）
  subconf/cross_domain.conf 通用 CORS 片段（不含项目专属请求头）
  subconf/geo.conf          IP 名单扩展点（默认空白名单）
  subconf/error_pages.conf  统一错误页映射（404/405/500/502/503/504）
  upstream/upstream.conf    upstream 扩展点（默认空，按需声明负载均衡组）
  vhosts/README.md          说明各服务 vhost 配置放在这里（内容由 /new-java-project 生成，
                             本 skill 不生成、不覆盖 vhosts/<service>.*.conf）
  cert/README.md            说明 SSL 证书应放在这里（不纳入版本管理）
  html/{404,405,500,502,503,504}.html  通用错误页（无项目品牌信息）

示例
  /new-nginx-conf       在当前目录生成 deploy-conf/nginx/
  /new-nginx-conf -h    显示本帮助

注意
  - 如当前目录已存在 deploy-conf/nginx/，会展示将被覆盖的文件列表并询问是否继续，不会静默覆盖，
    且绝不触碰 vhosts/ 下 /new-java-project 生成的 <service>.*.conf 服务配置
  - 生成的内容不含任何真实域名、证书私钥、业务专属请求头，需要按目标主机实际情况在
    vhosts/、cert/ 下补充具体项目配置
  - 本 skill 只生成配置文件，不会自动安装 nginx、不会执行 nginx -t / nginx -s reload
```

---

## 一、确认生成位置

生成目标固定为**当前工作目录**下的 `deploy-conf/nginx/`（路径固定，不提供改名参数——与
`/new-java-project` 共用同一棵目录树，保持跨项目的一致性）。

## 二、冲突检查

如果当前目录已存在 `deploy-conf/nginx/`：
1. 列出模板中本 skill 负责的每个文件（见下方清单，**不包括** `vhosts/<service>.*.conf`）与现有
   对应文件的差异（`diff`，不存在则视为新增）。
2. 汇总展示后询问用户是否继续生成（覆盖有差异的文件，新增缺失的文件）。
3. 用户确认前不做任何写入。
4. 全程不读取、不列出、不触碰 `vhosts/` 下除 `README.md` 之外的任何文件——那些属于
   `/new-java-project` 的产物。

如果不存在，直接生成，无需确认。

## 三、生成文件清单

将 `software-engineering-skills/templates/deploy-conf/nginx/` 目录树复制到当前目录下的
`deploy-conf/nginx/`，**跳过 `vhosts/service.dev.conf`、`vhosts/service.test.conf`、
`vhosts/service.prod.conf` 这三个文件**（它们是 `/new-java-project` 的原始模板，只在执行该 skill
时按服务名渲染复制，本 skill 不会把这三个模板原样复制进目标工程）。不做占位符替换（本 skill 负责
的部分不含项目专属占位符，是可以直接使用的通用配置）：

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
│   └── README.md                  # 本 skill 生成；<service>.*.conf 由 /new-java-project 生成
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

1. 提示用户：`vhosts/` 目录当前只有说明文档，需要为具体服务执行 `/new-java-project` 生成
   vhost 配置；`cert/` 目录只有说明文档，需要补充 SSL 证书（可用
   `templates/scripts/apply-ssl.sh` 申请）。
2. 提示用户：如果这台主机计划把 `deploy-conf/nginx/` 安装为实际生效的 nginx 配置目录，需要自行
   确认安装路径（约定为 `/opt/soft/nginx/conf`，见 `specs/deployment-common.md` 第一节），本 skill
   不会自动执行安装、`nginx -t`、`nginx -s reload`。
3. **不要**自动执行任何 `nginx -s reload` 或覆盖 `/opt/soft/nginx/conf` 下的现有文件——那是全局共享
   基础设施，涉及安装/重载必须由用户在确认目标主机状态后自己执行（见
   `specs/deployment-common.md` 第三节共享基础设施操作规范）。

## 五、完成提示

生成完成后，向用户输出：
1. 已生成/覆盖的文件列表（逐行列出路径）。
2. 下一步操作提示：
   ```
   ## 下一步操作

   1. 为具体服务生成 vhost 配置：/new-java-project <service-name> ...
      生成结果放进 deploy-conf/nginx/vhosts/ 后即可通过 nginx.conf 的
      include vhosts/*.conf; 自动生效
   2. 准备 SSL 证书：放进 deploy-conf/nginx/cert/，或用 templates/scripts/apply-ssl.sh 申请
   3. 确认目标主机上的安装路径与本机现有 nginx 配置的关系后再决定是否覆盖安装
   ```

---

## 六、注意事项

- **不要修改 `software-engineering-skills/templates/deploy-conf/nginx/`** 中的模板内容作为本次
  任务的副产品——如果模板本身需要更新，那是独立的一次修改（并同步更新本 skill 文件的说明），
  不要在给某个目标工程生成配置的过程中顺带改模板。
- 生成的文件如果目标路径已存在且有差异，**先展示差异，询问用户是否覆盖**，不要直接覆盖。
- `cert/` 目录不预置任何证书，`vhosts/` 目录不预置任何具体服务的配置——两者都只有说明文档，
  避免把某次生成时机器上偶然存在的证书或 vhost 误当作"通用模板"打包进去。
- **绝不生成或覆盖 `vhosts/<service-name>.*.conf`**——这些文件完全属于 `/new-java-project`，
  即使模板目录里存在 `vhosts/service.dev.conf` 等原始模板文件，本 skill 复制目录树时也要跳过它们。
