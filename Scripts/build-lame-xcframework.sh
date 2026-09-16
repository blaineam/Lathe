#!/bin/bash
#
# build-lame-xcframework.sh — turn the vendored LAME source into the dynamic
# framework `LatheMP3` links.
#
#   Scripts/build-lame-xcframework.sh              # -> Artifacts/lame.xcframework.zip
#   Scripts/build-lame-xcframework.sh <out-dir>    # somewhere else
#
# ## Why a dynamic framework, and why only LAME's C in it
#
# LAME is LGPL. The LGPL expects that whoever receives an application can
# replace the library with their own build of it, and the established way to
# allow that on Apple platforms is to ship the LGPL code as its own dynamic
# framework inside the app bundle, beside — not inside — the application's code.
# See Vendor/LAME/VENDORING.md.
#
# The framework holds LAME and nothing else. `LatheMP3` itself stays a static
# Swift module: if it were dynamic it would carry its own copy of `LatheCore`,
# the app would link another, and `catch let e as LatheError` would stop
# matching errors thrown by the MP3 code, because there would be two
# `LatheError` types.
#
# ## What this builds
#
#   ios-arm64                       iOS 17 device
#   ios-arm64_x86_64-simulator      iOS 17 Simulator
#   macos-arm64_x86_64              macOS 14 (a versioned bundle, as macOS requires)
#
# Every slice has an Info.plist, the public `lame.h`, a module map declaring the
# `lame` module, LAME's own licence text, and an ad-hoc signature — so the
# framework validates as it stands, and the embedding app re-signs it with its
# own identity. No bitcode: it is deprecated and App Store Connect refuses it.
#
# Only the functions `lame.h` declares are exported; LAME's internals are
# hidden, so they cannot collide with anything else in a process.
#
# ## Reproducible, as far as the toolchain is
#
# The inputs are exactly Vendor/LAME/upstream, which refresh-upstream.sh
# copies byte for byte from the SHA-256-pinned tarball. Source paths are mapped
# out of the binary, file times are pinned and the archive is written in sorted
# order, so the same Xcode produces the same zip and the same checksum twice. A
# different Xcode is a different compiler and will not — which is why the
# checksum SwiftPM pins belongs to a published release asset rather than to a
# rebuild.
#
# Everything is built in a temporary directory, not in the repository: the
# repository may live on a share that stamps extended attributes, and codesign
# refuses a bundle carrying them.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LAME_DIR="$ROOT/Vendor/LAME"
SRC="$LAME_DIR/upstream"
OUT_DIR="${1:-$ROOT/Artifacts}"

NAME="lame"
BUNDLE_ID="com.lathe.lame"
IOS_MIN="17.0"
MACOS_MIN="14.0"

