---
name: new-android-build
description: 为含 Android 工程的仓库生成 scripts/android-build.sh 编译校验脚本。只做编译校验（默认 compileDebugKotlin），不签名、不产出 APK；SDK 定位优先 src/android/local.properties 的 sdk.dir，其次 ANDROID_HOME；gradle 优先 gradlew 回退系统 gradle；release 系 task 校验 ANDROID_KEYSTORE_* 签名环境变量；[STATUS] 机器可读输出。当用户要求"生成 android 构建脚本"、"android 编译校验脚本"、"初始化 android-build"时触发。支持 /new-android-build -h 查看帮助。
---

# new-android-build

为工程生成标准化的 `scripts/android-build.sh`——Android 编译校验脚本。

**定位**：只管"本机改完代码后编译能不能过"，不签名、不产出可安装 APK；正式打包/签名/产物分发由工程自己的发布流程负责。

**触发条件**：用户要求为某工程创建或更新 Android 编译校验脚本（android-build.sh）。

---

## 零、参数处理

**如果用户传入 `-h` 或 `--help`**，不执行任何文件操作，直接输出以下帮助信息后结束：

---

```
用法: /new-android-build [-h]

功能
  在目标工程根目录生成 scripts/android-build.sh（Android 编译校验脚本）。
  脚本内容完全通用，不含任何项目专属信息，无需传参。

生成文件
  scripts/android-build.sh   Android 编译校验脚本

android-build.sh 主要能力
  默认 task: compileDebugKotlin（只编译校验，不签名不出 APK），
            可用 -t/--task 指定其他 task（如 assembleDebug）
  SDK 定位: 优先 src/android/local.properties 的 sdk.dir（本机配置，
            不提交版本库），其次 ANDROID_HOME（默认 $HOME/Android/Sdk）
  gradle:   优先 src/android/gradlew，回退系统 gradle
  签名校验: task 含 release 时提前校验 ANDROID_KEYSTORE_PATH /
            ANDROID_KEYSTORE_PASSWORD / ANDROID_KEY_ALIAS /
            ANDROID_KEY_PASSWORD 四个环境变量
  日志:     构建日志落盘 runtime/build-android-<时间戳>.log，
            失败时摘最后 120 行
  状态输出: [STATUS] SUCCESS / [STATUS] ERROR 机器可读行

约定前提
  Android 工程位于 <工程根>/src/android/（标准目录约定）

示例
  /new-android-build       在当前工程生成 scripts/android-build.sh
  /new-android-build -h    显示本帮助
```

---

## 一、前置检查

### 1.1 确认目标工程

目标工程为**当前工作目录**。检查是否存在 `src/android/` 目录：

- 存在 → 继续。
- 不存在 → 提示用户：`未检测到 src/android/ 目录（标准 Android 工程位置），是否仍要生成脚本？`，由用户确认后继续或终止。

### 1.2 检测现有脚本（Update 流程）

**检查目标工程根目录是否已存在 `scripts/android-build.sh`。**

#### 存在时

1. 将模板渲染结果写入临时文件。
2. **展示差异**（`diff -u scripts/android-build.sh <新版本>`）。
3. 询问：`是否用新版本覆盖？（y/N）`
4. 用户确认后覆盖，并执行 `chmod +x`。

不要静默覆盖。

#### 不存在时

直接进入生成流程。

---

## 二、生成文件清单

以下文件在**目标工程根目录**下生成：

```
scripts/android-build.sh
```

---

## 三、生成规则

### 模板来源

| 目标文件 | 模板来源 |
|---|---|
| `scripts/android-build.sh` | `software-engineering-skills/templates/scripts/android-build.sh` |

### 占位符替换

**无**。模板完全通用（工程路径按标准约定 `src/android/` 推导，SDK/签名凭据走环境变量），直接原样复制，不做任何内容修改。

---

## 四、生成后处理

```bash
chmod +x scripts/android-build.sh
```

---

## 五、完成提示

生成完成后，向用户输出以下内容：

1. **已生成文件列表**（`scripts/android-build.sh`）
2. **下一步操作**：

```
## 下一步操作

### 编译校验（默认）

   bash scripts/android-build.sh

### 指定 Gradle task

   # 连带组装 debug APK
   bash scripts/android-build.sh --task assembleDebug

   # release 编译（需先配置签名环境变量）
   export ANDROID_KEYSTORE_PATH=/path/to/keystore
   export ANDROID_KEYSTORE_PASSWORD=<YOUR_KEYSTORE_PASSWORD>
   export ANDROID_KEY_ALIAS=<YOUR_KEY_ALIAS>
   export ANDROID_KEY_PASSWORD=<YOUR_KEY_PASSWORD>
   bash scripts/android-build.sh --task assembleRelease

### SDK 找不到时

   # 方式一：本机配置 local.properties（不提交版本库）
   echo "sdk.dir=/path/to/Android/Sdk" > src/android/local.properties

   # 方式二：环境变量
   export ANDROID_HOME=/path/to/Android/Sdk
```

---

## 六、注意事项

- 目标文件已存在时，走 **1.2 Update 流程**（展示差异 → 确认覆盖），不要静默覆盖。
- 脚本要求在**项目根目录**执行（`bash scripts/android-build.sh`），脚本内部按自身位置推导工程根目录。
- 构建日志写入 `runtime/` 目录，该目录建议加入 `.gitignore`（若尚未忽略，生成后提醒用户）。
- 签名凭据（keystore 密码等）**只能**通过环境变量传入，禁止写入脚本或提交到版本库。
