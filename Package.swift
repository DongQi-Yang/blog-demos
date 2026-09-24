// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlogDemos",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FMP4Muxer", targets: ["FMP4Muxer"]),
        .library(name: "FilterGraph", targets: ["FilterGraph"]),
        .executable(name: "blog-demos", targets: ["DemoCLI"]),
    ],
    targets: [
        .target(name: "FMP4Muxer"),
        .target(name: "FilterGraph"),
        .executableTarget(name: "DemoCLI", dependencies: ["FMP4Muxer"]),
        .testTarget(name: "FMP4MuxerTests", dependencies: ["FMP4Muxer"]),
        .testTarget(name: "FilterGraphTests", dependencies: ["FilterGraph"]),
    ]
)
