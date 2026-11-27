#!/usr/bin/env bash
# HGhub macOS 本地一键打包脚本（默认面向 M1/M2/M3/M4 Apple Silicon）
#
# 用法:
#   bash scripts/build-release-macos.sh                # 构建 arm64 app + dmg，并复制到 artifacts/
#   bash scripts/build-release-macos.sh --install      # 构建后安装到 /Applications
#   bash scripts/build-release-macos.sh --install --launch
#   bash scripts/build-release-macos.sh --universal    # Universal 通用双架构
#   bash scripts/build-release-macos.sh --intel        # Intel (x86_64)
#
# 通过 pnpm 调用时参数前需要加 --，例如:
#   pnpm macos:release -- --install --launch

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ARCH="arm64"
INSTALL=0
LAUNCH=0
ARTIFACT_DIR="$ROOT_DIR/artifacts"
APP_NAME="HGhub"

info() { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[OK]   %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
HGhub macOS 本地一键打包脚本（默认 arm64 / Apple Silicon M 系列）

用法:
  bash scripts/build-release-macos.sh                # 构建 arm64 app + dmg，并复制到 artifacts/
  bash scripts/build-release-macos.sh --install      # 构建后安装到 /Applications
  bash scripts/build-release-macos.sh --install --launch
  bash scripts/build-release-macos.sh --universal    # Universal 通用双架构
  bash scripts/build-release-macos.sh --intel        # Intel (x86_64)

通过 pnpm 调用时参数前需要加 --，例如:
  pnpm macos:release -- --install --launch
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --)          shift ;;
    --install)   INSTALL=1; shift ;;
    --launch)    LAUNCH=1; shift ;;
    --universal) ARCH="universal"; shift ;;
    --intel|x64) ARCH="x86_64"; shift ;;
    --arm64|m4)  ARCH="arm64"; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) fail "未知参数: $1（--help 查看用法）" ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS 打包只能在 macOS 上运行"

for cmd in node pnpm cargo; do
  command -v "$cmd" >/dev/null 2>&1 || fail "缺少命令: $cmd"
done

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

case "$ARCH" in
  arm64)     TARGET="aarch64-apple-darwin";        ARCH_LABEL="arm64" ;;
  x86_64)    TARGET="x86_64-apple-darwin";         ARCH_LABEL="x64" ;;
  universal) TARGET="universal-apple-darwin";      ARCH_LABEL="universal" ;;
  *) fail "未知架构: $ARCH" ;;
esac
info "打包目标: $ARCH_LABEL ($TARGET)"

if [[ ! -d node_modules ]]; then
  info "安装前端依赖..."
  pnpm install
fi

if command -v rustup >/dev/null 2>&1; then
  case "$ARCH" in
    arm64)     rustup target add aarch64-apple-darwin >/dev/null 2>&1 || true ;;
    x86_64)    rustup target add x86_64-apple-darwin >/dev/null 2>&1 || true ;;
    universal) rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null 2>&1 || true ;;
  esac
fi

VERSION="$(node -p 'require("./src-tauri/tauri.conf.json").version')"

info "开始构建（app + dmg）..."
# tauri.macos.conf.json 已配置 targets=[app,dmg] 与 ad-hoc 签名（signingIdentity: "-"）
pnpm tauri build --config src-tauri/tauri.macos.conf.json --target "$TARGET"

BUNDLE_DIR="src-tauri/target/$TARGET/release/bundle"
APP="$BUNDLE_DIR/macos/$APP_NAME.app"
[[ -d "$APP" ]] || fail "未找到 .app 产物: $APP"

DMG="$(find "$BUNDLE_DIR/dmg" -maxdepth 1 -name '*.dmg' -type f -exec ls -t {} + 2>/dev/null | head -1)"
[[ -n "${DMG:-}" ]] || fail "未找到 .dmg 产物: $BUNDLE_DIR/dmg"

mkdir -p "$ARTIFACT_DIR"
OUT_DMG="$ARTIFACT_DIR/${APP_NAME}_${VERSION}_${ARCH_LABEL}.dmg"
cp -f "$DMG" "$OUT_DMG"
ok "构建完成"
echo "App: $APP"
echo "DMG: $OUT_DMG"

if [[ "$INSTALL" == "1" ]]; then
  DEST="/Applications/$APP_NAME.app"
  info "安装到 $DEST ..."

  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true

  if [[ -d "$DEST" ]]; then
    if ! rm -rf "$DEST" 2>/dev/null; then
      warn "/Applications 需要管理员权限，使用 sudo 覆盖安装"
      sudo rm -rf "$DEST"
    fi
  fi

  if ! ditto "$APP" "$DEST" 2>/dev/null; then
    warn "写入 /Applications 需要管理员权限，使用 sudo"
    sudo ditto "$APP" "$DEST"
  fi

  # 本地构建一般没有隔离属性；这里兜底清除，避免 Gatekeeper 拦截
  xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || sudo xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
  ok "已安装: $DEST"

  if [[ "$LAUNCH" == "1" ]]; then
    info "启动 $APP_NAME ..."
    open "$DEST"
  fi
elif [[ "$LAUNCH" == "1" ]]; then
  info "启动构建产物 $APP_NAME ..."
  open "$APP"
fi

echo "=================================================="
ok "macOS 打包完成"
echo "DMG: $OUT_DMG"
echo "签名: ad-hoc（未公证）"
echo "分发后首次打开如提示「已损坏」或「无法验证开发者」，执行："
echo "  sudo xattr -rd com.apple.quarantine \"/Applications/$APP_NAME.app\""
echo "=================================================="
