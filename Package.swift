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
    ],
    targets: [
        // MARK: - Umbrella

        // Media processing only. Adding a network-ingest module here would
        // silently give it to every consumer of the umbrella; see the note on
        // `products` above.
        .target(
            name: "Lathe",
            dependencies: ["LatheCore", "LatheImage", "LatheVideo", "LatheDoc", "LatheAudio"]
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
        .testTarget(name: "LatheImageTests", dependencies: ["LatheImage"]),
        .testTarget(name: "LatheVideoTests", dependencies: ["LatheVideo", "LatheFixtures"]),
        .testTarget(name: "LatheDocTests", dependencies: ["LatheDoc", "LatheFixtures"]),
        .testTarget(name: "LatheAudioTests", dependencies: ["LatheAudio", "LatheFixtures"]),
    ]
)
