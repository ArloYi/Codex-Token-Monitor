#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
VERSION=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleShortVersionString" \
  "$ROOT_DIR/App/Info.plist")
DIST_DIR="$ROOT_DIR/dist"
APP_PATH=$(/bin/zsh "$ROOT_DIR/scripts/build-app.sh")
ARCHIVE_NAME="Codex-Quota-HUD-$VERSION-macos-universal.zip"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

mkdir -p "$DIST_DIR"
rm -f "$ARCHIVE_PATH"
rm -f "$CHECKSUM_PATH"
(
  cd "$ROOT_DIR/build"
  COPYFILE_DISABLE=1 /usr/bin/zip \
    -qry "$ARCHIVE_PATH" "Codex Quota HUD.app"
)
(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)

echo "$ARCHIVE_PATH"
echo "$CHECKSUM_PATH"
