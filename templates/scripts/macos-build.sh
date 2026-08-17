#!/bin/bash
# iOS 构建校验与打包脚本——只在 macOS + Xcode 环境下运行。
# 默认跑模拟器编译校验（xcodebuild build，ad-hoc 签名，无需证书），成功后把
# 模拟器 .app 打包 zip 归档到 mobile-apps/（与 Android APK 同一分发目录）；
# --run 额外装到可用 iPhone 模拟器并启动，供界面验证；--ipa 额外走 archive +
# exportArchive 打真机 .ipa（签名凭据 IOS_TEAM_ID/IOS_EXPORT_METHOD 走环境变量）。
# 工程定位：-p 显式指定，或在当前目录自动查找（优先 .xcworkspace，其次
# .xcodeproj，找到多个则报错要求明确指定）。产物名/Bundle ID 全部从
# xcodebuild -showBuildSettings 动态读取，不硬编码任何工程专属信息。
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$PROJECT_DIR/runtime"

IOS_PROJECT_PATH="${IOS_PROJECT_PATH:-}"
IOS_SCHEME="${IOS_SCHEME:-}"
CONFIGURATION="Debug"
RUN_IN_SIMULATOR=false
BUILD_IPA=false
IOS_TEAM_ID="${IOS_TEAM_ID:-}"
IOS_CODE_SIGN_IDENTITY="${IOS_CODE_SIGN_IDENTITY:-}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [macos-build.sh] $*"
}

fail() {
    log "错误: $*"
    echo "[STATUS] ERROR - 构建失败：$*"
    exit 1
}

fail_xcodebuild() {
    local log_file="$1"
    log "错误: xcodebuild 编译失败，先摘 error 行（最多 40 条）:"
    grep -m 40 "error:" "$log_file" || true
    log "错误日志最后 60 行:"
    tail -n 60 "$log_file" || true
    echo "[STATUS] ERROR - xcodebuild 编译失败，完整日志: $log_file"
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  bash scripts/macos-build.sh [OPTIONS]

iOS 构建校验与打包：默认跑模拟器编译校验（xcodebuild build），成功后把
模拟器 .app zip 归档到 mobile-apps/（与 Android APK 同一分发目录）；
--run 额外装到模拟器启动；--ipa 额外 archive + exportArchive 打真机 .ipa
（必须 --team，签名相关见下）。出正式分发包建议 -c Release。

Options:
  -p, --project PATH   指定 .xcodeproj 或 .xcworkspace 路径。
                       不指定时自动在当前目录下查找（优先 .xcworkspace，其次 .xcodeproj，
                       找到多个则报错，需要用这个参数明确指定）。
                       也可用环境变量 IOS_PROJECT_PATH 指定。
  -s, --scheme NAME    指定 Xcode scheme 名称。
                       不指定时用 xcodebuild -list 读取工程的第一个 scheme。
                       也可用环境变量 IOS_SCHEME 指定。
  -c, --configuration NAME
                       构建配置，默认 Debug（校验/模拟器用）；
                       出分发包建议 Release（优化与线上态一致）。
  -r, --run            构建成功后安装到可用 iPhone 模拟器并启动（界面验证用，
                       需要 Xcode 已下载模拟器运行时）。
  -i, --ipa            额外打真机 .ipa：xcodebuild archive + exportArchive，
                       产物进 mobile-apps/。签名账号未就绪（Xcode 未登录/无
                       证书）时尝试 archive 后给出提示并跳过，不视为构建失败。
                       Team ID 用 -t/--team 或环境变量 IOS_TEAM_ID 提供
                       （Team ID 非敏感信息）；导出方式走环境变量
                       IOS_EXPORT_METHOD（development|ad-hoc|enterprise|
                       app-store，默认 development），Mac 需已在 Xcode
                       登录对应 Apple 账号。
  -t, --team TEAM_ID   Apple 开发者 Team ID，--ipa 时必须显式提供（无默认值）；
                       也可用环境变量 IOS_TEAM_ID，参数优先。
  -I, --identity NAME  签名证书（CODE_SIGN_IDENTITY），--ipa 可选；不指定时按
                       导出方式推断：development→Apple Development，
                       ad-hoc/enterprise/app-store→Apple Distribution。
                       等价于环境变量 IOS_CODE_SIGN_IDENTITY，参数优先。
  -h, --help           显示本帮助

示例:
  cd src/ios && bash ../../scripts/macos-build.sh
  bash scripts/macos-build.sh --project src/ios/MyApp.xcodeproj --scheme MyApp
  bash scripts/macos-build.sh --run
  bash scripts/macos-build.sh --ipa --team ABC1234567
  IOS_SCHEME=MyApp bash scripts/macos-build.sh
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -p|--project) IOS_PROJECT_PATH="$2"; shift 2 ;;
        -s|--scheme) IOS_SCHEME="$2"; shift 2 ;;
        -c|--configuration) CONFIGURATION="$2"; shift 2 ;;
        -r|--run) RUN_IN_SIMULATOR=true; shift ;;
        -i|--ipa) BUILD_IPA=true; shift ;;
        -t|--team)
            [ "$#" -ge 2 ] || fail "--team 缺少参数"
            IOS_TEAM_ID="$2"; shift 2 ;;
        -I|--identity)
            [ "$#" -ge 2 ] || fail "--identity 缺少参数"
            IOS_CODE_SIGN_IDENTITY="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "未知参数: $1（用 -h 查看帮助）" ;;
    esac
