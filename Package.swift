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
    products: [
        // The umbrella. `import Lathe` re-exports every module below.
        .library(name: "Lathe", targets: ["Lathe"]),
    ],
    targets: [
        // MARK: - Umbrella

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

        .target(name: "LatheVideo", dependencies: ["LatheCore"]),

        // LatheDoc recompresses the images *inside* PDFs and CBZs, so it sits
        // on top of LatheImage rather than beside it.
        .target(name: "LatheDoc", dependencies: ["LatheCore", "LatheImage"]),

        .target(name: "LatheAudio", dependencies: ["LatheCore"]),

        // MARK: - Tests

        .testTarget(name: "LatheCoreTests", dependencies: ["LatheCore"]),
        .testTarget(name: "LatheImageTests", dependencies: ["LatheImage"]),
        .testTarget(name: "LatheVideoTests", dependencies: ["LatheVideo"]),
        .testTarget(name: "LatheDocTests", dependencies: ["LatheDoc"]),
        .testTarget(name: "LatheAudioTests", dependencies: ["LatheAudio"]),
    ]
)
