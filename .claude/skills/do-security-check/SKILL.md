---
name: do-security-check
description: 全维度安全检测（静态 + 运行时 + 供应链）。静态：智能体源码分析、Semgrep SAST、Trivy SCA 依赖漏洞、密钥泄露、Git 历史密钥、IaC 配置错误、许可证合规、SBOM；运行时：HTTP 安全头、OWASP Top 10 只读探测、JWT/Cookie 检查、TLS/SSL 配置、端口暴露面、Nuclei 模板扫描、OWASP ZAP 被动扫描；供应链：容器镜像扫描。汇总报告 test/security/security-check-report.md，可选 --fix 最小化修复。当用户要求"安全扫描/安全检查"、"SAST/SCA/DAST"、"依赖漏洞"、"密钥泄露"、"OWASP 检查"、"TLS 检查"、"生成 SBOM"时触发。支持 /do-security-check -h 查看帮助。
---

# do-security-check

对工程做全维度安全检测：静态分析、运行时验证、供应链检查，汇总为统一报告。

## 检测维度总览

### 静态（默认全部执行）

| 维度 | --type 值 | 工具 | 说明 |
|---|---|---|---|
| 智能体源码分析 | review | 智能体自身 | 语言无关：审阅鉴权、加解密、输入处理、文件/命令操作，补工具盲区（越权、不安全默认值、业务绕过） |
| SAST 代码缺陷 | sast | Semgrep | 注入、硬编码凭据、不安全加密、路径穿越、反序列化等 |
| SCA 依赖漏洞 | sca | Trivy (vuln) | pom.xml / package-lock.json / go.sum 等比对 CVE 库 |
| 密钥泄露 | secret | Trivy (secret) | 工作区代码与配置中的 AK/SK、token、私钥 |
| Git 历史密钥 | history | Trivy (repo) / gitleaks | 全历史扫描：曾提交过的密钥、敏感文件 |
| IaC / 配置错误 | iac | Trivy (misconfig) | Dockerfile、docker-compose、K8s、Terraform、nginx conf、application*.yml 危险配置 |
| 许可证合规 | license | Trivy (license) | 依赖许可证风险（GPL 传染等） |
| SBOM | sbom | Trivy (sbom) | CycloneDX 软件物料清单 |

### 运行时（需 `--url`，目标必须是用户确认的非生产环境）

| 维度 | --type 值 | 工具 | 说明 |
|---|---|---|---|
| HTTP 安全头 | dast | curl + 智能体 | HSTS/CSP/X-Frame-Options/X-Content-Type-Options/Referrer-Policy、Cookie Secure/HttpOnly/SameSite |
| OWASP Top 10 探测 | dast | curl + 智能体 | A01~A10 只读探测：越权路径、目录穿越、敏感文件暴露（.git/env）、错误信息泄露 |
| JWT / 会话检查 | dast | curl + 智能体 | alg=none/弱密钥、过期策略、token 存放方式 |
| TLS / SSL 配置 | ssl | openssl s_client / testssl.sh | 证书有效期与链、协议版本（禁 TLS<1.2）、弱密码套件、HSTS |
| 端口暴露面 | port | ss / nmap（可选） | 后端监听端口 vs 部署配置登记，未登记的暴露端口告警 |
| 模板漏洞扫描 | nuclei | Nuclei（可选） | 数千个现成漏洞模板快速扫描 |
| Web 被动扫描 | zap | OWASP ZAP（可选） | 被动扫描、AJAX 爬取、头部分析 |

### 供应链（需 `--image`）

| 维度 | --type 值 | 工具 | 说明 |
|---|---|---|---|
| 容器镜像 | image | Trivy (image) | 镜像 OS 包 + 应用依赖 CVE、镜像内密钥与配置错误 |

**触发条件**：用户要求安全扫描/安全检查、漏洞扫描、密钥检查、OWASP/TLS 检查、SBOM，或直接输入 /do-security-check。

**能力边界**（报告中声明）：架构/业务逻辑级漏洞、云与 IAM 配置、物理/社工面、零日漏洞不在自动化覆盖范围，需人工评审或渗透测试。

---

## 零、参数处理

**如果用户传入 `-h` 或 `--help`**，不执行任何操作，直接输出以下帮助信息后结束：

---

