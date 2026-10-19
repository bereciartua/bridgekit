// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BridgeKit",
    platforms: [.macOS(.v14)],
    products: [
        // Static, so apps built with plain swiftc can link libBridgeKitCore.a.
        .library(name: "BridgeKitCore", type: .static, targets: ["BridgeKitCore"]),
        // Remote Access on top of the core: the tunnel listener, OAuth, client
        // metadata and tunnel checks. Static, for the same reason.
        .library(name: "BridgeKitRemote", type: .static, targets: ["BridgeKitRemote"]),
    ],
    targets: [
        .target(name: "BridgeKitCore"),
        .target(name: "BridgeKitRemote", dependencies: ["BridgeKitCore"]),
        .testTarget(name: "BridgeKitCoreTests", dependencies: ["BridgeKitCore"],
                    resources: [.copy("fixtures")]),
        .testTarget(name: "BridgeKitRemoteTests", dependencies: ["BridgeKitRemote"],
                    resources: [.copy("fixtures")]),
        // The reference server the Python harness talks to (Tests/harness).
        .executableTarget(name: "bridgekit-reference-server", dependencies: ["BridgeKitCore", "BridgeKitRemote"],
                          path: "Tests/harness/ReferenceServer", resources: [.copy("tools.json")]),
        .executableTarget(name: "bridgekit-reference-launcher", dependencies: ["BridgeKitCore"],
                          path: "Tests/harness/ReferenceLauncher"),
    ]
)
