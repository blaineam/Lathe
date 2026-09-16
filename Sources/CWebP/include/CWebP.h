// Lathe's view of the vendored libwebp.
//
// This is the only header `import CWebP` exposes, and it deliberately exposes
// two things: the encoder's public API and the muxer's (which is where
// `WebPAnimEncoder` and the metadata chunks live). libwebp's internal headers
// stay internal even though they are compiled into this target, so nothing in
// Swift can reach past `WebPEncode` into `VP8Encoder` and start depending on
// upstream internals that the next vendoring refresh is free to change.
//
// The include is written relative to *this file* rather than against a header
// search path on purpose. `cSettings` do not propagate to the Swift side of the
// build, so a `#include "src/webp/encode.h"` here would compile when clang
// builds the C sources and fail when Swift imports the module.
//
// Note what is absent: `decode.h`. The decoder *is* compiled — WebPAnimEncoder
// calls it internally, see VENDORING.md — but reading WebP is ImageIO's job,
// animated files included, so Swift is not handed a second way to do it. No
// demuxer is vendored, for the same reason.

#ifndef LATHE_CWEBP_H
#define LATHE_CWEBP_H

#include "../upstream/src/webp/encode.h"
#include "../upstream/src/webp/mux.h"

#endif  // LATHE_CWEBP_H
