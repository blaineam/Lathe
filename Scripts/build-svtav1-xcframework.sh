#!/bin/bash
#
# build-svtav1-xcframework.sh — build the SVT-AV1 encoder library `LatheAV1`
# links.
#
#   Scripts/build-svtav1-xcframework.sh              # -> Artifacts/SvtAv1Enc.xcframework.zip
#   Scripts/build-svtav1-xcframework.sh <out-dir>    # somewhere else
#   SVT_TAG=v4.3.0 Scripts/build-svtav1-xcframework.sh
#
# ## Why a binary
#
# No Apple device encodes AV1 in hardware — VideoToolbox decodes it on newer
# chips and encodes it nowhere — so AV1 output needs a software encoder in the
# process. SVT-AV1 is that encoder. It is ~340 C files arranged per instruction
# set and configured by CMake; SwiftPM cannot express per-architecture sources,
# so a source vendoring (the way libwebp is vendored) would have to drop every
# SIMD kernel and run several times slower. It is built here instead and
# published as a release asset, the way LAME is.
#
# ## Licence
#
# BSD-3-Clause-Clear, plus the Alliance for Open Media Patent License 1.0.
# Both texts are copied into the xcframework. The Clear variant grants no
# patent rights itself; those come from the AOMedia licence, which ends for
# anyone who brings an AV1 patent claim against its licensors.
#
# ## What this builds
#
#   macos-arm64_x86_64              macOS 14
#   ios-arm64                       iOS 17
#   ios-arm64_x86_64-simulator      iOS 17 Simulator
#
# Static libraries, encoder only. Apple silicon slices keep SVT-AV1's NEON,
# dot-product and I8MM kernels, chosen at run time; SVE and SVE2 are off
# because no Apple chip implements either. Intel slices are built C-only:
# their kernels are assembly that needs nasm, and an Intel Mac encoding AV1 on
# the CPU is not the case worth a build dependency. Logging is compiled out.
#
# Each build gets its own CMAKE_OUTPUT_DIRECTORY. Upstream's default is
# `Bin/<config>` inside the source tree, shared by every build directory, so
# the slices would silently overwrite one library.
#
# Needs cmake and ninja.
set -euo pipefail

SVT_TAG="${SVT_TAG:-v4.2.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$ROOT/Artifacts}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lathe-svtav1.XXXXXX")"
SRC="${TMPDIR:-/tmp}/lathe-svtav1-src-$SVT_TAG"
MAC_MIN=14.0
IOS_MIN=17.0

command -v cmake >/dev/null || { echo "cmake is required" >&2; exit 1; }
command -v ninja >/dev/null || { echo "ninja is required" >&2; exit 1; }

if [ ! -d "$SRC/.git" ]; then
    git clone --depth 1 --branch "$SVT_TAG" https://gitlab.com/AOMediaCodec/SVT-AV1.git "$SRC"
fi
COMMIT="$(git -C "$SRC" rev-parse HEAD)"

# build <name> <sysroot> <arch> <min-flag> [extra cmake args...]
build() {
    local name="$1" sysroot="$2" arch="$3" min_flag="$4"
    shift 4
    local dir="$WORK/build-$name"
    local system=iOS
    [ "$sysroot" = macosx ] && system=Darwin
    cmake -S "$SRC" -B "$dir" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME="$system" \
        -DCMAKE_SYSTEM_PROCESSOR="$arch" \
        -DCMAKE_OSX_SYSROOT="$sysroot" \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_C_FLAGS="$min_flag -ffile-prefix-map=$SRC=svt-av1" \
        -DCMAKE_CXX_FLAGS="$min_flag -ffile-prefix-map=$SRC=svt-av1" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_APPS=OFF \
        -DREPRODUCIBLE_BUILDS=ON \
        -DBUILD_TESTING=OFF \
        -DSVT_AV1_LTO=OFF \
        -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
        -DLOG_QUIET=ON \
        -DCMAKE_OUTPUT_DIRECTORY="$dir/out" \
        "$@" >"$dir.log" 2>&1 || { tail -40 "$dir.log" >&2; exit 1; }
    ninja -C "$dir" SvtAv1Enc >>"$dir.log" 2>&1 || { tail -40 "$dir.log" >&2; exit 1; }
    test -f "$dir/out/libSvtAv1Enc.a"
    strip -S -x "$dir/out/libSvtAv1Enc.a" 2>/dev/null || true
    echo "$dir/out/libSvtAv1Enc.a"
}

ARM=(-DENABLE_SVE=OFF -DENABLE_SVE2=OFF)
INTEL=(-DCOMPILE_C_ONLY=ON)

echo "building SVT-AV1 $SVT_TAG ($COMMIT)"
MAC_ARM="$(build mac-arm64 macosx arm64 "-mmacosx-version-min=$MAC_MIN" "${ARM[@]}")"
MAC_X86="$(build mac-x86_64 macosx x86_64 "-mmacosx-version-min=$MAC_MIN" "${INTEL[@]}")"
IOS_ARM="$(build ios-arm64 iphoneos arm64 "-miphoneos-version-min=$IOS_MIN" "${ARM[@]}")"
SIM_ARM="$(build sim-arm64 iphonesimulator arm64 "-mios-simulator-version-min=$IOS_MIN" "${ARM[@]}")"
SIM_X86="$(build sim-x86_64 iphonesimulator x86_64 "-mios-simulator-version-min=$IOS_MIN" "${INTEL[@]}")"

mkdir -p "$WORK/mac" "$WORK/sim"
lipo -create "$MAC_ARM" "$MAC_X86" -output "$WORK/mac/libSvtAv1Enc.a"
lipo -create "$SIM_ARM" "$SIM_X86" -output "$WORK/sim/libSvtAv1Enc.a"

# The public headers, and a module map so Swift can `import SvtAv1Enc`.
HEADERS="$WORK/headers"
mkdir -p "$HEADERS"
cp "$SRC"/Source/API/*.h "$HEADERS/"
cat > "$HEADERS/module.modulemap" <<'EOF'
module SvtAv1Enc {
    header "EbSvtAv1Enc.h"
    link "SvtAv1Enc"
    export *
}
EOF

FRAMEWORK="$WORK/SvtAv1Enc.xcframework"
xcodebuild -create-xcframework \
    -library "$WORK/mac/libSvtAv1Enc.a" -headers "$HEADERS" \
    -library "$IOS_ARM" -headers "$HEADERS" \
    -library "$WORK/sim/libSvtAv1Enc.a" -headers "$HEADERS" \
    -output "$FRAMEWORK" >/dev/null

cp "$SRC/LICENSE.md" "$FRAMEWORK/LICENSE.md"
cp "$SRC/PATENTS.md" "$FRAMEWORK/PATENTS.md"
printf '%s\n%s\n' "$SVT_TAG" "$COMMIT" > "$FRAMEWORK/VERSION"

# Pinned times and sorted entries, so one toolchain gives one checksum.
find "$FRAMEWORK" -exec touch -h -t 202001010000 {} +
mkdir -p "$OUT_DIR"
ZIP="$OUT_DIR/SvtAv1Enc.xcframework.zip"
rm -f "$ZIP"
(cd "$WORK" && find SvtAv1Enc.xcframework | LC_ALL=C sort | zip -X -q "$ZIP" -@)

echo "wrote $ZIP"
swift package compute-checksum "$ZIP"
rm -rf "$WORK"
