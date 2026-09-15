#!/bin/bash
#
# Builds Lathe.app.
#
#   ./App/make-app.sh && open ./App/build/Lathe.app
#
# A hand-assembled bundle rather than an Xcode project, on purpose: the whole
# repository builds with `swift build`, and adding a .xcodeproj would mean a
# second source of truth for the build that has to be kept in step by hand.
# A .app is a directory with an Info.plist in it; this makes that directory.
#
# Not signed. macOS will refuse to open it on first launch — right-click and
# Open, or `xattr -dr com.apple.quarantine`. Signing and notarisation live in
# the release workflow, which needs a Developer ID this script does not have.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/build"
APP="$BUILD/Lathe.app"
VERSION="${1:-0.1.0}"

echo "==> building"
swift build -c release --package-path "$HERE"
BIN="$(swift build -c release --package-path "$HERE" --show-bin-path)/LatheApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lathe"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Lathe</string>
    <key>CFBundleDisplayName</key><string>Lathe</string>
    <key>CFBundleIdentifier</key><string>com.lathe.app</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleExecutable</key><string>Lathe</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Apache-2.0</string>
</dict>
</plist>
PLIST

"$HERE/make-icon.sh" "$APP/Contents/Resources/AppIcon.icns"

echo "==> $APP"
echo "    First launch: right-click → Open, because it is not signed."