```
用法: /do-security-check [选项]

选项（通过命令行传入的参数直接使用，不再交互询问）
  --scope=<路径>      静态扫描范围（默认工程根目录；自动排除
                      .git / node_modules / target / dist / v0 文档目录）
  --type=<维度>       只执行指定维度，可多次传入；取值：
                      review / sast / sca / secret / history / iac / license / sbom
                      dast / ssl / port / nuclei / zap / image / all
                      不传默认：全部静态维度（运行时与镜像需显式 --url / --image）
  --url=<地址>        运行时检测目标（staging/测试环境 URL，自动启用 dast+ssl）
  --image=<名称[:tag]>  容器镜像扫描（自动启用 image 维度）
  --mode=<auto|augmented>
                      auto=仅工具；augmented=工具 + 智能体深度分析，默认 augmented
  --severity=<级别>   报告过滤：CRITICAL,HIGH,MEDIUM,LOW（默认全部展示，
                      CRITICAL/HIGH 置顶高亮）
  --fix               对高置信问题执行最小化修复（默认只出报告）
  -h, --help          显示本帮助

工作流程
  1. 前置检查：第三方工具可用性（缺失给出安装命令，经用户同意后安装）
  2. 静态检测：review/sast/sca/secret/history/iac/license/sbom
  3. 运行时检测（有 --url）：安全头 + OWASP 只读探测 + JWT/Cookie +
     TLS/SSL 配置 + 端口暴露面；nuclei/zap 可用时追加
  4. 供应链检测（有 --image）：镜像 CVE/密钥/配置
  5. 汇总：按 严重级别 × 维度 整理问题清单与修复建议
  6. --fix 时对高置信问题最小化修复并复扫验证
  7. 输出报告 test/security/security-check-report.md 与中文摘要

产物
  test/security/security-check-report.md  检测报告
  test/security/sbom.cdx.json             SBOM（执行 sbom 维度时）

示例
  /do-security-check                                  全量静态检测（augmented 模式）
  /do-security-check --type=sca --type=secret         只查依赖漏洞与密钥
  /do-security-check --url=http://staging.example.com 追加运行时检测
  /do-security-check --image=myapp:latest             追加容器镜像检测
  /do-security-check --mode=auto --fix                仅工具检测并最小化修复
  /do-security-check -h                               显示本帮助

──────────────────── 第三方工具安装与用法 ────────────────────

  semgrep（SAST）
    安装: pip install semgrep          # 或 brew install semgrep
    验证: semgrep --version
    用法: semgrep scan --config auto <路径> --json

  trivy（SCA/密钥/IaC/许可证/SBOM/镜像/Git 历史）
    安装: curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
          # macOS: brew install trivy
    验证: trivy --version
    用法: trivy fs --scanners vuln,secret,misconfig <路径> --format json
          trivy repo --scanners secret <路径>     # Git 历史密钥
          trivy image <镜像名>
          trivy sbom -o sbom.cdx.json <路径>

  gitleaks（Git 历史密钥，trivy repo 的备选）
    安装: brew install gitleaks        # 或 go install github.com/gitleaks/gitleaks/v8@latest
    用法: gitleaks detect --source <路径> --report-format json

  testssl.sh（TLS/SSL 深度检查，可选；缺省用 openssl s_client）
    安装: git clone --depth 1 https://github.com/drwetter/testssl.sh.git
    用法: ./testssl.sh --json <host:port>

  nmap（端口暴露面，可选；缺省用 ss/netstat）
    安装: apt install nmap             # 或 brew install nmap
    用法: nmap -p- --open <host>

  nuclei（运行时模板扫描，可选）
    安装: go install -v github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest
          # 或 brew install nuclei
    验证: nuclei -version
    用法: nuclei -u <URL> -severity critical,high,medium -json

  OWASP ZAP（运行时被动扫描，可选）
    安装: brew install --cask zap      # 或使用容器镜像
    用法: docker run -t ghcr.io/zaproxy/zaproxy:stable zap-baseline.py -t <URL>

──────────────────────────────────────────────────────────────
```

---

## 一、前置检查

1. 确认当前目录为工程根（存在 `src/` 或 `.git`）；确定 `--scope`（默认根目录）。
2. 工具可用性检查（semgrep/trivy/gitleaks/testssl.sh/nmap/nuclei/ZAP 按所选维度检查）：
   - 缺失工具 → 输出帮助中的对应安装命令，经**用户同意后**安装；拒绝则跳过该维度并在报告注明。
3. Semgrep 规则需联网（`--config auto`）；离线时提示受限，不静默跳过。
4. 有 `--url` 时，向用户确认目标确为 staging/测试环境（禁止对生产执行运行时探测）。

## 二、静态检测

统一输出 JSON 便于汇总：

