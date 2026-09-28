// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HDMCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HDMCore", targets: ["HDMCore"]),
        .library(name: "HDMTestSupport", targets: ["HDMTestSupport"]),
    ],
    targets: [
        .target(name: "HDMCore"),
        .target(name: "HDMTestSupport"),
        .testTarget(name: "HDMCoreTests", dependencies: ["HDMCore", "HDMTestSupport"],
                    resources: [.copy("Fixtures")]),
    ]
)
