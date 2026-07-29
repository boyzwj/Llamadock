// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LlamadockCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "LlamadockCore",
            targets: ["LlamadockCore"]
        )
    ],
    targets: [
        .target(name: "LlamadockCore"),
        .testTarget(
            name: "LlamadockCoreTests",
            dependencies: ["LlamadockCore"]
        )
    ]
)
