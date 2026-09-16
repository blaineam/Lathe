# Third-party notices

Lathe is licensed under the Apache License, Version 2.0 — see `LICENSE`.

Three third-party components are involved, and **they are involved in different
ways** — which changes what you have to do about each:

| Component | Relationship | Who distributes it |
|---|---|---|
| **libwebp** | vendored as source and compiled into `LatheImage` | you do, in your binary |
| **CPython** | bound at run time by `LatheFetch`; **not** in this repository | you do, *if* you embed it |
| **Ruffle** | fetched into `LatheSWFRender`'s resource bundle; **not** in this repository | you do, *if* you ship `LatheSWFRender` |

If you ship an application that depends on `LatheImage` (directly, or through the
`Lathe` umbrella, `LatheVideo` or `LatheDoc`), you are distributing libwebp and
its notice obligations apply to you. If you depend on `LatheFetch` **and embed a
CPython framework**, you are distributing CPython and its obligations apply too.
Depending on `LatheFetch` without embedding one — on macOS, where the host
supplies the interpreter — distributes no CPython and carries no obligation.
Reproducing this file in your application's acknowledgements satisfies both.

If you depend on `LatheSWFRender`, you are distributing Ruffle: the fetch script
puts it in a resource bundle that ships inside your application. Apache-2.0
requires attribution and a copy of the licence, so its notice applies to you.
Depending on `LatheSWF` alone distributes no Ruffle and carries no obligation —
that module has no renderer in it at all.

`LatheCore` and `LatheAudio` link nothing but Apple's own frameworks.

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

## CPython

- **Used by:** `LatheFetch` only. Not reachable from the `Lathe` umbrella or any
  media module.
- **Why:** the target is running large, published, unmodified Python packages on
  device. Reimplementing that ecosystem in Swift would mean inheriting its churn
  permanently; running the real interpreter does not.
- **Upstream:** <https://www.python.org> — built for Apple platforms by
  <https://github.com/beeware/Python-Apple-support>
- **Version:** CPython 3.13.15, from release `3.13-b15`. The code requires
  3.9 or newer and reads the running interpreter's version rather than assuming
  one.
- **Licence:** PSF-2.0 (CPython) and BSD-3-Clause (the support project's build
  scripts). Both are permissive and GPL-compatible.
- **Vendored at:** *nowhere.* No CPython source, header or binary is in this
  repository. `LatheFetch` resolves fifteen stable-ABI symbols with `dlsym`
  against whatever CPython the process already has. See
  `Sources/LatheFetch/VENDORING.md` for the pinned release, its SHA-256, why this
  route rather than a SwiftPM `binaryTarget`, and what a consumer has to do.
- **Modifications:** none, and none are possible — nothing is copied.

**The framework an application embeds bundles more than CPython.** The pinned
release builds in OpenSSL 3.0.22 (Apache-2.0), libFFI 3.4.7 (MIT), XZ 5.6.4
(0BSD), BZip2 1.0.8 (BSD-4-Clause-like) and mpdecimal 4.0.0 (BSD-2-Clause). Lathe
links none of them; an application that embeds the framework ships all of them
and should list them in its own acknowledgements. Upstream's `VERSIONS` file in
each release is the authoritative list.

### Licence (CPython's `LICENSE.txt`, "PYTHON SOFTWARE FOUNDATION LICENSE VERSION 2")

```
PYTHON SOFTWARE FOUNDATION LICENSE VERSION 2
--------------------------------------------

1. This LICENSE AGREEMENT is between the Python Software Foundation
("PSF"), and the Individual or Organization ("Licensee") accessing and
otherwise using this software ("Python") in source or binary form and
its associated documentation.

2. Subject to the terms and conditions of this License Agreement, PSF hereby
grants Licensee a nonexclusive, royalty-free, world-wide license to reproduce,
analyze, test, perform and/or display publicly, prepare derivative works,
distribute, and otherwise use Python alone or in any derivative version,
provided, however, that PSF's License Agreement and PSF's notice of copyright,
i.e., "Copyright (c) 2001 Python Software Foundation; All Rights Reserved"
are retained in Python alone or in any derivative version prepared by Licensee.

3. In the event Licensee prepares a derivative work that is based on
or incorporates Python or any part thereof, and wants to make
the derivative work available to others as provided herein, then
Licensee hereby agrees to include in any such work a brief summary of
the changes made to Python.

4. PSF is making Python available to Licensee on an "AS IS"
basis.  PSF MAKES NO REPRESENTATIONS OR WARRANTIES, EXPRESS OR
IMPLIED.  BY WAY OF EXAMPLE, BUT NOT LIMITATION, PSF MAKES NO AND
DISCLAIMS ANY REPRESENTATION OR WARRANTY OF MERCHANTABILITY OR FITNESS
FOR ANY PARTICULAR PURPOSE OR THAT THE USE OF PYTHON WILL NOT
INFRINGE ANY THIRD PARTY RIGHTS.

5. PSF SHALL NOT BE LIABLE TO LICENSEE OR ANY OTHER USERS OF PYTHON
FOR ANY INCIDENTAL, SPECIAL, OR CONSEQUENTIAL DAMAGES OR LOSS AS
A RESULT OF MODIFYING, DISTRIBUTING, OR OTHERWISE USING PYTHON,
OR ANY DERIVATIVE THEREOF, EVEN IF ADVISED OF THE POSSIBILITY THEREOF.

6. This License Agreement will automatically terminate upon a material
breach of its terms and conditions.

7. Nothing in this License Agreement shall be deemed to create any
relationship of agency, partnership, or joint venture between PSF and
Licensee.  This License Agreement does not grant permission to use PSF
trademarks or trade name in a trademark sense to endorse or promote
products or services of Licensee, or any third party.

8. By copying, installing or otherwise using Python, Licensee
agrees to be bound by the terms and conditions of this License
Agreement.
```

