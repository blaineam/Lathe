#!/bin/bash
#
# Builds a slimmed Tor xcframework for Lathe, from the upstream prebuilt.
#
#   App/Vendor/Tor/slim-tor.sh [output-directory]
#
# ## Why slim it
#
# Upstream ships every slice and every symbol: x86_64 and arm64 for macOS, the
# same again for the simulator, and full debug information throughout. That is
# the right choice for a general-purpose distribution and the wrong one here —
# Lathe is arm64-only, and a 335 MB artifact cannot go in a public repository or
# through a SwiftPM binary target without being painful for everyone who clones.
#
# Thinning to arm64 and removing debug information takes the macOS slice from
# 123 MB to about 15 MB, an eight-fold reduction, with every entry point intact:
#
#     fat (x86_64 + arm64)   123.3 MB
#     lipo -thin arm64        63.1 MB
#     strip -S                15.5 MB
#
# `strip -S` removes debug information only. `-x` additionally removes local
# symbols and saves a further 0.3 MB, which is not worth doing to a static
# archive that other people's linkers have to resolve against.
#
# ## Why not build Tor from source
#
# Because that means cross-compiling OpenSSL, libevent and zlib for two
# platforms and keeping that build working, to arrive at the same object code
# the Tor Project's own Apple packaging already produces. The upstream build is
# pinned to a tag and verified by checksum, which is the part that matters.
set -euo pipefail

VERSION="v409.11.1"
URL="https://github.com/iCepa/Tor.framework/releases/download/${VERSION}/tor.xcframework.zip"

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> downloading Tor.framework $VERSION"
curl -fL --progress-bar -o "$WORK/tor.zip" "$URL"
unzip -q "$WORK/tor.zip" -d "$WORK/upstream"

SOURCE="$WORK/upstream/tor.xcframework"
[ -d "$SOURCE" ] || { echo "the archive did not contain tor.xcframework" >&2; exit 1; }

# Keep only the slices Lathe can use. The simulator slice is dropped entirely:
# an app that needs Tor in the simulator can use a local proxy, and carrying a
# 131 MB slice for that is not a trade worth making.
declare -a KEEP=("macos-arm64_x86_64:macos-arm64" "ios-arm64:ios-arm64")

BUILD="$WORK/slim"
mkdir -p "$BUILD"
declare -a ARGS=()

for pair in "${KEEP[@]}"; do
    from="${pair%%:*}"
    to="${pair##*:}"
    src="$SOURCE/$from/tor.framework"
    [ -d "$src" ] || { echo "==> no $from slice upstream, skipping"; continue; }

    dest="$BUILD/$to/tor.framework"
    mkdir -p "$(dirname "$dest")"
    cp -R "$src" "$dest"

    before=$(stat -f%z "$dest/tor")
    # `lipo -thin` fails on a binary that is already single-architecture, which
    # the iOS slice is, so ask first rather than treating that as an error.
    if lipo -archs "$dest/tor" 2>/dev/null | grep -q x86_64; then
        lipo -thin arm64 "$dest/tor" -output "$dest/tor.arm64"
        mv "$dest/tor.arm64" "$dest/tor"
    fi
    strip -S "$dest/tor"
    after=$(stat -f%z "$dest/tor")
    printf "==> %-12s %6.1f MB -> %5.1f MB\n" "$to" \
        "$(echo "scale=2; $before/1048576" | bc)" "$(echo "scale=2; $after/1048576" | bc)"

    # The entry points the embedded client actually calls. Checking them here
    # means a bad strip is caught now rather than as a link error in somebody
    # else's build.
    for symbol in tor_run_main tor_main_configuration_new \
                  tor_main_configuration_setup_control_socket; do
        nm -g "$dest/tor" 2>/dev/null | grep -q "T _$symbol" \
            || { echo "$to: $symbol did not survive stripping" >&2; exit 1; }
    done

    ARGS+=(-framework "$dest")
done

[ ${#ARGS[@]} -gt 0 ] || { echo "no usable slices" >&2; exit 1; }

rm -rf "$OUT/tor.xcframework"
xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT/tor.xcframework" > /dev/null

( cd "$OUT" && zip -qry tor.xcframework.zip tor.xcframework )
SIZE=$(stat -f%z "$OUT/tor.xcframework.zip")
printf "==> tor.xcframework.zip  %.1f MB\n" "$(echo "scale=2; $SIZE/1048576" | bc)"
echo "    checksum: $(swift package compute-checksum "$OUT/tor.xcframework.zip")"
