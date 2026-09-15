// swift-tools-version: 6.0
//
// Lathe.app — the Mac app.
//
// A separate package depending on Lathe by local path, for the same reason the
// benchmarks are: the app links things a library consumer should not inherit,
// and `swift build` at the repository root stays a library build.
import Foundation
import PackageDescription

// The embedded Tor client links a 15 MB static framework that is a release
// asset rather than a repository file — `App/Vendor/Tor/slim-tor.sh` fetches
// and slims it. When it is absent the app still builds and Tor routing falls
// back to an external proxy, because requiring a 15 MB download before anyone
// can compile the app is a bad trade for a feature most contributors will not
// touch.
let torFramework = "Vendor/Tor/tor.xcframework"
let hasTor = FileManager.default.fileExists(
    atPath: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent(torFramework).path)

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
            ] + (hasTor ? [Target.Dependency.target(name: "CTorShim")] : []),
            swiftSettings: hasTor ? [.define("LATHE_EMBEDDED_TOR")] : [],
            // Tor's static library expects the system's compression and crypto
            // to be linked around it. The upstream build leaves these to the
            // consumer, which for an Xcode project is a checkbox and here is
            // this line.
            linkerSettings: hasTor
                ? [.linkedLibrary("z"), .linkedLibrary("lzma"),
                   .linkedFramework("CoreFoundation"), .linkedFramework("Security")]
                : []
        )
    ] + (hasTor
         ? [Target.binaryTarget(name: "CTor", path: torFramework),
            // A header-only C target declaring the handful of public entry
            // points, because the framework ships no module map and its
            // headers are Tor's whole internal tree.
            Target.target(name: "CTorShim", dependencies: [.target(name: "CTor")])]
         : [])
)
