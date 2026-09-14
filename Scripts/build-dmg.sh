#!/usr/bin/env bash
#
# build-dmg.sh — package a signed .app into a styled, signed DMG.
#
#   Scripts/build-dmg.sh <app-path> <output-dmg> <signing-identity>
#
# Kept as a script rather than inline workflow steps so it can be run locally,
# which matters: every problem here (window geometry, the background not
# applying, the Applications symlink landing in the wrong place) is visual, and
# the CI log cannot show you a Finder window.
set -euo pipefail

APP_PATH="${1:?usage: build-dmg.sh <app-path> <output-dmg> <identity>}"
OUT_DMG="${2:?usage: build-dmg.sh <app-path> <output-dmg> <identity>}"
IDENTITY="${3:?usage: build-dmg.sh <app-path> <output-dmg> <identity>}"

APP_NAME="$(basename "$APP_PATH" .app)"
VOL_NAME="$APP_NAME"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Size the image from the payload rather than hard-coding: a fixed size is
# either wasteful or, once the app grows, a build failure that looks unrelated.
APP_KB=$(du -sk "$APP_PATH" | cut -f1)
DMG_MB=$(( (APP_KB / 1024) + 60 ))   # headroom for the background and metadata

echo "==> creating ${DMG_MB}MB image for ${APP_NAME}"
hdiutil create -volname "$VOL_NAME" -fs HFS+ -size "${DMG_MB}m" "$WORK/temp.dmg" -quiet

ATTACH_OUT=$(hdiutil attach -readwrite -noverify "$WORK/temp.dmg")
DEVICE=$(echo "$ATTACH_OUT" | head -1 | awk '{print $1}')
MOUNT="/Volumes/$VOL_NAME"
# Detach on any failure, or the runner leaks a mounted image and the next
# attach picks a different volume name, which breaks the AppleScript silently.
trap 'hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

cp -R "$APP_PATH" "$MOUNT/"
ln -s /Applications "$MOUNT/Applications" 2>/dev/null || true

if [ -f "Resources/dmg-background.png" ]; then
  mkdir -p "$MOUNT/.background"
  cp "Resources/dmg-background.png" "$MOUNT/.background/background.png"
fi

sleep 2
# Finder scripting is best-effort throughout: it fails on a runner with no
# window server in ways that do not matter, and an unstyled DMG still installs
# perfectly well. Never let cosmetics fail a release.
osascript <<OSA || echo "note: Finder styling unavailable; shipping an unstyled DMG"
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    delay 2
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 200, 860, 600}
    set viewOptions to icon view options of container window
    set icon size of viewOptions to 100
    try
      set background picture of viewOptions to file ".background:background.png"
    end try
    try
      set position of item "$APP_NAME.app" of container window to {145, 185}
    end try
    try
      set position of item "Applications" of container window to {515, 185}
    end try
    close
    delay 1
  end tell
end tell
OSA

sleep 2
hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true
trap 'rm -rf "$WORK"' EXIT
sleep 1

mkdir -p "$(dirname "$OUT_DMG")"
hdiutil convert "$WORK/temp.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT_DMG" -quiet
codesign --force --sign "$IDENTITY" --timestamp "$OUT_DMG"

echo "==> $OUT_DMG"
