#!/bin/bash
#
# Refreshes Sources/CWebP/upstream/ from a pinned libwebp release tag.
#
#   ./refresh-upstream.sh            # re-vendor the pinned tag (see LIBWEBP_TAG)
#   ./refresh-upstream.sh v1.6.1     # vendor a different tag
#
# Everything this script copies is copied byte-for-byte; nothing is patched.
# If you bump the tag, update VENDORING.md (version + commit + date) with the
# values this script prints at the end, then run `swift build && swift test`.
#
# The allow-lists below are the *whole* vendoring policy: what an encoder and
# an animation encoder need, and nothing else. See VENDORING.md for what is
# excluded and why.

set -euo pipefail

LIBWEBP_TAG="${1:-v1.6.0}"
LIBWEBP_REPO="https://chromium.googlesource.com/webm/libwebp"

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HERE/upstream"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> cloning $LIBWEBP_REPO at $LIBWEBP_TAG"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$LIBWEBP_TAG" "$LIBWEBP_REPO" "$WORK/libwebp"
COMMIT="$(git -C "$WORK/libwebp" rev-parse HEAD)"

# --- What gets vendored -------------------------------------------------------
#
# src/webp  — the public headers the encoder, the decoder and the muxer
#             reference. demux.h is omitted: no demuxer is vendored, because
#             ImageIO reads animated WebP, timing included.
# src/dec   — all of it. WebPAnimEncoder decodes its own sub-frames back onto
#             the canvas (anim_encode.c → WebPDecode) when it rewrites a frame as
#             a keyframe, and the muxer sizes a bitstream with VP8GetInfo /
#             VP8LGetInfo. Both are link-time dependencies, so the decoder is in.
#             It is not used to *read* anything; ImageIO does that.
# src/enc   — everything except picture_psnr_enc.c (distortion metrics; not part
#             of encoding).
# src/mux   — the muxer and WebPAnimEncoder: every .c and .h, nothing else.
# src/dsp   — the encode, decode and shared kernels, in C plus the
#             NEON/SSE2/SSE4.1/AVX2 variants. Only the MIPS and MSA variants are
#             omitted. Note that dec*.c, ssim*.c and upsampling*.c were needed
#             even before the decoder was: the encoder calls the loop filters to
#             simulate the decoder's output, SSIM to score a filter strength, and
#             the upsamplers to take a YUV picture in.
# src/utils — all of it, now that the decoder-side utilities have a caller.
# sharpyuv  — all of it. Small, and the encoder's -sharp_yuv path needs it.

WEBP_HEADERS=(decode.h encode.h format_constants.h mux.h mux_types.h types.h)

DSP_FILES=(
  alpha_processing.c alpha_processing_neon.c alpha_processing_sse2.c
  alpha_processing_sse41.c
  common_sse2.h common_sse41.h
  cost.c cost_neon.c cost_sse2.c
  cpu.c cpu.h dsp.h
  dec.c dec_clip_tables.c dec_neon.c dec_sse2.c dec_sse41.c
  enc.c enc_neon.c enc_sse2.c enc_sse41.c
  filters.c filters_neon.c filters_sse2.c
  lossless.c lossless.h lossless_avx2.c lossless_common.h lossless_neon.c
  lossless_sse2.c lossless_sse41.c
  lossless_enc.c lossless_enc_avx2.c lossless_enc_neon.c lossless_enc_sse2.c
  lossless_enc_sse41.c
  neon.h quant.h
  rescaler.c rescaler_neon.c rescaler_sse2.c
  ssim.c ssim_sse2.c
  upsampling.c upsampling_neon.c upsampling_sse2.c upsampling_sse41.c
  yuv.c yuv.h yuv_neon.c yuv_sse2.c yuv_sse41.c
)

MUX_FILES=(anim_encode.c animi.h muxedit.c muxi.h muxinternal.c muxread.c)

# Whole directories, minus their build-system files.
copy_dir() {  # copy_dir <src-subdir> <dest-subdir> [excluded names...]
  local from="$WORK/libwebp/$1" to="$DEST/$2"; shift 2
  local path name e skip
  for path in "$from"/*.c "$from"/*.h; do
    name="$(basename "$path")"
    skip=0
    for e in "$@"; do [ "$name" = "$e" ] && skip=1; done
    [ "$skip" = 1 ] && continue
    cp "$path" "$to/$name"
  done
}

echo "==> replacing $DEST"
rm -rf "$DEST"
mkdir -p "$DEST/src/webp" "$DEST/src/dec" "$DEST/src/enc" "$DEST/src/dsp" \
         "$DEST/src/mux" "$DEST/src/utils" "$DEST/sharpyuv"

# Licence and provenance files, verbatim.
for f in COPYING PATENTS AUTHORS; do
  cp "$WORK/libwebp/$f" "$DEST/$f"
done

for f in "${WEBP_HEADERS[@]}"; do cp "$WORK/libwebp/src/webp/$f" "$DEST/src/webp/$f"; done
for f in "${DSP_FILES[@]}";    do cp "$WORK/libwebp/src/dsp/$f"  "$DEST/src/dsp/$f";  done
for f in "${MUX_FILES[@]}";    do cp "$WORK/libwebp/src/mux/$f"  "$DEST/src/mux/$f";  done

copy_dir src/dec   src/dec
copy_dir src/enc   src/enc   picture_psnr_enc.c
copy_dir src/utils src/utils
copy_dir sharpyuv  sharpyuv

cat > "$DEST/README-VENDORED.txt" <<EOF
This directory is an unmodified partial copy of libwebp, taken from

    $LIBWEBP_REPO
    tag    $LIBWEBP_TAG
    commit $COMMIT

by Sources/CWebP/refresh-upstream.sh. Do not edit anything in here by hand:
the next refresh will overwrite it. See ../VENDORING.md.

libwebp is BSD-3-Clause; its licence is in ./COPYING and the additional patent
grant is in ./PATENTS. Both are reproduced verbatim.
EOF

echo
echo "==> vendored $(find "$DEST" -name '*.c' | wc -l | tr -d ' ') .c and \
$(find "$DEST" -name '*.h' | wc -l | tr -d ' ') .h files"
echo "==> record these in VENDORING.md:"
echo "        tag:    $LIBWEBP_TAG"
echo "        commit: $COMMIT"
echo "        date:   $(date -u +%Y-%m-%d)"
