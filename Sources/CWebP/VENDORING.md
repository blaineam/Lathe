# Vendored libwebp

`upstream/` is a **partial, unmodified copy of libwebp**, taken from a pinned
release tag. It is the only third-party code in this package.

| | |
|---|---|
| Upstream | <https://chromium.googlesource.com/webm/libwebp> |
| Tag | `v1.6.0` |
| Commit | `4fa21912338357f89e4fd51cf2368325b59e9bd9` |
| Vendored | 2026-09-14 (encoder); 2026-09-16 (muxer and decoder added, same tag) |
| Licence | BSD-3-Clause, plus an additional patent grant |
| Size | 99 `.c` + 48 `.h`, ~2.2 MB of source (~320 KB of arm64 code and data, release) |

## Refreshing it

```sh
./refresh-upstream.sh            # re-vendor the pinned tag
./refresh-upstream.sh v1.6.1     # vendor a different tag
```

The script clones the tag, copies the allow-listed files, and prints the tag,
commit and date. Then:

1. Put those three values in the table above.
2. `swift build --scratch-path /tmp/lathe-build && swift test --scratch-path /tmp/lathe-build`
3. `git diff --stat Sources/CWebP/upstream` — a refresh should read as upstream's
   own changelog and nothing else. Anything surprising means the allow-lists in
   the script need a look (see "If a refresh fails to build" below).

The allow-lists live in `refresh-upstream.sh` and **are** the vendoring policy.
Nothing is copied that is not named there, so "what did we take?" has one answer
in one place rather than being reconstructible only by diffing against upstream.

## Why source, not an `.xcframework`

The reflex for a C dependency on Apple platforms is `xcodebuild
-create-xcframework` and a SwiftPM `binaryTarget`. libwebp does not need it and
taking it would cost real maintainability — see the long comment on the `CWebP`
target in `Package.swift` for the full argument. In short: one `swift build`
covers every platform and architecture; no binary artifact in git; no checksum
to keep in step with a tag; no CI job gating consumption of a change; and an
upstream bump is a source refresh rather than a rebuild-and-republish.

## What was taken, and what was not

What an **encoder** and an **animation encoder** need. libwebp is four
libraries in one tree — encoder, decoder, demuxer, muxer — and this package
takes three of them, one only because another calls it.

| Directory | Taken | Left behind |
|---|---|---|
| `src/webp` | `encode.h`, `mux.h`, `types.h`, `format_constants.h`, `mux_types.h`, `decode.h` | `demux.h` |
| `src/enc` | everything except `picture_psnr_enc.c` | `picture_psnr_enc.c` |
| `src/mux` | every `.c` and `.h` (`anim_encode.c`, `muxedit.c`, `muxinternal.c`, `muxread.c`, `animi.h`, `muxi.h`) | build files |
| `src/dec` | every `.c` and `.h` | build files |
| `src/dsp` | every kernel in C, NEON, SSE2, SSE4.1 and AVX2 | all `*_mips*`, all `*_msa*` |
| `src/utils` | every `.c` and `.h` | build files |
| `sharpyuv` | all of it | — |
| `src/demux` | nothing | all |
| `examples`, `extras`, `imageio`, `swig`, `tests`, `webp_js` | nothing | all |

`include/CWebP.h` exposes `encode.h` and `mux.h` to Swift and nothing else.

### History

The first vendoring (2026-09-14) took the encoder alone, with five decoder
*headers* and no decoder sources, and left the muxer out on purpose: a second
library to store an orientation tag was a poor trade when `ImageEncoder`
could bake orientation into the pixels. Two things changed that trade. Animated
WebP cannot be written without `WebPAnimEncoder`, which lives in the muxer; and
once the muxer is in, WebP's `EXIF` and `XMP ` chunks cost nothing more, so
WebP output now carries metadata and keeps its orientation tag. The tag, the
commit and the upstream files already vendored are unchanged; the second pass
only added files.

### Notes on the less obvious lines

- **The decoder is here for the muxer, not for reading.** `WebPAnimEncoder`
  decodes its own sub-frames back onto a canvas when it rewrites a frame as a
  keyframe (`anim_encode.c` → `WebPDecode`), and the muxer sizes a bitstream
  with `VP8GetInfo`/`VP8LGetInfo` (`src/dec/vp8_dec.c`, `vp8l_dec.c`). Both are
  link-time dependencies, so the whole of `src/dec` is compiled — about 290 KB
  of source. Nothing in Swift calls it: `decode.h` is deliberately absent from
  `include/CWebP.h`. **Reading WebP stays ImageIO's job**, animated files
  included — ImageIO reports every frame, each frame's delay
  (`kCGImagePropertyWebPUnclampedDelayTime`) and the loop count, and composites
  sub-rectangle frames correctly; `AnimatedWebPTests` checks all of that against
  files this encoder wrote.
