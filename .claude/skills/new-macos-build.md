---
name: new-macos-build
description: 为含 iOS 工程的仓库生成 scripts/macos-build.sh 构建校验与打包脚本（仅 macOS + Xcode）。默认模拟器编译校验（xcodebuild build，不签名），成功后 .app zip 归档到 mobile-apps/；--run 装到 iPhone 模拟器启动；--ipa 走 archive + exportArchive 打真机 .ipa（Team ID/导出方式走环境变量）；工程名/Bundle ID/版本从 build settings 动态读取；[STATUS] 机器可读输出。当用户要求"生成 iOS 构建脚本"、"macos 编译校验脚本"、"初始化 macos-build"时触发。支持 /new-macos-build -h 查看帮助。
---

# new-macos-build

为工程生成标准化的 `scripts/macos-build.sh`——iOS 构建校验与打包脚本（仅在 macOS + Xcode 环境运行）。

**定位**：默认只做模拟器编译校验并把 .app zip 归档到 `mobile-apps/`（与 Android APK 同一分发目录）；`--run` 装到模拟器启动做界面验证；`--ipa` 额外打真机 .ipa。产物名、Bundle ID、版本号全部从 `xcodebuild -showBuildSettings` 动态读取。

**触发条件**：用户要求为某工程创建或更新 iOS 构建校验脚本（macos-build.sh）。

---

## 零、参数处理

**如果用户传入 `-h` 或 `--help`**，不执行任何文件操作，直接输出以下帮助信息后结束：

---

```
用法: /new-macos-build [-h]

功能
  在目标工程根目录生成 scripts/macos-build.sh（iOS 构建校验与打包脚本）。
  无需传参（工程定位、产物名、Bundle ID 均动态推导）。
  生成的脚本只能在 macOS + Xcode 环境运行。

生成文件
  scripts/macos-build.sh   iOS 构建校验与打包脚本

macos-build.sh 主要能力
  编译校验: xcodebuild build，destination=generic/platform=iOS Simulator，
            CODE_SIGNING_ALLOWED=NO（不签名，只验证代码能否编译过）
  工程定位: -p/--project 显式指定；不指定时在当前目录自动查找
            （优先 .xcworkspace，其次 .xcodeproj，多个则报错）
  scheme:   -s/--scheme 指定；不指定时读工程第一个 scheme
  配置:     -c/--configuration，默认 Debug，出分发包建议 Release
  产物归档: 模拟器 .app zip 归档到 mobile-apps/<产品名>-ios-<配置>-<版本>.zip
  --run:    安装到可用 iPhone 模拟器并启动（Bundle ID 动态读取）
  --ipa:    archive + exportArchive 打真机 .ipa，产物进 mobile-apps/；
            Team ID 必须显式提供（-t/--team 或 IOS_TEAM_ID），
            导出方式走 IOS_EXPORT_METHOD（默认 development），
            签名账号未就绪时提示并跳过，不视为构建失败
  日志:     构建日志落盘 runtime/build-ios-<时间戳>.log，
            失败时摘 error 行（最多 40 条）+ 最后 60 行
  状态输出: [STATUS] SUCCESS / ERROR / SKIPPED 机器可读行

示例
  /new-macos-build       在当前工程生成 scripts/macos-build.sh
  /new-macos-build -h    显示本帮助
```

---

## 一、前置检查

### 1.1 确认目标工程

目标工程为**当前工作目录**。检查是否存在 iOS 工程（查找 `*.xcodeproj` / `*.xcworkspace`，或 `src/ios/` 目录）：

- 存在 → 继续。
- 不存在 → 提示用户：`未检测到 iOS 工程（*.xcodeproj / *.xcworkspace / src/ios/），是否仍要生成脚本？`，由用户确认后继续或终止。

### 1.2 检测现有脚本（Update 流程）

**检查目标工程根目录是否已存在 `scripts/macos-build.sh`。**

#### 存在时

1. 将模板渲染结果写入临时文件。
2. **展示差异**（`diff -u scripts/macos-build.sh <新版本>`）。
3. 询问：`是否用新版本覆盖？（y/N）`
4. 用户确认后覆盖，并执行 `chmod +x`。

不要静默覆盖。

#### 不存在时

直接进入生成流程。

---

## 二、生成文件清单

以下文件在**目标工程根目录**下生成：

```
scripts/macos-build.sh
```

---

## 三、生成规则

### 模板来源

| 目标文件 | 模板来源 |
|---|---|
| `scripts/macos-build.sh` | `software-engineering-skills/templates/scripts/macos-build.sh` |

### 占位符替换

**无**。直接原样复制（工程路径自动查找或 `-p` 指定，产物名/Bundle ID/版本从 build settings 动态读取，签名凭据走环境变量），不做任何内容修改。

---

## 四、生成后处理

```bash
chmod +x scripts/macos-build.sh
```

---

## 五、完成提示

生成完成后，向用户输出以下内容：

1. **已生成文件列表**（`scripts/macos-build.sh`）
2. **下一步操作**：

```
## 下一步操作（需在 macOS + Xcode 环境执行）

### 编译校验 + 产物归档（默认）

   # 在 iOS 工程目录下执行（自动查找 .xcworkspace / .xcodeproj）
   cd src/ios && bash ../../scripts/macos-build.sh

   # 或显式指定工程与 scheme
   bash scripts/macos-build.sh --project src/ios/<APP>.xcodeproj --scheme <APP>

### 模拟器界面验证

   bash scripts/macos-build.sh --run

### 打真机 .ipa（出分发包建议 -c Release）

   bash scripts/macos-build.sh --ipa --team <YOUR_TEAM_ID> -c Release
   # 导出方式（默认 development）：
   IOS_EXPORT_METHOD=app-store bash scripts/macos-build.sh --ipa --team <YOUR_TEAM_ID>

### 前提条件

   - App Store 安装完整 Xcode（非仅 Command Line Tools）
   - Xcode → Settings → Platforms 安装 iOS 模拟器运行时
   - --ipa 需在 Xcode → Settings → Accounts 登录对应 Apple 开发者账号
   - 产物统一归档到工程根目录 mobile-apps/
```

---

## 六、注意事项

- 目标文件已存在时，走 **1.2 Update 流程**（展示差异 → 确认覆盖），不要静默覆盖。
- 生成的脚本只能在 **macOS** 上运行（脚本内部有 `uname -s` 校验），在 Linux 开发机上生成后需到 Mac 上执行。
- 构建日志与 archive 产物写入 `runtime/` 目录，该目录建议加入 `.gitignore`（若尚未忽略，生成后提醒用户）。
- 签名相关凭据**只能**通过参数或环境变量传入（`IOS_TEAM_ID`、`IOS_EXPORT_METHOD`、`IOS_CODE_SIGN_IDENTITY`），禁止写入脚本或提交到版本库。
