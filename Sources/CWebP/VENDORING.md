# Vendored libwebp

`upstream/` is a **partial, unmodified copy of libwebp**, taken from a pinned
release tag. It is the only third-party code in this package.

| | |
|---|---|
| Upstream | <https://chromium.googlesource.com/webm/libwebp> |
| Tag | `v1.6.0` |
| Commit | `4fa21912338357f89e4fd51cf2368325b59e9bd9` |
| Vendored | 2026-09-14 |
| Licence | BSD-3-Clause, plus an additional patent grant |
| Size | 82 `.c` + 42 `.h`, ~1.9 MB |

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

Only what an **encoder** needs. libwebp is four libraries in one tree — encoder,
decoder, demuxer, muxer — and ImageIO already decodes WebP perfectly well, so
three of them are dead weight here.

| Directory | Taken | Left behind |
|---|---|---|
| `src/webp` | `encode.h`, `types.h`, `format_constants.h`, `mux_types.h`, `decode.h` | `demux.h`, `mux.h` |
| `src/enc` | everything except `picture_psnr_enc.c` | `picture_psnr_enc.c` |
| `src/dsp` | every kernel in C, NEON, SSE2, SSE4.1 and AVX2 | all `*_mips*`, all `*_msa*` |
| `src/utils` | the encoder-side utilities | `bit_reader_utils.c`, `huffman_utils.c`, `quant_levels_dec_utils.*` |
| `src/dec` | **headers only** (5 files) | every `.c` |
| `sharpyuv` | all of it | — |
| `src/demux`, `src/mux` | nothing | all |
| `examples`, `extras`, `imageio`, `swig`, `tests`, `webp_js` | nothing | all |

Notes on the less obvious lines:

- **`src/dec` headers with no `src/dec` sources.** The encoder and the decoder
  share struct definitions — `VP8LTransform`, `VP8Io`, the common coefficient
  tables in `common_dec.h` — and the *shared* DSP kernels (`src/dsp/lossless.c`,
  `src/dsp/dec.c`, `src/dsp/yuv.h`) name those types in their signatures. Five
  headers satisfy that; no decoder implementation is compiled.
- **`src/dsp/dec*.c`, `ssim*.c` and `upsampling*.c` are *not* decoder-only,
  whatever their names say.** This was the one real surprise in assembling the
  allow-list, and it is recorded here so nobody repeats the experiment: the
  encoder runs the loop filters to simulate what a decoder will produce
  (`filter_enc.c` → `VP8HFilter16i`), scores candidate filter strengths with
  SSIM (`VP8SSIMGetClipped`), reconstructs with the decoder's `VP8TransformWHT`,
  and takes YUV input through the upsamplers (`WebPGetLinePairConverter`).
  Leaving any of the three out compiles cleanly and fails at link. If a future
  refresh link-errors on an unfamiliar `VP8…` symbol, this is almost certainly
  the shape of the problem: find which `src/dsp` file defines it and add that
  file to `DSP_FILES`.
- **`bit_reader_utils.h` and `huffman_utils.h` without their `.c`.** Same
  reason: `src/dec/vp8li_dec.h` embeds those structs by value, so the layouts
  are needed and the functions are not.
- **`picture_psnr_enc.c`.** Distortion metrics: `WebPPictureDistortion` is
  declared in `encode.h` but measures an encode rather than performing one. The
  declaration remains in the header, so calling it is a link error rather than a
  silent wrong answer — and `CWebP` is not a package product, so no code outside
  this package can reach it in the first place. (Its `src/dsp/ssim*.c`
  dependency stays, for the reason in the previous bullet.)
- **MIPS and MSA kernels.** No Apple platform has ever run on either.
- **The muxer.** This is the consequential omission and it is deliberate. WebP
  keeps EXIF, XMP and ICC in the chunks of the *extended* (`VP8X`) file format,
  which only `libwebpmux` writes. Vendoring a second library to store an
  orientation tag is a poor trade when `ImageEncoder` already bakes orientation
  into the pixels for any format that cannot hold a tag. The consequence —
  WebP output carries no metadata at all — is documented on `WebPEncoder` and on
  `ImageEncoder`, not just here. It is also why **animated WebP cannot be
  written**: an animation is a muxer feature.

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
contend with the caller's own parallelism rather than add to it.

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