done

# --ipa 的 Team ID 必须显式提供、不做任何默认值；构建开始前先校验，缺参直接报错。
if [ "$BUILD_IPA" = true ] && [ -z "$IOS_TEAM_ID" ]; then
    fail "--ipa 必须显式指定 Team ID（无默认值）：--team <TeamID> 或环境变量 IOS_TEAM_ID"
fi

[ "$(uname -s)" = "Darwin" ] || fail "这个脚本只能在 macOS 上运行（当前系统: $(uname -s)）"

# ── 依赖检查：工具/SDK 缺失时输出带安装指引的提醒日志，已具备的打印版本 ────
check_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        log "缺少依赖工具: $1 —— $2"
        fail "缺少依赖工具: $1（$2）"
    }
}

log "依赖检查..."
check_tool xcodebuild "App Store 安装 Xcode 后执行 xcode-select --install"
check_tool xcrun "随 Xcode 提供，请先安装 Xcode"
check_tool ditto "macOS 自带工具（.app 打 zip 用），缺失请修复系统"
check_tool python3 "解析模拟器列表用，xcode-select --install 或 brew install python3"
log "  已具备: $(python3 --version 2>&1)"

XCODE_VERSION="$(xcodebuild -version </dev/null 2>&1 | head -n 1)" || true
case "${XCODE_VERSION:-}" in
    Xcode*) log "  已具备: ${XCODE_VERSION}" ;;
    *) fail "缺少依赖: 完整 Xcode（当前只有 Command Line Tools 或 license 未同意）。安装 Xcode 后执行 sudo xcode-select -s /Applications/Xcode.app/Contents/Developer，或手动跑一次 xcodebuild 同意 license" ;;
esac

SIM_SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version </dev/null 2>/dev/null)" || true
[ -n "$SIM_SDK_VERSION" ] || fail "缺少依赖库: iOS 模拟器 SDK——打开 Xcode → Settings → Platforms 安装 iOS 模拟器运行时"
log "  已具备: iOS Simulator SDK ${SIM_SDK_VERSION}"

if [ "$BUILD_IPA" = true ]; then
    DEVICE_SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version </dev/null 2>/dev/null)" || true
    [ -n "$DEVICE_SDK_VERSION" ] || fail "缺少依赖库: iOS 真机 SDK——随 Xcode 自带，缺失请重装 Xcode"
    log "  已具备: iOS Device SDK ${DEVICE_SDK_VERSION}"

    # 签名证书：钥匙串里没有可能是"未登录"，也可能是"已登录但首次还没生成证书"
    # （后者 archive 时自动签名会自建），这里只提示，不预先跳过——真正未登录的
    # 场景在 archive 失败时识别并提示跳过（见下方 --ipa 段）。
    if security find-identity -v -p codesigning </dev/null 2>/dev/null | grep -qE "Apple (Development|Distribution)|iPhone (Developer|Distribution)"; then
        log "  已具备: 钥匙串存在可用签名证书"
    else
        log "  提示: 钥匙串暂无 iOS 签名证书——已登录 Xcode 账号时 archive 会自动创建；未登录时 --ipa 会提示并跳过"
    fi
fi

SIM_UDID=""
if [ "$RUN_IN_SIMULATOR" = true ]; then
    SIM_UDID="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
