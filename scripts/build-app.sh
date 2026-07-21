#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/Codex Quota HUD.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

mkdir -p "$MACOS_DIR"
rm -rf "$BUILD_DIR/module-cache"
mkdir -p "$BUILD_DIR/module-cache"

xcrun clang \
  -arch arm64 \
  -arch x86_64 \
  -mmacosx-version-min=13.0 \
  -fobjc-arc \
  -fmodules \
  -fmodules-cache-path="$BUILD_DIR/module-cache" \
  -O \
  -framework AppKit \
  -framework ApplicationServices \
  "$ROOT_DIR/Sources/main.m" \
  -o "$MACOS_DIR/CodexQuotaHUD"

cp "$ROOT_DIR/App/Info.plist" "$CONTENTS_DIR/Info.plist"
codesign --force --sign - "$APP_DIR"

echo "$APP_DIR"
