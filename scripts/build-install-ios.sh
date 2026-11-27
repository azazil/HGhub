#!/usr/bin/env bash
# HGhub iOS 本地一键编译并安装到真机
#
# 用法:
#   bash scripts/build-install-ios.sh                  # Debug 构建，安装到第一台已连接 iPhone
#   bash scripts/build-install-ios.sh --release        # Release 构建
#   bash scripts/build-install-ios.sh --device <ID>    # 指定设备（devicectl identifier 或 UDID）
#   bash scripts/build-install-ios.sh --team <TEAM_ID> # 指定 Apple 开发者团队 ID
#   bash scripts/build-install-ios.sh --launch         # 安装后尝试启动
#
# 环境变量:
#   APPLE_DEVELOPMENT_TEAM  Apple 开发者团队 ID（等价 --team）
#   IOS_DEVICE_ID           目标设备（等价 --device）

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG="debug"
DEVICE_ID="${IOS_DEVICE_ID:-}"
TEAM="${APPLE_DEVELOPMENT_TEAM:-}"
LAUNCH=0
BUNDLE_ID="com.hghub.huangguo"
PROJECT_DIR="src-tauri/gen/apple"
PROJECT="$PROJECT_DIR/huangguo-client.xcodeproj"
PLIST="$PROJECT_DIR/huangguo-client_iOS/Info.plist"

info() { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[OK]   %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
HGhub iOS 本地一键编译并安装到真机

用法:
  bash scripts/build-install-ios.sh                  # Debug 构建，安装到第一台已连接 iPhone
  bash scripts/build-install-ios.sh --release        # Release 构建
  bash scripts/build-install-ios.sh --device <ID>    # 指定设备（devicectl identifier / UDID / 名称）
  bash scripts/build-install-ios.sh --team <TEAM_ID> # 指定 Apple 开发者团队 ID
  bash scripts/build-install-ios.sh --launch         # 安装后尝试启动

通过 pnpm 调用时参数前需要加 --，例如:
  pnpm ios:install -- --release --launch

环境变量:
  APPLE_DEVELOPMENT_TEAM  Apple 开发者团队 ID（等价 --team）
  IOS_DEVICE_ID           目标设备（等价 --device）
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --)       shift ;;
    --release) CONFIG="release"; shift ;;
    --debug)   CONFIG="debug"; shift ;;
    --device)  [[ $# -ge 2 ]] || fail "--device 需要参数"; DEVICE_ID="$2"; shift 2 ;;
    --team)    [[ $# -ge 2 ]] || fail "--team 需要参数"; TEAM="$2"; shift 2 ;;
    --launch)  LAUNCH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "未知参数: $1（--help 查看用法）" ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || fail "iOS 真机编译只能在 macOS 上运行"

for cmd in node pnpm cargo xcodebuild xcrun; do
  command -v "$cmd" >/dev/null 2>&1 || fail "缺少命令: $cmd"
done

# Xcode 的 Run Script 默认不含 Homebrew 路径，这里同时作用于当前 shell 和 xcodebuild
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# 团队 ID：命令行/环境变量 > tauri.conf.json > Xcode 最近选择 > 本机签名证书
if [[ -z "$TEAM" ]]; then
  TEAM="$(node -e 'const c=require("./src-tauri/tauri.conf.json");process.stdout.write((c.bundle&&c.bundle.iOS&&c.bundle.iOS.developmentTeam)||"")' 2>/dev/null || true)"
fi
if [[ -z "$TEAM" || "$TEAM" == "ABCDE12345" ]]; then
  TEAM="$(defaults read com.apple.dt.Xcode IDEProvisioningTeamManagerLastSelectedTeamID 2>/dev/null || true)"
fi
if [[ -z "$TEAM" ]]; then
  TEAM="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p' | head -1)"
fi
if [[ -z "$TEAM" || "$TEAM" == "ABCDE12345" ]]; then
  fail "未检测到开发者团队。请传 --team <TeamID>，或设置环境变量 APPLE_DEVELOPMENT_TEAM"
fi
info "使用开发者团队: $TEAM"

# 依赖
if [[ ! -d node_modules ]]; then
  info "安装前端依赖..."
  pnpm install
fi
if command -v rustup >/dev/null 2>&1; then
  rustup target add aarch64-apple-ios >/dev/null 2>&1 || true
fi

# 设备解析
resolve_device() {
  local json
  json="$(mktemp)"
  if ! xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1; then
    rm -f "$json"
    fail "无法读取设备列表，请确认 Xcode 已登录且手机已连接"
  fi
  DEVICES_JSON="$json" WANTED="${WANTED:-}" node -e '
const fs = require("fs");
const j = JSON.parse(fs.readFileSync(process.env.DEVICES_JSON, "utf8"));
const devices = (j.result && j.result.devices) || [];
const ios = devices.filter((d) => d.hardwareProperties && d.hardwareProperties.platform === "iOS");
const wanted = process.env.WANTED || "";
let pick = null;
if (wanted) {
  pick = ios.find((d) =>
    d.identifier === wanted ||
    d.hardwareProperties.udid === wanted ||
    d.deviceProperties.name === wanted
  );
} else {
  pick = ios.find((d) => d.connectionProperties && d.connectionProperties.tunnelState === "connected") || ios[0];
}
if (!pick) {
  const list = ios.map((d) => "  " + d.deviceProperties.name + "  identifier=" + d.identifier + "  udid=" + d.hardwareProperties.udid).join("\n");
  console.error(wanted ? ("[FAIL] 找不到设备: " + wanted + "\n可选设备:\n" + (list || "  (无)")) : "[FAIL] 没有检测到已连接的 iOS 设备，请用数据线连接并在手机上信任此电脑");
  process.exit(1);
}
const p = pick.deviceProperties || {};
const h = pick.hardwareProperties || {};
const c = pick.connectionProperties || {};
process.stdout.write([pick.identifier, p.name || "iPhone", h.udid || "", p.osVersionNumber || "", p.developerModeStatus || "", c.tunnelState || "unknown"].join("\t"));
'
  rm -f "$json"
}

if [[ -z "$DEVICE_ID" ]]; then
  info "查找已连接的 iOS 设备..."
  device_line="$(WANTED="" resolve_device)"
else
  device_line="$(WANTED="$DEVICE_ID" resolve_device)"
fi
IFS=$'\t' read -r DEVICE_ID DEVICE_NAME DEVICE_UDID DEVICE_OS DEV_MODE DEV_STATE <<<"$device_line"

info "目标设备: $DEVICE_NAME (iOS $DEVICE_OS, $DEV_STATE)"
[[ -n "$DEVICE_UDID" ]] || fail "未能获取设备 UDID，请用数据线重新连接手机"
[[ "$DEV_MODE" == "enabled" ]] || warn "设备开发者模式未开启：设置 -> 隐私与安全性 -> 开发者模式"
[[ "$DEV_STATE" == "connected" ]] || warn "设备当前状态为 $DEV_STATE，安装可能失败，请用数据线连接并保持解锁"

# 生成工程（首次）
if [[ ! -d "$PROJECT_DIR" ]]; then
  info "未找到 iOS 工程，执行 pnpm tauri ios init --ci ..."
  APPLE_DEVELOPMENT_TEAM="$TEAM" pnpm tauri ios init --ci
fi
[[ -d "$PROJECT" ]] || fail "iOS 工程生成失败: $PROJECT"

# 若工程是在 Externals 已有 libapp.a 时生成的，XcodeGen 会把它们当成资源
# 重复拷贝（Multiple commands produce .../libapp.a）。重新生成前清空 Externals，
# 让 libapp.a 只通过链接搜索路径参与构建；同时给 Build Rust Code 脚本补上
# Homebrew 路径，避免找不到 pnpm/node。
NEED_REGEN=0
if [[ -f "$PROJECT_DIR/project.yml" ]] && ! grep -q "/opt/homebrew/bin" "$PROJECT_DIR/project.yml"; then
  node -e '
const fs = require("fs");
const p = "src-tauri/gen/apple/project.yml";
let s = fs.readFileSync(p, "utf8");
if (s.includes("/opt/homebrew/bin")) process.exit(0);
if (!s.includes("- script: pnpm tauri ios xcode-script")) process.exit(0);
s = s.replace("- script: pnpm tauri ios xcode-script", "- script: |\n          export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"\n          pnpm tauri ios xcode-script");
fs.writeFileSync(p, s);
' || true
  NEED_REGEN=1
fi
if [[ -f "$PROJECT/project.pbxproj" ]] && grep -q "libapp.a in Resources" "$PROJECT/project.pbxproj"; then
  NEED_REGEN=1
fi
if [[ "$NEED_REGEN" == "1" ]] && command -v xcodegen >/dev/null 2>&1; then
  mkdir -p "$PROJECT_DIR/Externals"
  find "$PROJECT_DIR/Externals" -mindepth 1 -delete 2>/dev/null || true
  (cd "$PROJECT_DIR" && xcodegen generate >/dev/null)
fi

# 补全 Info.plist：横竖屏 + ATS 放行
if [[ -f "$PLIST" ]]; then
  for key in "UISupportedInterfaceOrientations" "UISupportedInterfaceOrientations~iphone" "UISupportedInterfaceOrientations~ipad"; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$PLIST" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :$key array" "$PLIST" >/dev/null
    /usr/libexec/PlistBuddy -c "Add :$key:0 string UIInterfaceOrientationPortrait" "$PLIST" >/dev/null
    /usr/libexec/PlistBuddy -c "Add :$key:1 string UIInterfaceOrientationLandscapeLeft" "$PLIST" >/dev/null
    /usr/libexec/PlistBuddy -c "Add :$key:2 string UIInterfaceOrientationLandscapeRight" "$PLIST" >/dev/null
  done
  if /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity" "$PLIST" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :NSAppTransportSecurity:NSAllowsArbitraryLoads true" "$PLIST" >/dev/null 2>&1 || \
      /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true" "$PLIST" >/dev/null
  else
    /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$PLIST" >/dev/null
    /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true" "$PLIST" >/dev/null
  fi
fi

# 清理旧 IPA，避免安装到上一次的产物
find "$PROJECT_DIR/build" -name '*.ipa' -type f -delete 2>/dev/null || true

# 编译 iOS
# 必须用 `tauri ios build` 而不是直接 xcodebuild：Tauri 的 "Build Rust Code"
# 脚本需要 CLI 启动的 options WebSocket 服务，直接 xcodebuild / Xcode GUI 运行
# 会报 "failed to read CLI options: ... Connection refused"。
info "编译 iOS ($CONFIG)，首次编译 Rust 依赖会比较久..."
TAURI_BUILD_ARGS=(ios build --ci)
if [[ "$CONFIG" == "debug" ]]; then
  TAURI_BUILD_ARGS+=(--debug)
fi
APPLE_DEVELOPMENT_TEAM="$TEAM" pnpm tauri "${TAURI_BUILD_ARGS[@]}"

IPA="$(find "$PROJECT_DIR/build" -name '*.ipa' -type f -exec ls -t {} + 2>/dev/null | head -1)"
[[ -n "${IPA:-}" ]] || fail "未找到 .ipa 产物"
ok "编译完成: $IPA"

# 解压 IPA，安装其中的 .app
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
unzip -q "$IPA" -d "$STAGE"
APP="$STAGE/Payload/HGhub.app"
[[ -d "$APP" ]] || fail "IPA 内未找到 Payload/HGhub.app"

# 安装
info "安装到 $DEVICE_NAME ..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"

if [[ "$LAUNCH" == "1" ]]; then
  info "启动 $BUNDLE_ID ..."
  if ! xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"; then
    warn "启动失败（手机锁屏时会这样，解锁后手动点 HGhub 即可）"
  fi
fi

echo "=================================================="
ok "已安装到 $DEVICE_NAME"
echo "IPA: $IPA"
echo "签名团队: $TEAM"
echo "如首次打开提示不受信任，请到 设置 -> 通用 -> VPN与设备管理 信任开发者证书"
echo "=================================================="
