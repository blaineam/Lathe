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
# The allow-lists below are the *whole* vendoring policy: only the files an
# encoder needs are taken. See VENDORING.md for what is excluded and why.

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
# src/webp  — the public headers the encoder's API and internals reference.
#             demux.h and mux.h are omitted: no demuxer or muxer is vendored.
# src/dec   — headers only. The encoder-side DSP shares struct definitions with
#             the decoder (VP8LTransform, VP8Io); no decoder .c file is taken.
# src/enc   — everything except picture_psnr_enc.c (distortion metrics; not part
#             of encoding, and it is what would drag in src/dsp/ssim*.c).
# src/dsp   — the encode and shared kernels, in C plus the NEON/SSE2/SSE4.1/AVX2
#             variants. Only the MIPS and MSA variants are omitted. Note that
#             dec*.c, ssim*.c and upsampling*.c are NOT decoder-only despite the
#             names: the encoder calls the loop filters to simulate the decoder's
#             output, SSIM to score a filter strength, and the upsamplers to take
#             a YUV picture in. Dropping them link-errors.
# src/utils — the encoder-side utilities. bit_reader_utils.c, huffman_utils.c and
#             quant_levels_dec_utils.* are decoder-only; the first two keep their
#             headers because decoder struct definitions are still referenced.
# sharpyuv  — all of it. Small, and the encoder's -sharp_yuv path needs it.

WEBP_HEADERS=(decode.h encode.h format_constants.h mux_types.h types.h)
DEC_HEADERS=(common_dec.h vp8_dec.h vp8i_dec.h vp8li_dec.h webpi_dec.h)

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

UTILS_FILES=(
  bit_reader_utils.h
  bit_writer_utils.c bit_writer_utils.h
  color_cache_utils.c color_cache_utils.h
  endian_inl_utils.h
  filters_utils.c filters_utils.h
  huffman_encode_utils.c huffman_encode_utils.h
  huffman_utils.h
  palette.c palette.h
  quant_levels_utils.c quant_levels_utils.h
  random_utils.c random_utils.h
  rescaler_utils.c rescaler_utils.h
  thread_utils.c thread_utils.h
  utils.c utils.h
)

ENC_EXCLUDE=(Makefile.am picture_psnr_enc.c)

echo "==> replacing $DEST"
rm -rf "$DEST"
mkdir -p "$DEST/src/webp" "$DEST/src/dec" "$DEST/src/enc" "$DEST/src/dsp" \
         "$DEST/src/utils" "$DEST/sharpyuv"

# Licence and provenance files, verbatim.
for f in COPYING PATENTS AUTHORS; do
  cp "$WORK/libwebp/$f" "$DEST/$f"
done

for f in "${WEBP_HEADERS[@]}"; do cp "$WORK/libwebp/src/webp/$f" "$DEST/src/webp/$f"; done
for f in "${DEC_HEADERS[@]}";  do cp "$WORK/libwebp/src/dec/$f"  "$DEST/src/dec/$f";  done
for f in "${DSP_FILES[@]}";    do cp "$WORK/libwebp/src/dsp/$f"  "$DEST/src/dsp/$f";  done
for f in "${UTILS_FILES[@]}";  do cp "$WORK/libwebp/src/utils/$f" "$DEST/src/utils/$f"; done

for path in "$WORK"/libwebp/src/enc/*; do
  name="$(basename "$path")"
  skip=0
  for e in "${ENC_EXCLUDE[@]}"; do [ "$name" = "$e" ] && skip=1; done
  [ "$skip" = 1 ] && continue
  cp "$path" "$DEST/src/enc/$name"
done

for path in "$WORK"/libwebp/sharpyuv/*.c "$WORK"/libwebp/sharpyuv/*.h; do
  cp "$path" "$DEST/sharpyuv/$(basename "$path")"
done

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
