# Vendored Ruffle

`RenderHost/ruffle/` holds **Ruffle's self-hosted web build** — five files from a
pinned release, each byte-identical to upstream's. It is the Flash player this
module drives inside a `WKWebView`, and it is committed to this repository.

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
notice the same way it carries libwebp's. Upstream's own licence files,
`LICENSE_APACHE` and `LICENSE_MIT`, are among the five files in
`RenderHost/ruffle/`, so they ship in the resource bundle beside the code they
cover, and `THIRD-PARTY-NOTICES.md` in the repository root records it.

Ruffle is a clean-room reimplementation of the Flash Player. It contains no
Adobe code and requires no licence from Adobe, which is the question people
actually mean when they ask whether shipping a Flash player is allowed.

## What is committed, and why it has to be

| File | Bytes | SHA-256 (first 16) | What it is |
|---|---:|---|---|
| `ruffle.js` | 465,076 | `a686a305345b0654` | entry point; installs `window.RufflePlayer` |
| `core.ruffle.c80159b526e567babaf5.js` | 108,322 | `624b0b23bc4460d7` | the WebAssembly glue for the build below |
| `826bb0938097485a2c9d.wasm` | 14,244,515 | `e4ba64aa1dc9f7f2` | Ruffle itself, extensions build |
| `LICENSE_APACHE` | 9,723 | `62c7a1e35f564068` | upstream's licence |
| `LICENSE_MIT` | 1,097 | `4de9338a7879c68e` | upstream's licence |

The full hashes are in `fetch-upstream.sh`, which checks them.

**This is the one binary artifact in the package**, and the house rule against
them — see `Sources/CWebP/VENDORING.md`, and the note on generated test
fixtures in `Package.swift` — gives way here for a reason that does not apply
to anything else:

- **SwiftPM gives a consumer only what is in the package.** An application that
  depends on `LatheSWFRender` gets exactly the resources present when SwiftPM
  checks the package out and builds it. There is no build hook that runs a
  package's fetch script on a consumer's machine, a `binaryTarget` carries a
  framework rather than a folder of web resources, and SwiftPM has no mechanism
  for a remote resource. A fetch-at-development-time arrangement, which is what
  this module had at first, builds cleanly and ships every application an empty
  folder.
- **`LatheFetch` is not a precedent.** It binds CPython at run time because the
  application embeds its own interpreter through an Xcode build phase. Ruffle
  has no equivalent: a render host page loads it from the bundle, so it has to
  be in the bundle.
- **Downloading it at run time was the alternative, and it is worse** for the
  application this was done for. It would put a network fetch of executable
  code into an App Store app — exactly what the "nothing is fetched at run
  time" answer below exists to rule out — and a user who opened a `.swf`
  offline would get nothing. `RuffleRuntime(directory:)` still accepts any
  directory, so an application that wants that trade can make it.

### What it costs

| | |
|---|---|
| Repository (git objects, compressed) | ≈ 5.1 MB, once; a version bump adds another ≈ 5 MB |
| Installed app bundle | 14.8 MB (`Lathe_LatheSWFRender.bundle`) |
| App Store download | ≈ 5 MB — the `.wasm` deflates to 4.98 MB |

Only applications that name the `LatheSWFRender` product pay the bundle cost.
Every clone pays the repository cost, which is the real concession here.

### What was left out of the archive

The release asset is 12 files and 29 MB unpacked. Seven are not shipped:

- **The vanilla build** — `core.ruffle.f000070ea72f8ae4fe3a.js` and
  `72a20ef1c0b8ceb37720.wasm`, another 14.4 MB. `ruffle.js` validates five
  WebAssembly features — bulk memory, SIMD, non-trapping float-to-int, sign
  extension, reference types — and loads the vanilla build only if one is
  missing. Every WebKit this package supports (iOS 17, macOS 14 and later) has
  all five. `WebAssemblySupport.probe()` validates the same five modules, so a
  system that would have needed the vanilla build is told which feature it
  lacks rather than failing inside Ruffle with "Failed to load Ruffle WASM".
