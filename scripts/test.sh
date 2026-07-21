#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_BINARY="$ROOT_DIR/build/Codex Quota HUD.app/Contents/MacOS/CodexQuotaHUD"

/bin/zsh "$ROOT_DIR/scripts/privacy-check.sh"
/bin/zsh "$ROOT_DIR/scripts/build-app.sh" >/dev/null

if rg -n \
  "orderFrontRegardless|makeKey|activateIgnoringOtherApps|activateWithOptions|requestUserAttention" \
  "$ROOT_DIR/Sources" "$ROOT_DIR/App"; then
  echo "focus-safety test failed"
  exit 1
fi

for required_pattern in \
  "NSWindowStyleMaskNonactivatingPanel" \
  "ignoresMouseEvents = YES" \
  "_hoverPanel.ignoresMouseEvents = NO" \
  "HoverRevealView" \
  "_hoverRevealView.onDrag" \
  "NSTrackingMouseEnteredAndExited" \
  "setDetailsExpanded" \
  "ResizeGripView" \
  "resizeHUDByDelta" \
  "QuotaStatusBallView" \
  "HUDDockSideNearFrame" \
  "HUDBallFrameForDock" \
  "finishPanelDrag" \
  "HUDMinimumScale" \
  "HUDMaximumScale" \
  "HUDMetricRowView" \
  "QuotaGaugeView" \
  "appendBezierPathWithArcWithCenter" \
  "本周期已用 %.0f%% / 100%%" \
  "HUDBaseExpandedHeight" \
  "frame.origin.y = topEdge - targetHeight" \
  "AdaptiveHUDMaterialView" \
  "AdaptiveHUDMaterialView : NSView" \
  "AdaptiveFontSizeForText" \
  "CodexQuotaResizableGaugeOrigin" \
  "CodexQuotaGaugeScale" \
  "CodexQuotaGaugeDockSide" \
  "CodexQuotaGaugeBallOrigin" \
  "activeThreadFromDatabase" \
  "currentCodexTaskTitleFromAccessibility" \
  "AXIsProcessTrusted" \
  "kAXTrustedCheckOptionPrompt" \
  "ThreadTitleMatchScore" \
  "sessionTitlesByThreadID" \
  "session_index.jsonl" \
  "ProjectSelectionForActiveThread" \
  "PathBelongsToProject" \
  "thread_source = 'user'" \
  "--project-snapshot" \
  "NSWorkspaceDidActivateApplicationNotification" \
  "orderOut:nil"; do
  if ! rg -q -- "$required_pattern" "$ROOT_DIR/Sources/main.m"; then
    echo "floating-window safety contract missing: $required_pattern"
    exit 1
  fi
done

if rg -n "NSVisualEffectView|NSVisualEffectMaterial" \
  "$ROOT_DIR/Sources/main.m"; then
  echo "transparent-window test failed: rectangular visual effect backdrop"
  exit 1
fi

if [[ $(rg -c "orderFront:nil" "$ROOT_DIR/Sources/main.m") -ne 1 ]]; then
  echo "floating-window safety contract failed: orderFront count"
  exit 1
fi

if rg -n "NSStatusBar|NSStatusItem" "$ROOT_DIR/Sources/main.m"; then
  echo "menu-bar removal test failed"
  exit 1
fi

"$APP_BINARY" --self-test
plutil -lint "$ROOT_DIR/App/Info.plist"
codesign --verify --deep --strict "$ROOT_DIR/build/Codex Quota HUD.app"

architectures=$(lipo -archs "$APP_BINARY")
if [[ "$architectures" != *"arm64"* ||
      "$architectures" != *"x86_64"* ]]; then
  echo "universal binary test failed: $architectures"
  exit 1
fi

bundle_id=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleIdentifier" \
  "$ROOT_DIR/App/Info.plist")
if [[ "$bundle_id" != "com.arlo.codex-quota-menu" ]]; then
  echo "bundle identity test failed: $bundle_id"
  exit 1
fi

if rg -n "com\\.arlo\\.codex-quota-hud" \
  "$ROOT_DIR/App" "$ROOT_DIR/Sources" "$ROOT_DIR/scripts"; then
  echo "stale bundle identity test failed"
  exit 1
fi

if ! rg -q 'CFBundleShortVersionString' "$ROOT_DIR/Sources/main.m"; then
  echo "runtime version source test failed"
  exit 1
fi

if ! rg -q 'poll\(' "$ROOT_DIR/Sources/main.m"; then
  echo "app-server timeout guard missing"
  exit 1
fi

echo "all tests passed"
