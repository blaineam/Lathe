#!/bin/bash
#
# Fetches the pinned beeware/Python-Apple-support release for iOS, verifies it
# against a recorded SHA-256, and unpacks it.
#
#   ./fetch-upstream.sh                  # fetch the pinned release into ./.python-apple-support
#   ./fetch-upstream.sh <destination>    # …somewhere else
#   ./fetch-upstream.sh --print-checksum # download and print the hash, for a version bump
#
# NOTHING FETCHED BY THIS SCRIPT IS COMMITTED. The archive is ~32 MB and the
# unpacked tree is ~2,900 files; both are build inputs for an *application*, not
# contents of this package. LatheFetch itself compiles, links and tests with
# none of it present — it binds CPython at run time. See VENDORING.md for why.
#
# macOS is deliberately not fetched: on macOS the host already has a CPython
# framework, and LatheFetch finds it. This script exists for the platform that
# genuinely has no system Python, which is iOS.

set -euo pipefail

# --- The pin -----------------------------------------------------------------
#
# Bump all four together, then re-run with --print-checksum and paste the result.
# See "Refreshing it" in VENDORING.md.

SUPPORT_TAG="3.13-b15"
SUPPORT_BUILD="b15"
PYTHON_SERIES="3.13"
EXPECTED_SHA256="80175765a31babe43b0910395cf86ba4e8412adf1902b069d55b74d523ecc5d1"

REPO="https://github.com/beeware/Python-Apple-support"
ASSET="Python-${PYTHON_SERIES}-iOS-support.${SUPPORT_BUILD}.tar.gz"
URL="${REPO}/releases/download/${SUPPORT_TAG}/${ASSET}"

PRINT_ONLY=0
DEST="./.python-apple-support"
if [ "${1:-}" = "--print-checksum" ]; then
  PRINT_ONLY=1
elif [ -n "${1:-}" ]; then
  DEST="$1"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> fetching $ASSET"
echo "    $URL"
curl --fail --location --progress-bar --output "$WORK/$ASSET" "$URL"

ACTUAL_SHA256="$(shasum -a 256 "$WORK/$ASSET" | awk '{print $1}')"

if [ "$PRINT_ONLY" = 1 ]; then
  echo
  echo "==> record these in VENDORING.md and in the pin above:"
  echo "        tag:      $SUPPORT_TAG"
  echo "        asset:    $ASSET"
  echo "        bytes:    $(wc -c < "$WORK/$ASSET" | tr -d ' ')"
  echo "        sha256:   $ACTUAL_SHA256"
  exit 0
fi

# The verification is the point of the script, not a courtesy. This archive
# becomes executable code inside somebody's application; a proxy, a cache or a
# rewritten release that changed it must stop here rather than be discovered
# later.
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
  echo
  echo "!!! CHECKSUM MISMATCH — nothing was unpacked."
  echo "    expected $EXPECTED_SHA256"
  echo "    actual   $ACTUAL_SHA256"
  echo
  echo "    If you meant to change the pinned release, edit the constants at the"
  echo "    top of this script and re-run with --print-checksum."
  exit 1
fi
echo "==> sha256 verified: $ACTUAL_SHA256"

echo "==> unpacking into $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
tar -xzf "$WORK/$ASSET" -C "$DEST"

STDLIB_COUNT="$(find "$DEST/Python.xcframework/lib" -type f | wc -l | tr -d ' ')"

cat <<EOF

==> done.

    $DEST/Python.xcframework          the framework slices (device + simulator)
    $DEST/Python.xcframework/lib      the standard library — $STDLIB_COUNT files
    $DEST/VERSIONS                    what CPython and which bundled libraries

    Note what that second line means: the standard library lives BESIDE the
    slices, not inside them. That is why this is not a SwiftPM binaryTarget —
    a binary target would deliver the framework and leave the interpreter with
    no standard library to find. See VENDORING.md, "Why not a binaryTarget".

    In the application target:

      1. Add Python.xcframework to "Frameworks, Libraries, and Embedded
         Content", set to Embed & Sign.
      2. Add a Run Script phase, BEFORE "Embed Frameworks", that copies
         Python.xcframework/lib/python$PYTHON_SERIES into the bundle as
         python/lib/python$PYTHON_SERIES, copies the slice's lib-dynload
         alongside it, and codesigns each .so individually — iOS requires a
         signature per Mach-O. Upstream ships this script; do not write a
         second one.
      3. At launch:

             let layout = try PythonLayout.inBundle()
             let runtime = try PythonRuntime.bootstrap(.init(layout: layout))

EOF
