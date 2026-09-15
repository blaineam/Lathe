#!/bin/bash
#
# Refreshes Sources/CLAME/upstream/ from a pinned LAME release.
#
#   ./refresh-upstream.sh          # re-vendor the pinned version
#   ./refresh-upstream.sh 3.100    # vendor a different one
#
# Everything copied is copied byte-for-byte; nothing is patched. The one file
# this script WRITES rather than copies is config.h, because LAME's own is
# produced by autoconf and this package does not run autoconf.
#
# If you bump the version, update VENDORING.md with what this prints, then run
# `swift build && swift test`.
set -euo pipefail

LAME_VERSION="${1:-3.100}"
LAME_URL="https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz"

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HERE/upstream"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> fetching $LAME_URL"
curl -sL --fail -o "$WORK/lame.tar.gz" "$LAME_URL"
SHA="$(shasum -a 256 "$WORK/lame.tar.gz" | cut -d' ' -f1)"
tar xzf "$WORK/lame.tar.gz" -C "$WORK"
SRC="$WORK/lame-${LAME_VERSION}"

rm -rf "$DEST"
mkdir -p "$DEST/libmp3lame" "$HERE/include"

# --- What gets vendored -------------------------------------------------------
#
# libmp3lame — the encoder. Every .c and .h EXCEPT mpglib_interface.c, which is
#              the bridge to LAME's bundled MPEG *decoder*. Nothing here decodes
#              an MP3: Apple's own decoder does that, and vendoring a second one
#              would add code this package never calls.
# include     — lame.h, the public API, which becomes the module's header.
#
# NOT vendored, and this one is a LICENCE decision rather than a size one:
# mpglib, LAME's bundled MPEG decoder, is GPL where the encoder is LGPL. Taking
# it would make this target GPL and take the whole question out of the
# consumer's hands. mpglib_interface.c is excluded above for the same reason.
#
# Also not vendored: the i386 NASM assembly (no assembler in this build and no
# 32-bit x86 target), the command-line front end, mpglib, the test programs,
# the Windows and DOS projects, and the autotools machinery.
for file in "$SRC"/libmp3lame/*.c "$SRC"/libmp3lame/*.h; do
    name="$(basename "$file")"
    [ "$name" = "mpglib_interface.c" ] && continue
    cp "$file" "$DEST/libmp3lame/$name"
done
# libmp3lame/vector — the SSE intrinsics. Vendored even though this package
# targets Apple silicon, because fft.c and quantize.c include the header
# UNCONDITIONALLY and only its contents are guarded by HAVE_XMMINTRIN_H. On
# arm64 these files compile to nothing; leaving them out breaks the build.
mkdir -p "$DEST/libmp3lame/vector"
cp "$SRC"/libmp3lame/vector/*.c "$SRC"/libmp3lame/vector/*.h "$DEST/libmp3lame/vector/" 2>/dev/null || true

cp "$SRC/include/lame.h" "$HERE/include/lame.h"
cp "$SRC/COPYING" "$DEST/COPYING"

# --- config.h -----------------------------------------------------------------
#
# LAME expects the header autoconf generates. This is that header, reduced to
# what Apple platforms actually provide — every value here is a fact about
# darwin, not a guess, and anything LAME probes for that darwin lacks is simply
# left undefined.
#
# HAVE_MPGLIB is deliberately absent: the decoder is not vendored.
cat > "$DEST/config.h" <<'CONFEOF'
/* Written by refresh-upstream.sh — not from upstream, and not autoconf's.
 *
 * LAME's build normally generates this. This package does not run autoconf, so
 * the handful of facts LAME needs about the platform are stated directly. They
 * are facts about Apple platforms rather than probes: darwin has all of these
 * headers and functions, on every architecture this package targets.
 */
#ifndef LATHE_LAME_CONFIG_H
#define LATHE_LAME_CONFIG_H

#define STDC_HEADERS 1
#define HAVE_LIMITS_H 1
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_UNISTD_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_MEMCPY 1
#define HAVE_STRCHR 1

/* HAVE_XMMINTRIN_H is deliberately ABSENT rather than defined to 0. LAME tests
 * it with #ifdef, so defining it as zero still selects the SSE intrinsics path
 * and pulls in libmp3lame/vector/, which is x86-only and is not vendored. This
 * package targets Apple silicon, where the C paths are what get used anyway. */

/* LAME's own version strings, which lame.c reports through the API. */
#define PACKAGE "lame"
#define VERSION "3.100"

/* FLOAT and FLOAT8 are deliberately NOT defined here.
 *
 * machine.h defines them, and defines FLOAT_MAX and FLOAT8_MAX alongside — but
 * only inside the `#ifndef FLOAT` branch it takes when config.h has said
 * nothing. Defining FLOAT here skips that branch, leaves FLOAT_MAX undefined,
 * and the build fails several files later complaining about a constant rather
 * than about the type. Leaving both alone gives exactly what a plain
 * ./configure produces: FLOAT is float, FLOAT8 is double.
 */

/* autoconf APPENDS these typedefs to config.h when the platform does not
 * already declare them, which darwin does not — they come from glibc's
 * <ieee754.h>. Without them util.h does not compile, and the error names the
 * type rather than the missing step, which is why this is written down.
 * ieee854_float80_t is omitted along with HAVE_IEEE854_FLOAT80: long double on
 * arm64 is not the 80-bit format the name refers to. */
typedef float ieee754_float32_t;
typedef double ieee754_float64_t;

/* The IEEE-754 bit trick LAME uses to round floats quickly. Valid on every
 * architecture this package targets, all of which are little-endian IEEE-754. */
#define TAKEHIRO_IEEE754_HACK 1

#endif /* LATHE_LAME_CONFIG_H */
CONFEOF

cat > "$DEST/README-VENDORED.txt" <<TXTEOF
LAME ${LAME_VERSION}, vendored by refresh-upstream.sh.
Source: ${LAME_URL}
SHA-256 of the tarball: ${SHA}

Licence: LGPL (see COPYING). This is the ONLY non-permissive code in Lathe and
it is confined to its own product, LatheMP3, for exactly that reason.
TXTEOF

echo
echo "==> vendored LAME ${LAME_VERSION}"
echo "    tarball sha256: ${SHA}"
echo "    .c files:       $(ls "$DEST"/libmp3lame/*.c | wc -l | tr -d ' ')"
echo
echo "Update VENDORING.md with the version and hash above, then:"
echo "    swift build && swift test"