- **No demuxer**, for the same reason. `libwebpdemux` is what a reader needs,
  and ImageIO is the reader.
- **`src/utils` is now whole.** `bit_reader_utils.c`, `huffman_utils.c` and
  `quant_levels_dec_utils.*` used to be left out as decoder-only; the decoder
  now has a caller, so they have one too.
- **`src/dsp/dec*.c`, `ssim*.c` and `upsampling*.c` were needed even before
  the decoder was.** This was the one real surprise in assembling the first
  allow-list, and it is recorded here so nobody repeats the experiment: the
  encoder runs the loop filters to simulate what a decoder will produce
  (`filter_enc.c` → `VP8HFilter16i`), scores candidate filter strengths with
  SSIM (`VP8SSIMGetClipped`), reconstructs with the decoder's `VP8TransformWHT`,
  and takes YUV input through the upsamplers (`WebPGetLinePairConverter`). If a
  future refresh link-errors on an unfamiliar `VP8…` symbol, find which
  `src/dsp` file defines it and add that file to `DSP_FILES`.
- **`picture_psnr_enc.c`.** Distortion metrics: `WebPPictureDistortion` is
  declared in `encode.h` but measures an encode rather than performing one. The
  declaration remains in the header, so calling it is a link error rather than a
  silent wrong answer — and `CWebP` is not a package product, so no code outside
  this package can reach it in the first place. `WebPAnimEncoder` does not call
  it.
- **MIPS and MSA kernels.** No Apple platform has ever run on either.
- **What the muxer is used for.** Two things, both in `LatheImage`:
  `WebPAnimationEncoder` (animated WebP, via `WebPAnimEncoder`) and
  `WebPEncoder`'s metadata path (`WebPMuxSetChunk` for `EXIF` and `XMP `). No
  `ICCP` chunk is written: pixels are converted to sRGB before encoding, which is
  what an untagged WebP means.

## Patches

**None.** Every file under `upstream/` is byte-for-byte upstream.

If a future refresh genuinely cannot be made to build without a change, put a
`.patch` file in a `patches/` directory beside this one, with a header saying
what it changes, why upstream cannot be used unmodified, and whether it has been
sent upstream — and have `refresh-upstream.sh` apply it after the copy. Do not
edit `upstream/` in place: a silent edit is invisible in the next refresh's
diff, which is exactly when it matters.

## Build configuration

`HAVE_CONFIG_H` is deliberately **not** defined, and there is no `config.h`.
Without it, libwebp's own `src/dsp/cpu.h` selects kernels from the compiler's
architecture macros, which is precisely right under SwiftPM's one-build-per-
architecture model:

| Architecture | Path | How |
|---|---|---|
| `arm64` (device, Apple silicon, simulator) | **NEON** | `__aarch64__` ⇒ `WEBP_USE_NEON`, no flag needed |
| `x86_64` (Intel Mac, simulator) | **SSE2** | `__SSE2__` is baseline on x86-64 |
| `x86_64` | SSE4.1 / AVX2 — *not* enabled | needs per-file `-msse4.1` / `-mavx2`, which SwiftPM cannot express |

The SSE4.1 and AVX2 translation units are still compiled; upstream's
`WEBP_DSP_INIT_STUB` turns each into an empty init function when its macro is
absent, so they cost a few bytes and nothing else. On arm64 NEON is
*unconditional* rather than runtime-dispatched — libwebp treats it as implied by
the architecture — so the kernels that matter are always the fast ones.

Verifying this after a refresh rather than assuming it:

```sh
swift build --scratch-path /tmp/lathe-build
find /tmp/lathe-build -name enc_neon.o -exec size -m {} \; | grep __text
```

`__text` in the thousands means real NEON code; a size of 4 means the stub
compiled and the SIMD path is off.

`WEBP_USE_THREAD` is also left undefined, so `thread_utils.c` compiles to its
single-threaded form. The encoder's own `thread_level` defaults to 0 regardless,
and `ImageEncoder` is called from inside `LatheWork`'s queue — often once per
image across a batch — so worker threads inside a single still encode would
contend with the caller's own parallelism rather than add to it. The same holds
for the decoder's threaded filter path, which nothing here would use anyway.

## Licence

libwebp is **BSD-3-Clause** with an additional patent grant. Both files are
reproduced verbatim:

- `upstream/COPYING` — the licence
- `upstream/PATENTS` — the additional grant
- `upstream/AUTHORS` — upstream's author list

Lathe itself is Apache-2.0. The two are compatible, and a consumer linking
`LatheImage` links libwebp, so the obligation travels: see
`THIRD-PARTY-NOTICES.md` at the repository root, which is the file a consumer is
expected to find.
