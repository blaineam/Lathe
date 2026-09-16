# SVT-AV1 in LatheAV1

`LatheAV1` encodes AV1 with [SVT-AV1](https://gitlab.com/AOMediaCodec/SVT-AV1),
linked as the `SvtAv1Enc` binary target.

| | |
|---|---|
| Upstream | <https://gitlab.com/AOMediaCodec/SVT-AV1> |
| Tag | `v4.2.0` |
| Commit | `9292ec8e32bce26f781f277ec8739b53426c4300` |
| Built by | `Scripts/build-svtav1-xcframework.sh` |
| Published | release `svt-av1-4.2.0`, asset `SvtAv1Enc.xcframework.zip` |
| Slices | `macos-arm64_x86_64` (14), `ios-arm64` (17), `ios-arm64_x86_64-simulator` (17) — static, encoder only |
| Licence | **BSD-3-Clause-Clear**, plus the **Alliance for Open Media Patent License 1.0** |

## Why a software encoder, and why a binary

No Apple device encodes AV1 in hardware; VideoToolbox decodes it on newer
chips and encodes it nowhere. So AV1 output is computed on the CPU, by a
library linked into the process.

SVT-AV1 is ~340 C files arranged per instruction set and configured by CMake.
SwiftPM cannot express per-architecture sources, so vendoring it as source —
the way libwebp is — would mean dropping every SIMD kernel and running several
times slower. It is built by a script instead and published as a release
asset, for the same reason LAME is: a binary target at a local path that does
not exist fails every build in the package.

Apple silicon slices keep the NEON, dot-product and I8MM kernels, chosen at
run time. Intel slices are built C-only (their kernels are nasm assembly), so
AV1 on an Intel Mac or an Intel-hosted simulator is correct and slow.

## What an app shipping it must include

- **BSD-3-Clause-Clear** requires the copyright notice, conditions and
  disclaimer with any binary redistribution. The text is `LICENSE.md` in the
  xcframework.
- The Clear variant **grants no patent rights**. Those come from the
  **AOMedia Patent License 1.0** (`PATENTS.md` in the xcframework): a
  royalty-free licence to the AV1 patents of AOMedia members, which ends for
  anyone who brings an AV1 patent claim against its licensors.

Both are permissive and compatible with App Store distribution. An
acknowledgements screen that lists SVT-AV1 with both texts meets them.

## Rebuilding

```sh
Scripts/build-svtav1-xcframework.sh                 # the pinned tag
SVT_TAG=v4.3.0 Scripts/build-svtav1-xcframework.sh  # another release
```

Needs `cmake` and `ninja`. A new build is a new release (`svt-av1-<version>`)
and a new checksum in `Package.swift`, never a replacement of an existing
asset. Then run the `AV1 encoding` suite: it encodes and decodes real clips,
which is the only check that means anything for a bitstream.
