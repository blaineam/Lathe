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
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Apache-2.0</string>
</dict>
</plist>
PLIST

# The icon is a layered Icon Composer document, not a flattened .icns, so
# the system draws the squircle, the glass and the specular pass and derives
# the tinted and dark appearances itself. That means it has to go through
# actool: the compiler turns the document into an Assets.car, and writes the
# Info.plist keys that point at it into a partial plist. `CFBundleIconName`
# is the one that matters — `CFBundleIconFile` alone gets you the fallback
# .icns actool also emits, with none of the system treatment.
echo "==> icon"
python3 "$HERE/make-icon.py" "$HERE/Icon"
ICONBUILD="$(mktemp -d)"
trap 'rm -rf "$ICONBUILD"' EXIT
xcrun actool "$HERE/Icon/Lathe.icon" \
    --compile "$APP/Contents/Resources" \
    --app-icon Lathe \
    --output-partial-info-plist "$ICONBUILD/icon.plist" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --target-device mac \
    --errors --warnings > /dev/null

# actool reports failures in its plist rather than in its exit status, so
# check the plist. Without this the build "succeeds" and ships an app with
# no icon at all.
if /usr/libexec/PlistBuddy -c "Print :com.apple.actool.errors" \
        "$ICONBUILD/icon.plist" > /dev/null 2>&1; then
    echo "icon failed to compile:" >&2
    /usr/libexec/PlistBuddy -c "Print :com.apple.actool.errors" "$ICONBUILD/icon.plist" >&2
    exit 1
fi

for key in CFBundleIconName CFBundleIconFile; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$ICONBUILD/icon.plist" 2>/dev/null || true)"
    [ -n "$value" ] && /usr/libexec/PlistBuddy \
        -c "Add :$key string $value" "$APP/Contents/Info.plist"
done

# App Intents have to be *compiled* to be found.
#
# Declaring an `AppIntent` in Swift is not enough: the system discovers them
# from a Metadata.appintents bundle that a separate tool produces from the
# compiler's const-value output. Xcode runs it as a build phase; SwiftPM does
# not, which is why the intents existed and Shortcuts showed nothing.
#
# Everything it needs is already on disk after the build — the source list and
# the .swiftconstvalues files the compiler emitted — so this is a matter of
# handing them over rather than of generating anything new.
echo "==> app intents"
INTENTS_WORK="$(mktemp -d)"
BUILD_DIR="$(swift build -c release --package-path "$HERE" --show-bin-path)"
SCRATCH="$(dirname "$(dirname "$BUILD_DIR")")"

find "$HERE/Sources/LatheApp" -name "*.swift" > "$INTENTS_WORK/sources.txt"
find "$SCRATCH" -name "*.swiftconstvalues" -path "*LatheApp*" -path "*Release*" \
    > "$INTENTS_WORK/constvalues.txt"

TOOLCHAIN="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
if [ -s "$INTENTS_WORK/constvalues.txt" ] && xcrun appintentsmetadataprocessor \
        --output "$APP/Contents/Resources" \
        --toolchain-dir "$TOOLCHAIN" \
        --module-name LatheApp \
        --sdk-root "$(xcrun --show-sdk-path --sdk macosx)" \
        --xcode-version "$(xcodebuild -version | tail -1 | awk '{print $3}')" \
        --platform-family macOS \
        --deployment-target 26.0 \
        --target-triple arm64-apple-macos26.0 \
        --bundle-identifier com.lathe.app \
        --source-file-list "$INTENTS_WORK/sources.txt" \
        --swift-const-vals-list "$INTENTS_WORK/constvalues.txt" \
        --quiet-warnings > /dev/null 2>&1; then
    echo "    intents: $(ls "$APP/Contents/Resources" | grep -c appintents) bundle(s)"
else
    # Not fatal. Every other way into the app still works, and a release that
    # fails because Siri phrases did not compile would be a poor trade.
    echo "    note: App Intents metadata could not be built; Shortcuts will not see them"
fi
rm -rf "$INTENTS_WORK"

# Launch Services caches an app's icon by bundle path, so a rebuilt bundle
# at the same path keeps showing the previous icon until the cache is told
# otherwise. Touching the bundle is what invalidates that.
touch "$APP"

echo "==> $APP"
echo "    First launch: right-click → Open, because it is not signed."
