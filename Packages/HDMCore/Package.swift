// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HDMCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HDMCore", targets: ["HDMCore"]),
        .library(name: "HDMIPC", targets: ["HDMIPC"]),
        .library(name: "HDMTestSupport", targets: ["HDMTestSupport"]),
        .executable(name: "hdm-bridge", targets: ["hdm-bridge"]),
    ],
    targets: [
        .target(name: "HDMCore"),
        // Thin wire-protocol module shared by the app, the bridge and the Safari appex (spec §4).
        .target(name: "HDMIPC"),
        .executableTarget(name: "hdm-bridge", dependencies: ["HDMIPC"]),
        .target(name: "HDMTestSupport"),
        .testTarget(name: "HDMCoreTests", dependencies: ["HDMCore", "HDMTestSupport"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "HDMIPCTests", dependencies: ["HDMIPC"]),
    ]
)
