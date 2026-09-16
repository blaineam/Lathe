# Vendored Ruffle

`RenderHost/ruffle/` holds **Ruffle's self-hosted web build**, unmodified, from a
pinned release. It is the Flash player this module drives inside a `WKWebView`.

| | |
|---|---|
| Upstream | <https://github.com/ruffle-rs/ruffle> |
| Release | `v0.6.0` — a stable release, not a nightly |
| Published | 2026-09-06 |
| Asset | `ruffle-0.6.0-web-selfhosted.zip` |
| SHA-256 | `e8acfacc37443303872379d0e215999af846854d1dd3fa8fac0a765445b43dbf` |
| Size | 10,525,002 bytes compressed |
| Licence | **Apache-2.0 OR MIT**, at your option |
| Copyright | Ruffle LLC \<ruffle@ruffle.rs\> and Ruffle contributors |

## The licence, explicitly

Ruffle is dual-licensed Apache-2.0 **or** MIT, at the user's option. Lathe is
Apache-2.0, so Lathe takes it under Apache-2.0 and the two are the same licence
with nothing to reconcile — no copyleft obligation, no source-disclosure trigger,
no per-application decision of the kind `LatheMP3`'s LGPL vendoring forces.

That said, **Apache-2.0 requires attribution and a copy of the licence in
distributions**, so an application shipping `LatheSWFRender` must carry Ruffle's
notice the same way it carries libwebp's. `fetch-upstream.sh` keeps upstream's
own licence files in `RenderHost/ruffle/`, where they are bundled as resources
alongside the code they cover, and `THIRD-PARTY-NOTICES.md` in the repository
root records it.

Ruffle is a clean-room reimplementation of the Flash Player. It contains no
Adobe code and requires no licence from Adobe, which is the question people
actually mean when they ask whether shipping a Flash player is allowed.

## Nothing here is committed

**The Ruffle build is not in this repository**, and that is the same arrangement
`LatheFetch` uses for CPython, taken for the same reasons:

- It is ~10 MB of JavaScript and WebAssembly. Committing it would put a binary
  artifact in a package whose stated policy is that it has none — see
  `Sources/CWebP/VENDORING.md`, and the note on generated test fixtures in
  `Package.swift`.
- Every clone of this repository, including everyone working only on image
  encoding, would pay for it forever, in git history rather than just on disk.
- A version bump would be a 10 MB commit rather than four edited lines.

So a fresh clone has an empty `RenderHost/ruffle/`, and:

- **`LatheSWFRender` builds, links and passes its whole test suite** with it
  empty. The suite drives the real page, the real scheme handler and the real
  capture path against a canvas it animates itself; see `RenderHost/shim.html`.
- **It cannot render a movie**, and says so by name:
  `LatheError.unsupportedOnThisPlatform`, naming the script below.

## Fetching it

```sh
./fetch-upstream.sh                  # fetch the pinned release into RenderHost/ruffle
./fetch-upstream.sh <destination>    # …somewhere else
./fetch-upstream.sh --print-checksum # download and print the hash, for a version bump
```

The script downloads the pinned asset, verifies it against the SHA-256 above —
and **refuses to unpack anything that does not match** — then unpacks it.

## Refreshing it

1. Change `RUFFLE_TAG` and `RUFFLE_VERSION` in `fetch-upstream.sh`.
2. `./fetch-upstream.sh --print-checksum`, and paste the result into both the
   script and the table above.
3. `swift test --scratch-path /tmp/lathe-build`
4. Render something real and look at it. The suite cannot do this step: it
   covers everything except Ruffle, because Ruffle is what is not committed.

## Why the whole directory is served, and no file is named

`ruffle.js` is only an entry point. It lazily loads its core JavaScript and its
`.wasm` from the directory it was itself served out of, and **those filenames
carry a content hash that changes with every release**. So `RenderSchemeHandler`
serves the directory whole and names nothing inside it: the alternative is
editing Swift on every version bump, with a player that loads and silently never
starts as the price of getting one name wrong.

Path traversal out of that directory is checked on the *resolved* path, because
everything requested under it is requested by third-party JavaScript.

## What a consumer is taking on

Beyond the licence, which is clean, there is a judgement that is not this file's
to make:

**This runs a WebAssembly interpreter over ActionScript from a user-supplied
file.** It runs inside WebKit — the sanctioned place for untrusted code on
Apple's platforms — nothing is fetched at run time, and the host WebView refuses
navigation to any scheme but its own, so a movie calling `getURL` cannot make it
fetch anything. It is still third-party bytecode from an untrusted file
executing on a user's device, and an App Store submission should weigh that
deliberately rather than inherit it.

That is precisely why `LatheSWFRender` is its own product and is not in the
`Lathe` umbrella. An application that wants to recover the artwork inside old
Flash files, and does not need to play them, should depend on `LatheSWF` alone
and ship none of this.
