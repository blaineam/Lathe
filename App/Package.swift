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
    platforms: [.macOS("26.0")],
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
                // The downloader. This is the ONE consumer that is meant to
                // link it — the whole point of it being a separate product is
                // that an App Store build can leave it out, and this app is not
                // an App Store build.
                .product(name: "LatheFetch", package: "Lathe"),
            ]
        )
    ]
)
