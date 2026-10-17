// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BridgeKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BridgeKitCore", targets: ["BridgeKitCore"]),
    ],
    targets: [
        .target(name: "BridgeKitCore"),
        .testTarget(name: "BridgeKitCoreTests", dependencies: ["BridgeKitCore"],
                    resources: [.copy("fixtures")]),
        // The reference server the Python harness talks to (Tests/harness).
        .executableTarget(name: "bridgekit-reference-server", dependencies: ["BridgeKitCore"],
                          path: "Tests/harness/ReferenceServer"),
        .executableTarget(name: "bridgekit-reference-launcher", dependencies: ["BridgeKitCore"],
                          path: "Tests/harness/ReferenceLauncher"),
    ]
)
