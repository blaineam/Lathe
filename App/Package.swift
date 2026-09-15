// swift-tools-version: 6.0
//
// Lathe.app — the Mac app.
//
// A separate package depending on Lathe by local path, for the same reason the
// benchmarks are: the app links things a library consumer should not inherit,
// and `swift build` at the repository root stays a library build.
import PackageDescription

let package = Package(
    name: "LatheApp",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(
            name: "LatheApp",
            dependencies: [
                .product(name: "LatheCore", package: "Lathe"),
                .product(name: "LatheImage", package: "Lathe"),
                .product(name: "LatheVideo", package: "Lathe"),
                .product(name: "LatheAudio", package: "Lathe"),
                .product(name: "LatheDoc", package: "Lathe"),
                .product(name: "LatheMeta", package: "Lathe"),
            ]
        )
    ]
)
