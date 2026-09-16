#!/bin/bash
#
# Fetches the pinned Ruffle self-hosted web build, verifies it against a
# recorded SHA-256, and unpacks it.
#
#   ./fetch-upstream.sh                  # into ./RenderHost/ruffle
#   ./fetch-upstream.sh <destination>    # …somewhere else
#   ./fetch-upstream.sh --print-checksum # download and print the hash, for a bump
#
# NOTHING FETCHED BY THIS SCRIPT IS COMMITTED. The archive is ~10 MB; this
# package keeps no binary artifacts in git. LatheSWFRender compiles, links and
# passes its tests with none of it present — what it cannot do is render, and it
# refuses by name. See VENDORING.md.

set -euo pipefail

# --- The pin -----------------------------------------------------------------
#
# Bump the two together, then re-run with --print-checksum and paste the result
# here and into VENDORING.md's table.

RUFFLE_TAG="v0.6.0"
RUFFLE_VERSION="0.6.0"
EXPECTED_SHA256="e8acfacc37443303872379d0e215999af846854d1dd3fa8fac0a765445b43dbf"

REPO="https://github.com/ruffle-rs/ruffle"
ASSET="ruffle-${RUFFLE_VERSION}-web-selfhosted.zip"
URL="${REPO}/releases/download/${RUFFLE_TAG}/${ASSET}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PRINT_ONLY=0
DEST="${HERE}/RenderHost/ruffle"
if [ "${1:-}" = "--print-checksum" ]; then
  PRINT_ONLY=1
elif [ -n "${1:-}" ]; then
  DEST="$1"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "Ruffle ${RUFFLE_TAG}"
echo "  from ${URL}"
curl --fail --location --progress-bar --output "${WORK}/${ASSET}" "${URL}"

ACTUAL_SHA256="$(shasum -a 256 "${WORK}/${ASSET}" | cut -d' ' -f1)"

if [ "${PRINT_ONLY}" = "1" ]; then
  echo
  echo "  asset  ${ASSET}"
  echo "  bytes  $(wc -c < "${WORK}/${ASSET}" | tr -d ' ')"
  echo "  sha256 ${ACTUAL_SHA256}"
  echo
  echo "Paste that into EXPECTED_SHA256 above and into VENDORING.md."
  exit 0
fi

# The verification is the point of the script, not a formality: what is being
# unpacked becomes a WebAssembly interpreter inside the user's application, so a
# mismatch stops here rather than being reported and worked around.
if [ "${ACTUAL_SHA256}" != "${EXPECTED_SHA256}" ]; then
  echo "CHECKSUM MISMATCH — refusing to unpack." >&2
  echo "  expected ${EXPECTED_SHA256}" >&2
  echo "  actual   ${ACTUAL_SHA256}" >&2
  echo >&2
  echo "Either the pin in this script is stale, or the download is not what it" >&2
  echo "claims to be. Do not 'fix' this by pasting the actual hash without" >&2
  echo "first establishing which of those it is." >&2
  exit 1
fi
echo "  sha256 ok"

mkdir -p "${DEST}"
# Clear out a previous fetch, but keep the two files that belong to this
# repository rather than to upstream.
find "${DEST}" -mindepth 1 -maxdepth 1 ! -name 'PLACEHOLDER.md' \
  -exec rm -rf {} +

unzip -q "${WORK}/${ASSET}" -d "${WORK}/unpacked"

# The archive has a single top-level directory in some releases and none in
# others, so the entry point is located rather than assumed.
ENTRY="$(find "${WORK}/unpacked" -name 'ruffle.js' -maxdepth 3 | head -1)"
if [ -z "${ENTRY}" ]; then
  echo "No ruffle.js in ${ASSET} — upstream's archive layout has changed." >&2
  exit 1
fi
cp -R "$(dirname "${ENTRY}")"/. "${DEST}/"

echo
echo "Unpacked into ${DEST}"
echo "  $(find "${DEST}" -type f | wc -l | tr -d ' ') files, $(du -sh "${DEST}" | cut -f1)"
echo
echo "Nothing here is committed; see the repository .gitignore."
