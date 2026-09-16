// swift-tools-version: 6.0
//
// The comparison harness. **A separate package on purpose.**
//
// It depends on Lathe by local path rather than living inside it, so that
// nothing here — not the subprocess calls it makes to run the tools it compares
// against, not its dependency on LatheMP3 and therefore on LGPL code — can reach
// a consumer of the library. `swift build` in the repository root does not build
// any of this.
import PackageDescription

let package = Package(
    name: "lathe-bench",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "..")],
    targets: [
        // The images on the documentation site. A separate executable so the
        // site's pictures are produced BY the library they advertise, rather
        // than exported once by hand and quietly drifting from what the code
        // actually does.
        .executableTarget(
            name: "lathe-siteassets",
            dependencies: [
                .product(name: "LatheCore", package: "Lathe"),
                .product(name: "LatheImage", package: "Lathe"),
                .product(name: "LatheVideo", package: "Lathe"),
            ]
        ),
        .executableTarget(
            name: "lathe-bench",
            dependencies: [
                .product(name: "LatheCore", package: "Lathe"),
                .product(name: "LatheImage", package: "Lathe"),
                .product(name: "LatheVideo", package: "Lathe"),
                .product(name: "LatheAudio", package: "Lathe"),
                .product(name: "LatheDoc", package: "Lathe"),
                .product(name: "LatheMeta", package: "Lathe"),
                .product(name: "LatheMP3", package: "Lathe"),
            ]
        )
    ]
)