data = json.load(sys.stdin)
for devices in data["devices"].values():
    for dev in devices:
        if dev.get("isAvailable") and "iPhone" in dev["name"]:
            print(dev["udid"]); sys.exit(0)
')" || true
    [ -n "$SIM_UDID" ] || fail "缺少依赖: 可用 iPhone 模拟器——打开 Xcode → Settings → Platforms 下载模拟器运行时"
    log "  已具备: iPhone 模拟器 ${SIM_UDID}"
fi
log "依赖检查通过"

mkdir -p "$RUNTIME_DIR"

# 定位工程：优先 .xcworkspace（用了 CocoaPods/SPM 多 target 场景一般会有），
# 没有的话退回 .xcodeproj。同一种找到多个又没指定 -p，直接报错，不猜——猜错了
# 会往错误的工程里跑构建，比直接报错更难排查。
XCODEBUILD_PROJECT_FLAG=()
if [ -n "$IOS_PROJECT_PATH" ]; then
    [ -e "$IOS_PROJECT_PATH" ] || fail "指定的工程路径不存在: $IOS_PROJECT_PATH"
else
    workspaces=()
    while IFS= read -r -d '' f; do workspaces+=("$f"); done < <(find . -maxdepth 1 -iname "*.xcworkspace" -print0)

    if [ "${#workspaces[@]}" -gt 1 ]; then
        fail "在当前目录下找到多个 .xcworkspace，请用 -p/--project 明确指定: ${workspaces[*]}"
    elif [ "${#workspaces[@]}" -eq 1 ]; then
        IOS_PROJECT_PATH="${workspaces[0]}"
    else
        projects=()
        while IFS= read -r -d '' f; do projects+=("$f"); done < <(find . -maxdepth 1 -iname "*.xcodeproj" -print0)

        if [ "${#projects[@]}" -eq 0 ]; then
            fail "当前目录下未找到 .xcworkspace / .xcodeproj，请 cd 到 iOS 工程目录执行，或用 -p/--project 指定工程路径"
        elif [ "${#projects[@]}" -gt 1 ]; then
            fail "在当前目录下找到多个 .xcodeproj，请用 -p/--project 明确指定: ${projects[*]}"
        else
            IOS_PROJECT_PATH="${projects[0]}"
        fi
    fi
fi

if [[ "$IOS_PROJECT_PATH" == *.xcworkspace ]]; then
    XCODEBUILD_PROJECT_FLAG=(-workspace "$IOS_PROJECT_PATH")
else
    XCODEBUILD_PROJECT_FLAG=(-project "$IOS_PROJECT_PATH")
fi
log "使用工程: $IOS_PROJECT_PATH"

# 没指定 scheme 就读工程里的第一个——大多数场景工程只有一个 scheme（App 本身），
# 够用；有多个 scheme 的场景需要用 -s/--scheme 明确指定。
# xcodebuild 首次运行可能弹 license/组件安装等交互提示——stdin 接 /dev/null 让它
# 快速失败而不是静默挂起；读不到 scheme 时把 -list 输出打出来便于排查。
if [ -z "$IOS_SCHEME" ]; then
    XCODE_LIST_OUTPUT="$(xcodebuild -list "${XCODEBUILD_PROJECT_FLAG[@]}" </dev/null 2>&1)" || true
    IOS_SCHEME="$(printf '%s\n' "$XCODE_LIST_OUTPUT" | awk '/Schemes:/{flag=1; next} flag && NF{print; exit}' | sed 's/^[[:space:]]*//')"
    if [ -z "$IOS_SCHEME" ]; then
        log "xcodebuild -list 输出（最后 20 行）:"
        printf '%s\n' "$XCODE_LIST_OUTPUT" | tail -20
        fail "未能从工程里自动读到 scheme，请用 -s/--scheme 明确指定（若上面提示 license/组件安装，先手动跑一次 xcodebuild 完成确认）"
    fi
fi
log "使用 scheme: ${IOS_SCHEME}，configuration: $CONFIGURATION"

BUILD_LOG_FILE="$RUNTIME_DIR/build-ios-$(date '+%Y%m%d%H%M%S').log"
log "xcodebuild 构建日志: $BUILD_LOG_FILE"

