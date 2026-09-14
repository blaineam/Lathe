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
        // Split by domain so each can grow — and acquire its own binary
        // dependencies — without dragging the others along. The still-image
        // module will eventually need a WebP encoder, the document module a PDF
        // writer, the video module an optional container fallback. Keeping them
        // apart means a consumer that only needs stills never links a PDF
        // library.

        .target(name: "LatheCore"),

        .target(name: "LatheImage", dependencies: ["LatheCore"]),

        // LatheVideo writes still images too — a thumbnail is a still — so it
        // sits on top of LatheImage in order to reuse one capability probe
        // rather than growing a second one. The dependency runs in this
        // direction only: `import LatheImage` still links no video code.
        .target(name: "LatheVideo", dependencies: ["LatheCore", "LatheImage"]),

        // LatheDoc recompresses the images *inside* PDFs and CBZs, so it sits
        // on top of LatheImage rather than beside it.
        .target(name: "LatheDoc", dependencies: ["LatheCore", "LatheImage"]),

        .target(name: "LatheAudio", dependencies: ["LatheCore"]),

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
        .testTarget(name: "LatheDocTests", dependencies: ["LatheDoc"]),
        .testTarget(name: "LatheAudioTests", dependencies: ["LatheAudio", "LatheFixtures"]),
    ]
)
