# Third-party notices

Lathe is licensed under the Apache License, Version 2.0 — see `LICENSE`.

It also **links one third-party component**, whose licence is reproduced below.
If you ship an application that depends on `LatheImage` (directly, or through
the `Lathe` umbrella, `LatheVideo` or `LatheDoc`), you are distributing that
component's code and its notice obligations apply to you. Reproducing this file
in your application's acknowledgements satisfies them.

No other module carries a third-party dependency. `LatheCore` and `LatheAudio`
link nothing but Apple's own frameworks.

---

## libwebp

- **Used by:** `LatheImage` (and therefore `Lathe`, `LatheVideo`, `LatheDoc`)
- **Why:** ImageIO decodes WebP and cannot encode it. libwebp is the WebP
  encoder; there is no Apple-provided alternative.
- **Upstream:** <https://chromium.googlesource.com/webm/libwebp>
- **Version:** v1.6.0 (commit `4fa21912338357f89e4fd51cf2368325b59e9bd9`)
- **Licence:** BSD-3-Clause, with an additional patent grant
- **Vendored at:** `Sources/CWebP/upstream/` — a partial, unmodified copy of the
  encoder. See `Sources/CWebP/VENDORING.md` for exactly what was taken, what was
  left out, and how to refresh it.
- **Modifications:** none. Every vendored file is byte-for-byte upstream.

### Licence (`Sources/CWebP/upstream/COPYING`)

```
Copyright (c) 2010, Google Inc. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of Google nor the names of its contributors may
    be used to endorse or promote products derived from this software
    without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

```

### Additional IP Rights Grant (`Sources/CWebP/upstream/PATENTS`)

```
Additional IP Rights Grant (Patents)
------------------------------------

"These implementations" means the copyrightable works that implement the WebM
codecs distributed by Google as part of the WebM Project.

Google hereby grants to you a perpetual, worldwide, non-exclusive, no-charge,
royalty-free, irrevocable (except as stated in this section) patent license to
make, have made, use, offer to sell, sell, import, transfer, and otherwise
run, modify and propagate the contents of these implementations of WebM, where
such license applies only to those patent claims, both currently owned by
Google and acquired in the future, licensable by Google that are necessarily
infringed by these implementations of WebM. This grant does not include claims
that would be infringed only as a consequence of further modification of these
implementations. If you or your agent or exclusive licensee institute or order
or agree to the institution of patent litigation or any other patent
enforcement activity against any entity (including a cross-claim or
counterclaim in a lawsuit) alleging that any of these implementations of WebM
or any code incorporated within any of these implementations of WebM
constitute direct or contributory patent infringement, or inducement of
patent infringement, then any patent rights granted to you under this License
for these implementations of WebM shall terminate as of the date such
litigation is filed.
```

---

## Notes for consumers

**Linking less.** `LatheImage` is the only module that links libwebp. A consumer
that needs no still-image work can depend on `LatheCore` or `LatheAudio` alone
and ship none of it — that is what the per-module products in `Package.swift`
are for.

**Patents.** WebP's bitstream is covered by the additional grant above rather
than by the BSD licence text. The grant is broad and royalty-free, and it
terminates if you sue Google over WebM patents. If that clause matters to your
organisation, read it rather than this summary.
