// swift-tools-version: 6.0
// Lathe — an on-device media processing engine for Apple platforms.
//
// Tools version 6.0 (rather than the 5.9 minimum) is deliberate: it turns on the
// Swift 6 language mode, so `Sendable` correctness across the
// progress/cancellation seam is enforced by the compiler rather than by review.
// See README, "Toolchain".

import PackageDescription

let package = Package(
    name: "Lathe",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    // MARK: - The linking contract
    //
    // One product per module, plus an umbrella. Which one a consumer depends on
    // is a decision with consequences, so the shape is explicit rather than
    // convenient:
    //
    // * **Per-module products** let a consumer link exactly what it uses. An app
    //   that only recompresses stills depends on `LatheImage` and ships no video,
    //   PDF or audio code at all. This is the preferred way to depend on Lathe.
    //
    // * **`Lathe` is the umbrella, and it is media processing only.** It
    //   re-exports the five modules below and nothing else, and that is a
    //   standing guarantee rather than a description of today: everything
    //   reachable through it reads a file and writes a file.
    //
    // * **Anything that ingests media from the network gets its own product and
    //   stays out of the umbrella.** Downloaders and in-app browsers carry
    //   licence and app-review exposure that pure media processing does not, and
    //   an app that wants none of it must be able to guarantee it has none by
    //   choosing a product — not by auditing a transitive import graph after the
    //   fact. Such modules will be added here as additional `.library` entries
    //   with their own targets; they must never be added to the `Lathe` target's
    //   dependencies, because that would hand them to every existing consumer in
    //   a routine version bump.
    products: [
        // The umbrella: `import Lathe` re-exports the five media modules.
        // Deliberately excludes any network-ingest module, now and later.
        .library(name: "Lathe", targets: ["Lathe"]),

        // À la carte. Depend on these to link less.
        .library(name: "LatheCore", targets: ["LatheCore"]),
        .library(name: "LatheImage", targets: ["LatheImage"]),
        .library(name: "LatheVideo", targets: ["LatheVideo"]),
        .library(name: "LatheDoc", targets: ["LatheDoc"]),
        .library(name: "LatheAudio", targets: ["LatheAudio"]),
        .library(name: "LatheMeta", targets: ["LatheMeta"]),
        .library(name: "LatheLookup", targets: ["LatheLookup"]),

        // MP3 encoding. Its OWN product, and not part of the umbrella, because
        // it is the only non-permissive code in this package: it vendors LAME,
        // which is LGPL. Naming this product is how a consumer takes on that
        // obligation, and NOT naming it is how a consumer proves it has not.
        // See Sources/CLAME/VENDORING.md before depending on it.
        .library(name: "LatheMP3", targets: ["LatheMP3"]),

        // Salvage, not processing, and deliberately not in the umbrella. See
        // the target below for the argument.
        .library(name: "LatheSWF", targets: ["LatheSWF"]),

        // Rendering a Flash movie, as opposed to salvaging what is inside one.
        // Its own product for a reason worth choosing deliberately; see the
        // target.
        .library(name: "LatheSWFRender", targets: ["LatheSWFRender"]),

        // Network ingest, and the first module the rule above was written for.
        // `LatheFetch` embeds a CPython interpreter and installs Python packages
        // the user asks for at run time. It is a separate product precisely so
        // an application doing pure media processing can *prove* it links none
        // of that, by naming the products it depends on.
        .library(name: "LatheFetch", targets: ["LatheFetch"]),
    ],
    targets: [
        // MARK: - Umbrella

        // Media processing only. Adding a network-ingest module here would
        // silently give it to every consumer of the umbrella; see the note on
        // `products` above.
        .target(
            name: "Lathe",
            dependencies: [
                "LatheCore", "LatheImage", "LatheVideo", "LatheDoc", "LatheAudio", "LatheMeta",
            ]
        ),

        // MARK: - Domain modules
        //
        // Split by domain so each can grow — and acquire its own third-party
        // dependencies — without dragging the others along. The still-image
        // module has a WebP encoder (below); the document module will need a PDF
        // writer, the video module an optional container fallback. Keeping them
        // apart means a consumer that only needs stills never links a PDF
        // library.

        .target(name: "LatheCore"),

        .target(name: "LatheImage", dependencies: ["LatheCore", "CWebP"]),

        // LatheVideo writes still images too — a thumbnail is a still — so it
        // sits on top of LatheImage in order to reuse one capability probe
        // rather than growing a second one. The dependency runs in this
        // direction only: `import LatheImage` still links no video code.
        .target(name: "LatheVideo", dependencies: ["LatheCore", "LatheImage"]),

        // LatheDoc recompresses the images *inside* PDFs and CBZs, so it sits
        // on top of LatheImage rather than beside it.
        .target(name: "LatheDoc", dependencies: ["LatheCore", "LatheImage"]),

        .target(name: "LatheAudio", dependencies: ["LatheCore"]),

        // Metadata: reading and editing what a file SAYS about itself, as
        // opposed to what it contains. Deliberately depends on LatheCore alone.
        // Nothing here decodes or encodes media — an injection is a container
        // rewrite — so a consumer that only wants to fix a title should not have
        // to link an image encoder or a video pipeline to do it.
        .target(name: "LatheMeta", dependencies: ["LatheCore"]),

        // Online metadata lookup: TMDb for film and television, OpenSubtitles
        // for subtitles, each reached with the USER's own API key.
        //
        // Deliberately NOT part of LatheFetch, and the distinction is the one
        // the linking contract exists to make. LatheFetch downloads media and
        // is the module an App Store build must be able to leave out; this
        // fetches a synopsis and a poster for a file the user already has,
        // which is an ordinary API call. Keeping them apart is what lets a
        // store app enrich a library without linking a downloader.
        //
        // Separate from LatheMeta as well, so a consumer that only edits tags
        // offline links no networking at all.
        .target(name: "LatheLookup", dependencies: ["LatheCore", "LatheMeta"]),

        // MP3 encoding, kept apart from LatheAudio on purpose. Apple ships no
        // MP3 encoder on any platform — only a decoder — so this is the one
        // capability that cannot be had from the system, and the only way to
        // have it is to vendor an LGPL library. Separating it means the rest of
        // the package stays permissive and a consumer chooses.
        .target(
            name: "LatheMP3",
            dependencies: ["LatheCore", "CLAME"]
        ),

        // MARK: - Salvage
        //
        // `LatheSWF` recovers the embedded JPEG, PNG, GIF, MP3 and PCM out of
        // Adobe Flash `.swf` files. It is NOT in the `Lathe` umbrella, and the
        // reason is not the licence one that keeps `LatheMP3` out, nor the
        // network one that keeps `LatheFetch` out. It is a third reason, and it
        // deserves its own entry in the contract:
        //
        // * **It is a parser for hostile input, and nothing else here is.**
        //   Every other module in this package hands bytes to Apple's own
        //   frameworks, which are hardened, sandboxed where it matters, and
        //   patched by somebody else. This module walks an untrusted binary
        //   container by hand — tag codes, declared lengths, bit-packed fields,
        //   recursive sprites — for a format whose last security update was a
        //   long time ago and whose surviving files come from wherever old
        //   Flash files come from. That is real attack surface, and an
        //   application that never opens a `.swf` should be able to prove it
        //   links none of it by naming its products, rather than by auditing an
        //   import graph after a version bump handed it one.
        //
        // * **It salvages; it does not process.** The umbrella's standing
        //   promise is media processing: read a file, write a file, in formats
        //   the system understands. SWF capture is archaeology — a one-way
        //   recovery of what is left inside a container nothing can play any
        //   more. It produces inputs *for* the media modules rather than being
        //   one of them, and the output of an extraction is an ordinary folder
        //   of JPEGs and MP3s that `LatheImage` and `LatheAudio` then handle
        //   with no knowledge that Flash was ever involved.
        //
        // It depends on `LatheCore` alone — the error taxonomy and the logging
        // subsystem — and deliberately not on `LatheImage`, even though it
        // writes PNGs. It writes them through ImageIO, which is a system
        // framework; depending on `LatheImage` to reuse one format enum would
        // link libwebp and a full encoder into every consumer that only wanted
        // to open a Flash file.
        .target(name: "LatheSWF", dependencies: ["LatheCore"]),

        // Rendering, which is a different thing from the salvage above and
        // carries a different set of consequences.
        //
        // `LatheSWF` reads a container. `LatheSWFRender` runs a WebAssembly
        // build of Ruffle inside a `WKWebView` and captures the frames it draws
        // — which means it executes the ActionScript inside a user-supplied file.
        // It is a separate product, and not in the umbrella, because that is a
        // decision an application has to make rather than inherit:
        //
        // * **It interprets untrusted bytecode.** Inside WebKit, which is the
        //   sanctioned place for it on Apple's platforms, and with nothing
        //   fetched at run time — but an App Store submission should weigh it
        //   deliberately, and an app that only salvages bitmaps should be able to
        //   prove it ships none of it.
        // * **It costs about 10 MB.** The Ruffle build is a bundled resource, so
        //   an app that links this carries it whether it renders anything or not.
        // * **It needs WebKit**, which `LatheSWF` does not, and which an
        //   extension or a command-line tool may not want.
        //
        // It depends on `LatheImage` for `FrameSequence`, which is how its output
        // reaches `AnimatedImageWriter`, `FrameVideoWriter` and
        // `FrameDocumentWriter` without this target growing an encoder of its
        // own. The Ruffle artifact itself is NOT committed — `fetch-upstream.sh`
        // downloads the pinned release against a recorded SHA-256, exactly as
        // `LatheFetch` does for CPython. This target builds and tests with it
        // absent; see Sources/LatheSWFRender/VENDORING.md.
        .target(
            name: "LatheSWFRender",
            dependencies: ["LatheCore", "LatheSWF", "LatheImage"],
            exclude: [
                "VENDORING.md",
                "fetch-upstream.sh",
            ],
            resources: [.copy("RenderHost")]
        ),

        // MARK: - Network ingest
        //
        // An embedded CPython interpreter, and an installer for pure-Python
        // packages the user acquires at run time.
        //
        // ## Why this target has no binary dependency
        //
        // The reflex here is the opposite of the one for libwebp below: a
        // `binaryTarget` on beeware/Python-Apple-support's `Python.xcframework`.
        // Three things rule it out, and the third is decisive:
        //
        // * **SwiftPM cannot consume the published artifact.** A `binaryTarget`
        //   takes either a local path or a remote `.xcframework.zip` with a
        //   checksum. Every Python-Apple-support release asset is a `.tar.gz`.
        // * **Committing ~40 MB of binary is not acceptable here**, and a fetch
        //   script producing a *local* binary target would make `swift build`
        //   fail on a fresh clone until somebody ran it — including for the
        //   existing media modules, which have nothing to do with Python.
        // * **The xcframework is not the whole dependency.** The pure-Python
        //   standard library — 2,500-odd files — and the per-slice `lib-dynload`
        //   extension modules sit *beside* the slices in that archive, not
        //   inside them. SwiftPM embeds a binary target's framework and has no
        //   mechanism to place anything else in an app bundle, so the
        //   binaryTarget route delivers an interpreter that cannot find its own
        //   standard library and aborts. Upstream's own integration is an Xcode
        //   build phase, which is an application-level thing.
        //
        // So the interpreter is **acquired by the application and bound at run
        // time**: fifteen stable-ABI symbols resolved through `dlsym`, against
        // whatever CPython the process has — the `Python.framework` an iOS app
        // embedded, or the host's framework build on macOS. That keeps
        // `swift build`, `swift test` and the iOS build working with nothing
        // fetched, which is also what keeps this target from taxing every other
        // module in the package. See Sources/LatheFetch/VENDORING.md for the
        // full argument, the pinned upstream release, and what a consumer has to
        // do.
        //
        // It depends on LatheCore for the logging subsystem, so one predicate
        // still filters the whole package out of a host's logs. Nothing in
        // LatheCore depends back.
        .target(
            name: "LatheFetch",
            dependencies: ["LatheCore"],
            exclude: [
                "VENDORING.md",
                "fetch-upstream.sh",
            ]
        ),

        // MARK: - Vendored C
        //
        // libwebp, as source, compiled by SwiftPM like any other target.
        //
        // ## Why not an xcframework
        //
        // The reflex for a C dependency on Apple platforms is to build it into an
        // `.xcframework` and consume it as a `binaryTarget`. libwebp does not
        // need that, and taking it would cost real maintainability:
        //
        // * **One `swift build` covers every platform.** iOS, macOS, both
        //   simulators, Catalyst, and whatever Apple ships next — all from the
        //   same sources, with no per-slice build script, no `lipo`, no
        //   `-create-xcframework`, and no slice that somebody forgot to rebuild.
        // * **Nothing binary is committed.** No artifact in git, no release
        //   pipeline, no checksum to keep in step with a tag, and no CI job that
        //   has to run green before anyone can consume a change.
        // * **Upstream updates are a source refresh.** `refresh-upstream.sh`
        //   against a new tag, then `swift test` — rather than rebuild,
        //   re-notarise, re-upload, re-checksum.
        //
        // libwebp is plain portable C with no exotic build requirements, so none
        // of what an xcframework buys (a closed-source blob, a hostile build
        // system, a toolchain this package does not have) applies.
        //
        // ## Header layout
        //
        // Upstream includes itself as `"src/webp/encode.h"` — paths relative to
        // its own repository root — so `upstream/` is put on the header search
        // path and the vendored tree keeps upstream's directory shape verbatim.
        // That is what lets `refresh-upstream.sh` be a copy rather than a
        // rewrite. `include/` holds Lathe's one-line umbrella header, so the
        // Swift side sees `WebPEncode` and none of libwebp's internals.
        //
        // ## SIMD
        //
        // No `HAVE_CONFIG_H`, deliberately: libwebp's own `cpu.h` then selects
        // its kernels from the compiler's architecture macros, which is exactly
        // the right behaviour under SwiftPM's one-build-per-arch model. NEON
        // turns on from `__aarch64__` with no flag needed, and on Apple silicon
        // it is unconditional rather than runtime-probed. x86_64 gets SSE2 the
        // same way (`__SSE2__` is baseline); SSE4.1 and AVX2 need per-file
        // `-msse4.1` / `-mavx2`, which SwiftPM cannot express, so those
        // translation units compile to upstream's own empty stubs and the SSE2
        // path runs. See VENDORING.md.
        .target(
            name: "CWebP",
            path: "Sources/CWebP",
            exclude: [
                "VENDORING.md",
                "refresh-upstream.sh",
                "upstream/AUTHORS",
                "upstream/COPYING",
                "upstream/PATENTS",
                "upstream/README-VENDORED.txt",
            ],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("upstream")]
        ),

        // LAME, vendored. **LGPL** — the only non-permissive code in this
        // package. See Sources/CLAME/VENDORING.md.
        .target(
            name: "CLAME",
            path: "Sources/CLAME",
            exclude: [
                "refresh-upstream.sh",
                "upstream/COPYING",
                "upstream/README-VENDORED.txt",
            ],
            sources: ["upstream/libmp3lame"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("upstream"),
                .headerSearchPath("upstream/libmp3lame"),
                .headerSearchPath("include"),
                .define("HAVE_CONFIG_H"),
                // LAME's own sources warn heavily under modern clang, and none
                // of it is actionable without patching upstream — which this
                // package does not do, so that a version bump stays a copy.
                .unsafeFlags(["-Wno-everything"]),
            ]
        ),

        // MARK: - Test support

        // Test fixtures are *generated*, never committed: `AVAssetWriter` and
        // `AVAudioFile` synthesise every clip the suite needs at run time. No
        // binary media lives in this repository, so there is nothing to keep in
        // sync with the encoders and nothing whose provenance or licence has to
        // be explained.
        //
        // It is an ordinary target rather than a test target because two test
        // targets — video and audio — need the same clips, and SwiftPM test
        // targets cannot depend on one another. It lives outside `Sources` so
        // that directory keeps mirroring the product list, and it is
        // deliberately *not* a product: nothing outside this package can import
        // it.
        .target(
            name: "LatheFixtures",
            dependencies: ["LatheCore"],
            path: "TestSupport/LatheFixtures"
        ),

        // MARK: - Tests

        .testTarget(name: "LatheCoreTests", dependencies: ["LatheCore"]),
        .testTarget(
            name: "LatheRemoteTests",
            dependencies: ["LatheCore", "LatheDoc", "LatheMeta", "LatheFixtures"]
        ),
        .testTarget(name: "LatheImageTests", dependencies: ["LatheImage", "LatheFixtures"]),
        .testTarget(name: "LatheVideoTests", dependencies: ["LatheVideo", "LatheFixtures"]),
        .testTarget(name: "LatheDocTests", dependencies: ["LatheDoc", "LatheFixtures"]),
        .testTarget(name: "LatheAudioTests", dependencies: ["LatheAudio", "LatheFixtures"]),
        .testTarget(name: "LatheMetaTests", dependencies: ["LatheMeta", "LatheFixtures"]),
        .testTarget(name: "LatheLookupTests", dependencies: ["LatheLookup"]),
        .testTarget(name: "LatheSWFTests", dependencies: ["LatheSWF"]),
        .testTarget(name: "LatheSWFRenderTests", dependencies: ["LatheSWFRender"]),
        .testTarget(name: "LatheMP3Tests", dependencies: ["LatheMP3", "LatheFixtures"]),

        // The Python suite runs against whatever CPython the host machine has,
        // and records a known issue naming the reason when there is none —
        // rather than failing, which would make an unconfigured machine look
        // like a broken package, or passing quietly, which would make it look
        // like a tested one. Its network tests are opt-in; see the suite.
        .testTarget(name: "LatheFetchTests", dependencies: ["LatheFetch"]),
    ]
)