# 模拟器编译校验用 ad-hoc 签名（CODE_SIGN_IDENTITY="-"，不需要任何证书）：iOS 17+
# 模拟器对未签名 App 的 Keychain 访问会静默失败（SecItemAdd 报错），登录 token
# 存不进去，登录后第一个请求不带 Authorization 被 401 踢回登录页——ad-hoc 签名
# 不需要证书，又让 App 带合法标识，Keychain 恢复正常。destination 用
# generic/platform=iOS Simulator，不需要实际启动模拟器实例。
if xcodebuild build \
    "${XCODEBUILD_PROJECT_FLAG[@]}" \
    -scheme "$IOS_SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=iOS Simulator" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_IDENTITY="-" \
    </dev/null >"$BUILD_LOG_FILE" 2>&1; then
    log "编译通过"
else
    fail_xcodebuild "$BUILD_LOG_FILE"
fi

# ── 产物归档：模拟器 .app zip 进 mobile-apps/（与 Android APK 同目录）────────
# 产物名/版本/Bundle ID 全部从 build settings 动态读取，不硬编码工程专属信息。
BUILD_SETTINGS="$(xcodebuild -showBuildSettings \
    "${XCODEBUILD_PROJECT_FLAG[@]}" \
    -scheme "$IOS_SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=iOS Simulator" \
    </dev/null 2>/dev/null)"

read_build_setting() {
    printf '%s\n' "$BUILD_SETTINGS" | awk -v key="$1" '$0 ~ "^[[:space:]]+" key " = " {sub(/^.*= /, ""); print; exit}'
}

PRODUCTS_DIR="$(read_build_setting BUILT_PRODUCTS_DIR)"
PRODUCT_NAME="$(read_build_setting PRODUCT_NAME)"
BUNDLE_ID="$(read_build_setting PRODUCT_BUNDLE_IDENTIFIER)"
APP_VERSION="$(read_build_setting MARKETING_VERSION)"
APP_VERSION="${APP_VERSION:-1.0.0}"
[ -n "$PRODUCT_NAME" ] || fail "未能从 build settings 读取 PRODUCT_NAME，无法定位构建产物"

APP_PATH="$PRODUCTS_DIR/${PRODUCT_NAME}.app"
[ -d "$APP_PATH" ] || fail "未找到构建产物: ${APP_PATH:-（BUILT_PRODUCTS_DIR 为空）}"
log "构建结果完整路径: $APP_PATH"

MOBILE_APPS_DIR="$PROJECT_DIR/mobile-apps"
CFG_LOWER="$(printf '%s' "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')"
IOS_ARTIFACT="$MOBILE_APPS_DIR/${PRODUCT_NAME}-ios-${CFG_LOWER}-${APP_VERSION}.zip"
mkdir -p "$MOBILE_APPS_DIR"
ditto -c -k --keepParent "$APP_PATH" "$IOS_ARTIFACT" || fail "归档产物失败: $IOS_ARTIFACT"
log "iOS 产物已归档: $IOS_ARTIFACT"

# ── --run：装到可用 iPhone 模拟器并启动（界面验证）──────────────────────────
# SIM_UDID 已在依赖检查阶段选好并校验过，这里直接用。
if [ "$RUN_IN_SIMULATOR" = true ]; then
    [ -n "$BUNDLE_ID" ] || fail "未能从 build settings 读取 PRODUCT_BUNDLE_IDENTIFIER，无法在模拟器启动 App"
    log "启动模拟器并安装: ${SIM_UDID}"
    xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
    # simctl boot 只启动后台设备，不会弹窗——主动打开 Simulator 才能看到运行画面
    open -a Simulator || fail "打开 Simulator 应用失败"
    xcrun simctl install "$SIM_UDID" "$APP_PATH" || fail "安装到模拟器失败: ${SIM_UDID}"
    xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" || fail "模拟器启动 App 失败（${BUNDLE_ID}）"
    log "App 已在模拟器启动（${BUNDLE_ID}）"
fi