The full `LICENSE.txt` in a CPython distribution also carries the historical
BeOpen, CNRI and CWI terms covering earlier versions, plus per-component notices
for the libraries CPython bundles. Reproduce that file — not this excerpt — if
you embed the framework.

### Packages installed at run time are *not* covered by this file

`PythonPackageInstaller` fetches wheels from a package index **on the user's
device, at the user's request, from an index the user chose**. Lathe does not
distribute, mirror, cache or bundle any of them, and ships no default set. Their
licences therefore bind whoever installs them, not this package and not you — and
that is precisely why the installer exists rather than a `Resources/` directory
with some wheels in it. It is also what keeps the no-GPL rule in the README's
licence policy true regardless of what a user chooses to install.

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

**Python is opt-in twice over.** `LatheFetch` is a separate product, so an
application that does not name it links none of this. And an application that
does name it still ships no CPython unless it embeds a framework itself — on
macOS the host's interpreter is used and nothing is redistributed.


---

## Ruffle

- **Used by:** `LatheSWFRender` only. **Not** `LatheSWF`, and not the `Lathe`
  umbrella.
- **Why:** it is a Flash Player. Rendering a `.swf` means running one, and
  writing one is a project measured in person-years; Ruffle is the only
  permissively licensed implementation that works.
- **Upstream:** <https://github.com/ruffle-rs/ruffle>
- **Version:** v0.6.0 (released 2026-09-06), asset
  `ruffle-0.6.0-web-selfhosted.zip`, SHA-256
  `e8acfacc37443303872379d0e215999af846854d1dd3fa8fac0a765445b43dbf`
- **Licence:** **Apache-2.0 OR MIT**, at the user's option. Lathe takes it under
  Apache-2.0, which is Lathe's own licence — so there is nothing to reconcile,
  no copyleft obligation, and no per-application decision of the kind
  `LatheMP3`'s LGPL vendoring forces.
- **Copyright:** Ruffle LLC \<ruffle@ruffle.rs\> and Ruffle contributors
- **Vendored at:** `Sources/LatheSWFRender/RenderHost/ruffle/` — and **not
  committed**. `Sources/LatheSWFRender/fetch-upstream.sh` downloads the pinned
  release, verifies the hash above, and unpacks it, keeping upstream's own
  licence files beside the code they cover. See
  `Sources/LatheSWFRender/VENDORING.md`.
- **Modifications:** none. The unpacked build is byte-for-byte upstream's
  release asset.

Ruffle is a clean-room reimplementation of the Flash Player. It contains no
Adobe code and needs no licence from Adobe — which is the question people
usually mean when they ask whether shipping a Flash player is allowed.

### Licence

Apache-2.0 is reproduced in this repository's own `LICENSE`, and applies to
Ruffle on the same terms. Upstream's `LICENSE.md`, which carries both that and
the MIT alternative together with the copyright line above, is unpacked into
`Sources/LatheSWFRender/RenderHost/ruffle/` by the fetch script and ships in the
resource bundle alongside the code.

### The other thing to weigh, which is not a licence question

`LatheSWFRender` runs a WebAssembly interpreter over ActionScript from a
**user-supplied file**. It does so inside WebKit — the sanctioned place for
untrusted code on Apple's platforms — with nothing fetched at run time, and with
the host WebView refusing navigation to any scheme but its own. That is still
third-party bytecode from an untrusted file executing on a user's device, and an
App Store submission should weigh it deliberately rather than inherit it. It is
a separate product so that the decision is one you make.