# The version the framework reports is the version that was vendored.
LAME_VERSION="$(sed -n 's/^#define VERSION "\(.*\)"$/\1/p' "$SRC/config.h")"
[ -n "$LAME_VERSION" ] || { echo "error: no VERSION in $SRC/config.h" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lame-xcframework.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

export ZERO_AR_DATE=1
export SOURCE_DATE_EPOCH=0

SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(
    cd "$SRC" && find libmp3lame -name '*.c' | LC_ALL=C sort
)

CFLAGS=(
    -std=gnu99
    -O2
    -fPIC
    -DHAVE_CONFIG_H
    -DNDEBUG
    -I"$SRC"
    -I"$SRC/libmp3lame"
    -I"$LAME_DIR/include"
    # No absolute paths from this machine end up in the binary.
    -ffile-prefix-map="$SRC"=lame
    -ffile-prefix-map="$LAME_DIR"=lame
    # LAME's sources warn heavily under modern clang and none of it is
    # actionable without patching upstream, which this package does not do.
    -Wno-everything
)

compile_slice() {  # <target-triple> <sdk> <objdir>
    local triple="$1" sdk="$2" objdir="$3"
    local sysroot
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    mkdir -p "$objdir"
    local src obj
    for src in "${SOURCES[@]}"; do
        obj="$objdir/$(echo "$src" | tr '/' '_').o"
        xcrun --sdk "$sdk" clang -target "$triple" -isysroot "$sysroot" \
            "${CFLAGS[@]}" -c "$SRC/$src" -o "$obj"
    done
}

# --- Exports ------------------------------------------------------------------
#
# Every function `lame.h` declares that the vendored sources define. The
# intersection matters: lame.h also declares the hip_* decoder API, which lives
# in mpglib — GPL, and deliberately not vendored — so those names are declared
# and never defined, and exporting them would fail the link.
declared_symbols() {
    # Identifiers immediately followed by "(" in lame.h — every prototype — as
    # linker symbol names.
    grep -oE '\b(lame|hip|get_lame|id3tag)_[A-Za-z0-9_]*[[:space:]]*\(' "$LAME_DIR/include/lame.h" \
        | sed -E 's/[[:space:]]*\($//' | LC_ALL=C sort -u | sed 's/^/_/'
}

link_dylib() {  # <target-triple> <sdk> <objdir> <install-name> <out>
    local triple="$1" sdk="$2" objdir="$3" install_name="$4" out="$5"
    local sysroot
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"

    # What the objects define, intersected with what the header declares.
    xcrun nm -gUj "$objdir"/*.o 2>/dev/null | LC_ALL=C sort -u > "$objdir/defined.txt"
    declared_symbols > "$objdir/declared.txt"
    LC_ALL=C comm -12 "$objdir/defined.txt" "$objdir/declared.txt" > "$objdir/exports.txt"
    [ -s "$objdir/exports.txt" ] || { echo "error: no exported symbols for $triple" >&2; exit 1; }

    xcrun --sdk "$sdk" clang -target "$triple" -isysroot "$sysroot" \
        -dynamiclib \
        -install_name "$install_name" \
        -compatibility_version 1.0 \
        -current_version "$LAME_VERSION" \
        -Wl,-exported_symbols_list,"$objdir/exports.txt" \
        -Wl,-dead_strip \
        -Wl,-no_adhoc_codesign \
        -o "$out" "$objdir"/*.o
    xcrun strip -x "$out"
}

write_info_plist() {  # <out> <platform> <min-key> <min-version>
    local out="$1" platform="$2" min_key="$3" min_version="$4"
    cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$NAME</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>$LAME_VERSION</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>$platform</string>
	</array>
	<key>CFBundleVersion</key>
	<string>$LAME_VERSION</string>
	<key>NSHumanReadableCopyright</key>
	<string>LAME is free software under the GNU Library General Public License, version 2 or later. See COPYING.</string>
	<key>$min_key</key>
	<string>$min_version</string>
</dict>
</plist>
PLIST
    plutil -lint -s "$out"
}

write_module_map() {  # <out>
    cat > "$1" <<'MAP'
framework module lame {
    umbrella header "lame.h"
    export *
}
MAP
}

# One architecture stays a thin binary; lipo would wrap it in a fat header.
merge_slices() {  # <out> <binary>...
    local out="$1"; shift
    if [ "$#" -eq 1 ]; then
        cp "$1" "$out"
    else
        xcrun lipo -create "$@" -output "$out"
    fi
}

# An iOS framework is a flat bundle.
make_ios_framework() {  # <dest-dir> <platform> <objdir-triple:sdk>...
    local dest="$1" platform="$2"; shift 2
    local fw="$dest/$NAME.framework"
    mkdir -p "$fw/Headers" "$fw/Modules"
    local slices=() spec triple sdk objdir
    for spec in "$@"; do
        triple="${spec%%:*}"; sdk="${spec##*:}"
        objdir="$WORK/obj/$triple"
        compile_slice "$triple" "$sdk" "$objdir"
        link_dylib "$triple" "$sdk" "$objdir" "@rpath/$NAME.framework/$NAME" "$objdir/$NAME"
        slices+=("$objdir/$NAME")
    done
    merge_slices "$fw/$NAME" "${slices[@]}"
    cp "$LAME_DIR/include/lame.h" "$fw/Headers/lame.h"
    write_module_map "$fw/Modules/module.modulemap"
    cp "$SRC/COPYING" "$fw/COPYING"
    write_info_plist "$fw/Info.plist" "$platform" MinimumOSVersion "$IOS_MIN"
}

# A macOS framework must be a versioned bundle, or codesign and notarization
# refuse it.
make_macos_framework() {  # <dest-dir> <objdir-triple:sdk>...
    local dest="$1"; shift
    local fw="$dest/$NAME.framework"
    local v="$fw/Versions/A"
    mkdir -p "$v/Headers" "$v/Modules" "$v/Resources"
    local slices=() spec triple sdk objdir
    for spec in "$@"; do
        triple="${spec%%:*}"; sdk="${spec##*:}"
        objdir="$WORK/obj/$triple"
        compile_slice "$triple" "$sdk" "$objdir"
        link_dylib "$triple" "$sdk" "$objdir" "@rpath/$NAME.framework/Versions/A/$NAME" "$objdir/$NAME"
        slices+=("$objdir/$NAME")
    done
    merge_slices "$v/$NAME" "${slices[@]}"
    cp "$LAME_DIR/include/lame.h" "$v/Headers/lame.h"
    write_module_map "$v/Modules/module.modulemap"
    cp "$SRC/COPYING" "$v/Resources/COPYING"
    write_info_plist "$v/Resources/Info.plist" MacOSX LSMinimumSystemVersion "$MACOS_MIN"
    ln -s A "$fw/Versions/Current"
    for link in Headers Modules Resources "$NAME"; do
        ln -s "Versions/Current/$link" "$fw/$link"
    done
}

sign() {  # <framework>
    # Ad hoc, and without a timestamp, so the signature is a function of the
    # bytes alone. The embedding app replaces it with its own.
    xattr -cr "$1"
    codesign --force --sign - --timestamp=none "$1"
    codesign --verify --strict --verbose=1 "$1"
}

echo "==> LAME $LAME_VERSION, ${#SOURCES[@]} translation units"

echo "==> iOS device"
make_ios_framework "$WORK/ios" iPhoneOS \
    "arm64-apple-ios$IOS_MIN:iphoneos"
echo "==> iOS Simulator"
make_ios_framework "$WORK/ios-simulator" iPhoneSimulator \
    "arm64-apple-ios$IOS_MIN-simulator:iphonesimulator" \
    "x86_64-apple-ios$IOS_MIN-simulator:iphonesimulator"
echo "==> macOS"
make_macos_framework "$WORK/macos" \
    "arm64-apple-macos$MACOS_MIN:macosx" \
    "x86_64-apple-macos$MACOS_MIN:macosx"

for fw in "$WORK"/ios/$NAME.framework "$WORK"/ios-simulator/$NAME.framework "$WORK"/macos/$NAME.framework; do
    sign "$fw"
done

echo "==> xcframework"
xcodebuild -create-xcframework \
    -framework "$WORK/ios/$NAME.framework" \
    -framework "$WORK/ios-simulator/$NAME.framework" \
    -framework "$WORK/macos/$NAME.framework" \
    -output "$WORK/stage/$NAME.xcframework" >/dev/null

# xcodebuild lists the slices in whatever order it finished them, which differs
# from run to run and would change the checksum of identical binaries.
/usr/bin/python3 - "$WORK/stage/$NAME.xcframework/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as f:
    info = plistlib.load(f)
info["AvailableLibraries"].sort(key=lambda lib: lib["LibraryIdentifier"])
with open(path, "wb") as f:
    plistlib.dump(info, f, sort_keys=True)
PY

# Pinned times and a sorted file list, so the archive is a function of its
# contents. -y keeps the macOS bundle's symlinks as symlinks.
(
    cd "$WORK/stage"
    find "$NAME.xcframework" -exec touch -h -t 200001010000 {} +
    find "$NAME.xcframework" | LC_ALL=C sort | zip -q -X -y -@ "$WORK/$NAME.xcframework.zip"
)

mkdir -p "$OUT_DIR"
cp "$WORK/$NAME.xcframework.zip" "$OUT_DIR/$NAME.xcframework.zip"

echo
echo "==> slices"
for bin in "$WORK"/stage/$NAME.xcframework/*/$NAME.framework/$NAME \
           "$WORK"/stage/$NAME.xcframework/*/$NAME.framework/Versions/A/$NAME; do
    [ -f "$bin" ] && [ ! -L "$bin" ] || continue
    echo "  ${bin#"$WORK/stage/"}: $(xcrun lipo -archs "$bin")"
done
echo
echo "==> $OUT_DIR/$NAME.xcframework.zip ($(du -h "$OUT_DIR/$NAME.xcframework.zip" | cut -f1 | tr -d ' '))"
# What goes in Package.swift's `checksum:` once the zip is a release asset.
# SwiftPM's checksum is the archive's SHA-256; shasum stands in if there is no
# package to run the command in.
if [ -f "$ROOT/Package.swift" ]; then
    CHECKSUM="$(cd "$ROOT" && swift package compute-checksum "$OUT_DIR/$NAME.xcframework.zip")"
else
    CHECKSUM="$(shasum -a 256 "$OUT_DIR/$NAME.xcframework.zip" | cut -d' ' -f1)"
fi
echo "    checksum: $CHECKSUM"