# ── --ipa：真机 archive + exportArchive 产 .ipa（签名凭据走环境变量）────────
IPA_ARTIFACT=""
if [ "$BUILD_IPA" = true ]; then
    IOS_EXPORT_METHOD="${IOS_EXPORT_METHOD:-development}"
    case "$IOS_EXPORT_METHOD" in
        development|ad-hoc|enterprise|app-store) ;;
        *) fail "IOS_EXPORT_METHOD 取值无效: ${IOS_EXPORT_METHOD}（可选: development|ad-hoc|enterprise|app-store）" ;;
    esac
    # 证书不指定时按导出方式推断：开发签名用 Apple Development，分发类用 Apple Distribution。
    if [ -z "$IOS_CODE_SIGN_IDENTITY" ]; then
        if [ "$IOS_EXPORT_METHOD" = "development" ]; then
            IOS_CODE_SIGN_IDENTITY="Apple Development"
        else
            IOS_CODE_SIGN_IDENTITY="Apple Distribution"
        fi
    fi
    log "签名证书: ${IOS_CODE_SIGN_IDENTITY}"

    EXPORT_OPTIONS="$RUNTIME_DIR/exportOptions.plist"
    cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>${IOS_EXPORT_METHOD}</string>
	<key>teamID</key>
	<string>${IOS_TEAM_ID}</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>compileBitcode</key>
	<false/>
	<key>stripSwiftSymbols</key>
	<true/>
</dict>
</plist>
PLIST

    ARCHIVE_PATH="$RUNTIME_DIR/${PRODUCT_NAME}-$(date '+%Y%m%d%H%M%S').xcarchive"
    IPA_LOG="$RUNTIME_DIR/build-ios-ipa-$(date '+%Y%m%d%H%M%S').log"
    # 签名账号未就绪（未登录/无证书无 profile）时：提示 + 跳过，不视为构建失败。
    skip_ipa_with_notice() {
        log "提示: 签名账号未就绪——请到 Xcode → Settings → Accounts 登录 Team ${IOS_TEAM_ID} 的 Apple 账号后重新执行 -i"
        log "本次 --ipa 跳过，不视为构建失败；编译校验与模拟器归档已完成"
        echo "[STATUS] SKIPPED - --ipa 跳过：签名账号未就绪（完整日志: $1）"
        exit 0
    }
    log "真机 archive（team: ${IOS_TEAM_ID}，method: ${IOS_EXPORT_METHOD}），日志: ${IPA_LOG}"
    if ! xcodebuild archive \
        "${XCODEBUILD_PROJECT_FLAG[@]}" \
        -scheme "$IOS_SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "generic/platform=iOS" \
        -archivePath "$ARCHIVE_PATH" \
        -allowProvisioningUpdates \
        CODE_SIGNING_ALLOWED=YES \
        CODE_SIGN_STYLE=Automatic \
        CODE_SIGN_IDENTITY="$IOS_CODE_SIGN_IDENTITY" \
        DEVELOPMENT_TEAM="$IOS_TEAM_ID" \
        </dev/null >"$IPA_LOG" 2>&1; then
        grep -qE "No Accounts|No profiles|No signing certificate|provisioning profile" "$IPA_LOG" \
            && skip_ipa_with_notice "$IPA_LOG"
        fail_xcodebuild "$IPA_LOG"
    fi

    IPA_EXPORT_DIR="$RUNTIME_DIR/ipa-export"
    rm -rf "$IPA_EXPORT_DIR"
    log "exportArchive 生成 .ipa"
    if ! xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        -exportPath "$IPA_EXPORT_DIR" \
        -allowProvisioningUpdates \
        </dev/null >>"$IPA_LOG" 2>&1; then
        grep -qE "No Accounts|No profiles|No signing certificate|provisioning profile" "$IPA_LOG" \
            && skip_ipa_with_notice "$IPA_LOG"
        fail_xcodebuild "$IPA_LOG"
    fi

    IPA_ARTIFACT="$MOBILE_APPS_DIR/${PRODUCT_NAME}-ios-${CFG_LOWER}-${APP_VERSION}.ipa"
    cp -f "$IPA_EXPORT_DIR/${PRODUCT_NAME}.ipa" "$IPA_ARTIFACT" || fail "拷贝 .ipa 失败: ${IPA_ARTIFACT}"
    log ".ipa 产物完整路径: ${IPA_ARTIFACT}"
fi

if [ "$BUILD_IPA" = true ]; then
    echo "[STATUS] SUCCESS - iOS 构建成功（工程: ${IOS_PROJECT_PATH}，scheme: ${IOS_SCHEME}，模拟器产物: ${IOS_ARTIFACT}，真机产物: ${IPA_ARTIFACT}）"
else
    echo "[STATUS] SUCCESS - iOS 构建成功（工程: ${IOS_PROJECT_PATH}，scheme: ${IOS_SCHEME}，产物: ${IOS_ARTIFACT}）"
fi
