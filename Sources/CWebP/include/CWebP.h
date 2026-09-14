// Lathe's view of the vendored libwebp.
//
// This is the only header `import CWebP` exposes, and it deliberately exposes
// one thing: the encoder's public API. libwebp's internal headers stay internal
// even though they are compiled into this target, so nothing in Swift can reach
// past `WebPEncode` into `VP8Encoder` and start depending on upstream internals
// that the next vendoring refresh is free to change.
//
// The include is written relative to *this file* rather than against a header
// search path on purpose. `cSettings` do not propagate to the Swift side of the
// build, so a `#include "src/webp/encode.h"` here would compile when clang
// builds the C sources and fail when Swift imports the module.
//
// Note what is absent: no decoder is vendored (ImageIO reads WebP), and no
// muxer or demuxer (see VENDORING.md). `decode.h` is present in the vendored
// tree only because internal headers reference its types; there is no
// `WebPDecode` implementation to call.

#ifndef LATHE_CWEBP_H
#define LATHE_CWEBP_H

#include "../upstream/src/webp/encode.h"

#endif  // LATHE_CWEBP_H