- **Source maps** — `ruffle.js.map` and the two `core.ruffle.*.js.map`, 1.5 MB,
  for a debugger nobody attaches to an offscreen WebView. The scripts' trailing
  `sourceMappingURL` comments are left as upstream wrote them, so the files stay
  byte-identical; they are only followed when a Web Inspector is open.
- **`package.json` and `README.md`** — npm packaging.

Nothing that is shipped is modified.

## Checking it

```sh
./fetch-upstream.sh --verify         # check the committed files against the pin
./fetch-upstream.sh                  # re-download, verify, and reinstall them
./fetch-upstream.sh <destination>    # …somewhere else
./fetch-upstream.sh --print-checksum # download and print the archive hash, for a bump
```

The script downloads the pinned asset, verifies the archive against the SHA-256
above — and **refuses to unpack anything that does not match** — then copies out
the five files, verifies each against its own recorded hash, and only then
replaces the directory.

## Refreshing it

1. Change `RUFFLE_TAG` and `RUFFLE_VERSION` in `fetch-upstream.sh`.
2. `./fetch-upstream.sh --print-checksum`, and paste the result into both the
   script and the table above.
3. **Re-derive the file list by hand.** Upstream's filenames carry content
   hashes, so the `SHIPPED` list cannot survive a bump. Unpack the asset, and in
   `ruffle.js` find where it chooses between its two core chunks (search for
   `falling back to the vanilla`): keep the chunk and `.wasm` it loads when every
   feature check passes, and check whether the five feature-detection modules
   still match `WebAssemblySupport.rufflesRequiredExtensions`. Record the new
   names and hashes in the script and in the table above.
4. `./fetch-upstream.sh`, then
   `swift test --scratch-path /tmp/lathe-build --no-parallel`. `RuffleRenderTests`
   plays a synthesised movie through the new build and checks every frame.
5. Render something real and look at it.

## The traps this module has already met

Each of these produced a render that looked plausible and was wrong, and each is
handled in `RenderHost/shim.html` or `RenderSchemeHandler.swift`:

- **The `.wasm` must be served as `application/wasm`**, or streaming
  instantiation rejects it.
- **Every response must be an HTTP 200.** A plain `URLResponse` reaches `fetch`
  with status 0, Ruffle rebuilds the `.wasm` response with
  `new Response(stream, original)` to report progress, and that constructor
  throws for a status outside 200…599 — reported only as "Failed to load Ruffle
  WASM".
- **`requestAnimationFrame` stops for a page WebKit thinks is invisible**, and an
  offscreen host is one. Ruffle's player loop runs on it, so the movie froze. The
  page races every request against a fallback clock.
- **A `setTimeout` fallback froze too**, after about ten frames: each timeout is
  created inside the previous one, and WebKit aligns deeply nested timers in a
  hidden page to one-second boundaries. The fallback is scheduled from a
  MessageChannel task, which resets the nesting.
- **Most frames read back blank**, because Ruffle redraws only when the movie
  advances and a WebGL canvas without `preserveDrawingBuffer` is empty between
  draws. The page creates WebGL contexts with it.
- **A GPU renderer can create its context and still panic.** In the iOS
  Simulator both of Ruffle's WebGL renderers do, before the first frame, with
  nothing but a console error to show for it. The page watches the console for
  Rust panics, and when no renderer was requested it starts a fresh player with
  Ruffle's canvas renderer; `SWFRenderResult.renderer` reports which one drew.
- **The canvas is in device pixels** — 2× on a Retina display — so frames are
  scaled back to the movie's size.
- **A resource directory named `Resources` breaks iOS codesigning**, which is why
  this one is `RenderHost`.

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
fetch anything. Ruffle is also configured to refuse first
(`allowNetworking: "none"`, `openUrlMode: "deny"`), and the scheme handler serves
nothing but the page, the movie and this directory. It is still third-party
bytecode from an untrusted file executing on a user's device, and an App Store
submission should weigh that deliberately rather than inherit it. **Committing
the build changes none of that; it only means the question is now live for any
application that names the product.**

That is precisely why `LatheSWFRender` is its own product and is not in the
`Lathe` umbrella. An application that wants to recover the artwork inside old
Flash files, and does not need to play them, should depend on `LatheSWF` alone
and ship none of this.
