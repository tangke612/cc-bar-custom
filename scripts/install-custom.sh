#!/bin/bash
#
# install-custom.sh — 一键下载并安装/升级最新定制版 CCBar 到 macOS /Applications
#
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/tangke612/cc-bar-custom/custom/scripts/install-custom.sh | bash
#
set -euo pipefail

REPO="tangke612/cc-bar-custom"
APP_DEST="/Applications/CCBar.app"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "❌ 此安装脚本仅支持 macOS。" >&2
  exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "❌ 定制版安装包目前仅支持 Apple Silicon (arm64) Mac。" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ccbar-install.XXXXXX")"
MOUNT_POINT=""
cleanup() {
  if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || hdiutil detach "$MOUNT_POINT" -force -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "==> [1/4] 检查 ${REPO} 最新版本..."
EFFECTIVE_URL="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest")"
LATEST_TAG="${EFFECTIVE_URL##*/}"
DMG_URL="https://github.com/${REPO}/releases/latest/download/CCBar.dmg"
DMG_PATH="$TMP_DIR/CCBar.dmg"

echo "   -> 最新版本: ${LATEST_TAG}"
echo "==> [2/4] 下载 CCBar.dmg..."
curl -fL --progress-bar "$DMG_URL" -o "$DMG_PATH"

echo "==> [3/4] 挂载并校验签名..."
MOUNT_POINT="$(hdiutil attach -nobrowse -readonly "$DMG_PATH" | sed -n 's/.*\(\/Volumes\/.*\)$/\1/p' | tail -n 1)"
if [[ -z "$MOUNT_POINT" || ! -d "$MOUNT_POINT/CCBar.app" ]]; then
  echo "❌ DMG 挂载失败或未找到 CCBar.app" >&2
  exit 1
fi

codesign --verify --deep --strict "$MOUNT_POINT/CCBar.app"

if pgrep -x "CCBar" >/dev/null 2>&1; then
  echo "   -> 正在关闭运行中的旧版 CCBar..."
  osascript -e 'tell application "CCBar" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6; do
    pgrep -x "CCBar" >/dev/null 2>&1 || break
    sleep 0.5
  done
  killall CCBar >/dev/null 2>&1 || true
fi

echo "==> [4/4] 安装到 ${APP_DEST} 并清理隔离标记..."
rm -rf "$APP_DEST"
ditto "$MOUNT_POINT/CCBar.app" "$APP_DEST"
xattr -cr "$APP_DEST"

INSTALLED_VER="$(defaults read "$APP_DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "$LATEST_TAG")"
open "$APP_DEST"

echo
echo "✅ CCBar (${INSTALLED_VER} / ${LATEST_TAG}) 已成功安装并启动！"
