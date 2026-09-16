#!/bin/bash
#
# Fetches the pinned Ruffle self-hosted web build, verifies it against a
# recorded SHA-256, and installs the files Lathe ships into RenderHost/ruffle —
# verifying each of those too.
#
#   ./fetch-upstream.sh                  # refresh ./RenderHost/ruffle
#   ./fetch-upstream.sh <destination>    # …somewhere else
#   ./fetch-upstream.sh --verify         # check the committed files, no download
#   ./fetch-upstream.sh --print-checksum # download and print the hash, for a bump
#
# THE RESULT IS COMMITTED. SwiftPM gives a consumer only the resources that are
# in the package when it builds, so an application depending on LatheSWFRender
# gets Ruffle only if these files are in the repository. This script is how
# they got there, and how anyone can check that they are still what upstream
# published. See VENDORING.md.

set -euo pipefail

# --- The pin -----------------------------------------------------------------
#
# Bump the version and the archive hash together, then follow VENDORING.md,
# "Refreshing it" — the file list below has to be re-derived by hand, because
# upstream's filenames carry content hashes.

RUFFLE_TAG="v0.6.0"
RUFFLE_VERSION="0.6.0"
EXPECTED_SHA256="e8acfacc37443303872379d0e215999af846854d1dd3fa8fac0a765445b43dbf"

# The files Lathe ships, and each one's hash. Everything else in the archive is
# left behind:
#
# * `*.js.map` — source maps, for a debugger nobody attaches to this WebView.
# * `package.json`, `README.md` — npm packaging.
# * The VANILLA core (`core.ruffle.f000070ea72f8ae4fe3a.js` and
#   `72a20ef1c0b8ceb37720.wasm`, 14 MB). `ruffle.js` loads it only when
#   WebAssembly lacks bulk memory, SIMD, non-trapping float-to-int, sign
#   extension or reference types, and every WebKit on iOS 17 / macOS 14 and
#   later has all five. `WebAssemblySupport.probe()` checks the same five, so a
#   system that would need it is told so by name.
SHIPPED=(
  "ruffle.js a686a305345b06542dddedada71869104916a61e393f174687571528ac4225f5"
  "core.ruffle.c80159b526e567babaf5.js 624b0b23bc4460d73e789e608fd1274546a5a411f71f7e873414aca94bc5bc4f"
  "826bb0938097485a2c9d.wasm e4ba64aa1dc9f7f2368602dd0fc2c51046f3e35baba8116d6cf3ae930a63aa02"
  "LICENSE_APACHE 62c7a1e35f56406896d7aa7ca52d0cc0d272ac022b5d2796e7d6905db8a3636a"
  "LICENSE_MIT 4de9338a7879c68e911742a7d691f0797ff1ef8d8a6fb978b0c711e258fe959c"
)

REPO="https://github.com/ruffle-rs/ruffle"
ASSET="ruffle-${RUFFLE_VERSION}-web-selfhosted.zip"
URL="${REPO}/releases/download/${RUFFLE_TAG}/${ASSET}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="install"
DEST="${HERE}/RenderHost/ruffle"
case "${1:-}" in
  --print-checksum) MODE="print" ;;
  --verify) MODE="verify" ;;
  "") ;;
  *) DEST="$1" ;;
esac

# Checks every shipped file in a directory against its recorded hash, and that
# nothing else is there.
verify_directory() {
  local dir="$1" failed=0 entry name hash actual
  for entry in "${SHIPPED[@]}"; do
    name="${entry% *}"
    hash="${entry#* }"
    if [ ! -f "${dir}/${name}" ]; then
      echo "  MISSING  ${name}" >&2
      failed=1
      continue
    fi
    actual="$(shasum -a 256 "${dir}/${name}" | cut -d' ' -f1)"
    if [ "${actual}" != "${hash}" ]; then
      echo "  MODIFIED ${name}" >&2
      failed=1
    fi
  done
  local count
  count="$(find "${dir}" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
  if [ "${count}" != "${#SHIPPED[@]}" ]; then
    echo "  ${dir} holds ${count} entries; ${#SHIPPED[@]} are expected" >&2
    failed=1
  fi
  return "${failed}"
}

if [ "${MODE}" = "verify" ]; then
  if verify_directory "${DEST}"; then
    echo "Ruffle ${RUFFLE_TAG}: all ${#SHIPPED[@]} files match the pin."
    exit 0
  fi
  echo "Ruffle ${RUFFLE_TAG}: the committed files do not match the pin." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "Ruffle ${RUFFLE_TAG}"
echo "  from ${URL}"
curl --fail --location --progress-bar --output "${WORK}/${ASSET}" "${URL}"

ACTUAL_SHA256="$(shasum -a 256 "${WORK}/${ASSET}" | cut -d' ' -f1)"

if [ "${MODE}" = "print" ]; then
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

unzip -q "${WORK}/${ASSET}" -d "${WORK}/unpacked"

# The archive has a single top-level directory in some releases and none in
# others, so the entry point is located rather than assumed.
ENTRY="$(find "${WORK}/unpacked" -name 'ruffle.js' -maxdepth 3 | head -1)"
if [ -z "${ENTRY}" ]; then
  echo "No ruffle.js in ${ASSET} — upstream's archive layout has changed." >&2
  exit 1
fi
SOURCE="$(dirname "${ENTRY}")"

mkdir -p "${WORK}/staged"
for entry in "${SHIPPED[@]}"; do
  name="${entry% *}"
  if [ ! -f "${SOURCE}/${name}" ]; then
    echo "${ASSET} has no ${name} — the file list in this script is stale." >&2
    exit 1
  fi
  cp "${SOURCE}/${name}" "${WORK}/staged/${name}"
done
if ! verify_directory "${WORK}/staged"; then
  echo "The archive verified but a file in it does not match its recorded hash." >&2
  exit 1
fi

mkdir -p "${DEST}"
find "${DEST}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp "${WORK}/staged/"* "${DEST}/"

echo
echo "Installed into ${DEST}"
echo "  ${#SHIPPED[@]} files, $(du -sh "${DEST}" | cut -f1)"
