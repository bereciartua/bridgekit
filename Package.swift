// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BridgeKit",
    platforms: [.macOS(.v14)],
    products: [
        // Static, so apps built with plain swiftc can link libBridgeKitCore.a.
        .library(name: "BridgeKitCore", type: .static, targets: ["BridgeKitCore"]),
    ],
    targets: [
        .target(name: "BridgeKitCore"),
        .testTarget(name: "BridgeKitCoreTests", dependencies: ["BridgeKitCore"],
                    resources: [.copy("fixtures")]),
        // The reference server the Python harness talks to (Tests/harness).
        .executableTarget(name: "bridgekit-reference-server", dependencies: ["BridgeKitCore"],
                          path: "Tests/harness/ReferenceServer", resources: [.copy("tools.json")]),
        .executableTarget(name: "bridgekit-reference-launcher", dependencies: ["BridgeKitCore"],
                          path: "Tests/harness/ReferenceLauncher"),
    ]
)