1. **review**（augmented 模式）：审阅鉴权/加解密/输入处理/文件与命令操作等关键模块，产出工具难覆盖的逻辑级问题，标注 `智能体分析`。
2. **sast**：`semgrep scan --config auto --json {SCOPE} > /tmp/sc-sast.json`（非零退出码通常是存在 finding，按 `results` 计数，不当作失败）。
3. **sca**：`trivy fs --scanners vuln --format json {SCOPE}`。
4. **secret**：`trivy fs --scanners secret --format json {SCOPE}`。
5. **history**：`trivy repo --scanners secret {SCOPE}`（或 `gitleaks detect --source {SCOPE} --report-format json`）。
6. **iac**：`trivy fs --scanners misconfig --format json {SCOPE}`；另人工核对 `application*.yml`（debug 开启、明文密码、actuator 全暴露等）。
7. **license**：`trivy fs --scanners license --format json {SCOPE}`。
8. **sbom**：`trivy sbom --format cyclonedx --output test/security/sbom.cdx.json {SCOPE}`。

每条 finding 记录：维度、严重级别、文件/组件、行号、规则/CVE ID、描述摘要、修复建议。

## 三、运行时检测（仅 `--url` 时）

1. **dast-安全头**：对首页与主要路由发 GET，检查安全头与 Cookie 属性，缺失项按风险定级。
2. **dast-OWASP**（A01~A10 只读）：越权路径尝试、目录穿越读取、敏感文件暴露（/.git/config、/.env、actuator）、错误信息泄露；**写操作/破坏性 payload 必须先经用户确认**。
3. **dast-JWT/会话**：alg=none/弱密钥风险、过期策略、token 存放位置。
4. **ssl**：`openssl s_client` 检查证书有效期/链/协议/密码套件；testssl.sh 可用时跑完整报告。
5. **port**：对照 specs/deployment.md 或 deploy-conf 登记的端口，`ss -ltnp`（或 nmap）列出实际监听，未登记/多余暴露端口告警。
6. **nuclei**（可用时）：`nuclei -u {URL} -severity critical,high,medium -json`。
7. **zap**（可用时）：zap-baseline 被动扫描，只取告警不执行主动攻击。

## 四、供应链检测（仅 `--image` 时）

`trivy image --format json {IMAGE}`：OS 包与应用依赖 CVE、镜像内密钥与配置错误。不做 push 等任何变更操作。

## 五、--fix 修复（仅显式传入时）

只对**高置信、低风险**问题自动修复，其余仅给建议：

- 硬编码密钥 → 环境变量/配置注入（同步 env.example，不写真实值）；Git 历史中的密钥提示轮换，并评估 filter-repo 清理（需用户确认）。
- 依赖漏洞 → 升级到已修复版本；Java 工程升级后 `mvn -q -DskipTests compile` 验证，失败回滚。
- 安全头缺失 / TLS 配置 → 在 nginx 配置中补充（禁止改 Java 后端处理 CORS/安全头）。
- IaC 错误（root 运行、多余端口暴露、缺 HEALTHCHECK）→ 最小改动。
- application*.yml 危险配置（debug、明文密码）→ 按部署规范改为环境变量注入。

每项修复后**复扫该维度**确认消除；修复一律最小化，不顺手重构。

## 六、报告输出

写入 `test/security/security-check-report.md`：

```markdown
# 安全检测报告

检测时间：<YYYY-MM-DD HH:mm>
范围：<scope>；运行时目标：<url 或 无>；镜像：<image 或 无>；模式：<auto/augmented>
维度：<实际执行列表>；工具版本：semgrep x.y / trivy x.y / ...

## 总览
| 维度 | CRITICAL | HIGH | MEDIUM | LOW | 已修复 |
|---|---|---|---|---|---|

## 一、静态（智能体分析 / SAST / SCA / 密钥 / Git 历史 / IaC / 许可证 / SBOM）
## 二、运行时（安全头 / OWASP / JWT / TLS / 端口 / Nuclei / ZAP）
## 三、供应链（镜像）

## 结论与修复清单
- CRITICAL/HIGH 逐项结论；修复文件清单；遗留问题与优先级
- 能力边界声明：业务逻辑漏洞、云/IAM 配置、零日漏洞需人工/渗透测试覆盖
```

同时向用户输出中文摘要：各维度问题数（CRITICAL/HIGH 单列明细）、修复项、遗留项。

## 七、注意事项

- 报告**只引用密钥类型与位置，不回显明文**；发现泄露的密钥提示用户立即轮换。
- 运行时探测只做只读/低侵入操作，写操作 payload 必须用户确认；目标必须是用户指定的非生产环境。
- 检测与修复不改动 `v0/` 只读文档目录；产物只写入 `test/security/`。
- 依赖升级必须编译验证后保留，失败回滚；不执行 `git commit`，由用户决定是否提交。
- 工具结果存在误报：CRITICAL/HIGH 逐条确认后写入结论，不确定项标注 `待确认`。
