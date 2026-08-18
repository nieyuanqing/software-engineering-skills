#!/bin/bash
# Android 构建校验脚本——只做编译校验，不签名、不产出可安装的 APK
#（正式打包/签名/产物分发请走工程自己的发布流程，本脚本只管
# "本机改完代码后编译能不能过"）。
#
# 环境解析约定：SDK 位置优先 src/android/local.properties 的 sdk.dir
#（每台开发机各自配置，不提交到版本库），其次 ANDROID_HOME（默认
# $HOME/Android/Sdk）；gradle 优先 gradlew，回退系统 gradle。
# release 系 task 的签名凭据走环境变量：ANDROID_KEYSTORE_PATH /
# ANDROID_KEYSTORE_PASSWORD / ANDROID_KEY_ALIAS / ANDROID_KEY_PASSWORD
#（build.gradle(.kts) 用 System.getenv 读取）。
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$PROJECT_DIR/src/android"
RUNTIME_DIR="$PROJECT_DIR/runtime"

GRADLE_TASK="compileDebugKotlin"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [android-build.sh] $*"
}

fail() {
    log "错误: $*"
    echo "[STATUS] ERROR - 构建失败：$*"
    exit 1
}

fail_gradle() {
    local log_file="$1"
    log "错误: Gradle 构建失败，错误日志如下（最后 120 行）:"
    tail -n 120 "$log_file" || true
    echo "[STATUS] ERROR - Gradle 构建失败，完整日志: $log_file"
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  bash scripts/android-build.sh [OPTIONS]

只做编译校验（默认 gradle task: compileDebugKotlin），不签名、不产出 APK。
正式打包 APK（assembleDebug/assembleRelease，含 release 签名与产物分发）
请走工程自己的发布流程。

运行前提：Android SDK 可被找到——优先 src/android/local.properties 的
sdk.dir（每台开发机各自配置，不提交到版本库），其次 ANDROID_HOME（默认
$HOME/Android/Sdk）。task 为 release 系（如 assembleRelease）时还需要
ANDROID_KEYSTORE_PATH/ANDROID_KEYSTORE_PASSWORD/ANDROID_KEY_ALIAS/
ANDROID_KEY_PASSWORD 四个环境变量。

Options:
  -t, --task TASK      指定 Gradle task，默认 compileDebugKotlin。
                       比如想连带跑一遍 debug APK 组装，可以传 assembleDebug。
  -h, --help           显示本帮助

示例:
  bash scripts/android-build.sh
  bash scripts/android-build.sh --task assembleDebug
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -t|--task) GRADLE_TASK="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "未知参数: $1（用 -h 查看帮助）" ;;
    esac
done

[ -d "$ANDROID_DIR" ] || fail "未找到 Android 工程目录: $ANDROID_DIR（标准约定为 <工程根>/src/android）"

# ── 依赖检查（缺什么提示什么） ──

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"

if ! command -v java >/dev/null 2>&1; then
    log "缺少依赖: java —— Gradle 构建需要 JDK（具体版本以工程 build.gradle 声明为准）"
    fail "缺少依赖: java"
fi

GRADLE_BIN=""
if [ -x "$ANDROID_DIR/gradlew" ]; then
    GRADLE_BIN="$ANDROID_DIR/gradlew"
elif command -v gradle >/dev/null 2>&1; then
    GRADLE_BIN="gradle"
    log "gradlew 不可执行，回退系统 gradle: $(command -v gradle)"
fi
if [ -z "$GRADLE_BIN" ]; then
    log "缺少依赖: gradle —— ${ANDROID_DIR}/gradlew 不存在或不可执行，本机也没有 gradle"
    fail "缺少依赖: gradlew/gradle"
fi

# SDK 位置：gradle 优先读 local.properties 的 sdk.dir；没有该配置时 ANDROID_HOME 目录必须存在
if ! grep -q '^sdk\.dir=' "$ANDROID_DIR/local.properties" 2>/dev/null; then
    if [ ! -d "$ANDROID_HOME" ]; then
        log "缺少依赖: Android SDK —— ${ANDROID_DIR}/local.properties 未配置 sdk.dir，ANDROID_HOME 目录（${ANDROID_HOME}）也不存在"
        fail "缺少依赖: Android SDK"
    fi
fi

# release 系 task 提前校验签名凭据（build.gradle(.kts) 用 System.getenv 读取）
case "$GRADLE_TASK" in
    *[Rr]elease*)
        missing=()
        [ -n "${ANDROID_KEYSTORE_PATH:-}" ]     || missing+=("ANDROID_KEYSTORE_PATH")
        [ -n "${ANDROID_KEYSTORE_PASSWORD:-}" ] || missing+=("ANDROID_KEYSTORE_PASSWORD")
        [ -n "${ANDROID_KEY_ALIAS:-}" ]         || missing+=("ANDROID_KEY_ALIAS")
        [ -n "${ANDROID_KEY_PASSWORD:-}" ]      || missing+=("ANDROID_KEY_PASSWORD")
        if [ "${#missing[@]}" -gt 0 ]; then
            fail "release task 需要以下环境变量（缺失: ${missing[*]}）：ANDROID_KEYSTORE_PATH, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD"
        fi
        [ -f "$ANDROID_KEYSTORE_PATH" ] || fail "未找到 keystore 文件: $ANDROID_KEYSTORE_PATH"
        ;;
esac

log "依赖检查通过（gradle: ${GRADLE_BIN}，ANDROID_HOME: ${ANDROID_HOME}）"

mkdir -p "$RUNTIME_DIR"

log "使用 task: $GRADLE_TASK"
BUILD_LOG_FILE="$RUNTIME_DIR/build-android-$(date '+%Y%m%d%H%M%S').log"
log "Gradle 构建日志: $BUILD_LOG_FILE"

if "$GRADLE_BIN" -p "$ANDROID_DIR" "$GRADLE_TASK" --console=plain >"$BUILD_LOG_FILE" 2>&1; then
    log "编译通过"
    echo "[STATUS] SUCCESS - Android 编译校验通过（task: ${GRADLE_TASK}），完整日志: $BUILD_LOG_FILE"
else
    fail_gradle "$BUILD_LOG_FILE"
fi
