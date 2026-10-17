# Changelog

## 0.1.0 (unreleased)

- First version, moved from EK Bridge 0.11.1 (commit 9c726f2): the loopback HTTP server, the
  MCP server and service, JSON-RPC, rate limits, safe file loading, key files, the launcher
  and agent config writing.
- New seams for apps: `BridgeConfiguration`, `AgentAuthenticator`, `ToolRegistry`,
  `BridgeHandler`, `ToolContract`, `LauncherConfiguration`.
- Main-actor hops use `Task { @MainActor in … }`, so hosts that run `dispatchMain()` work under
  Swift 6's isolation checks.
- `BridgeKitCore` is a static library product, so apps built with plain `swiftc` link `libBridgeKitCore.a` from
  either SwiftPM build system.
- Timeouts pass an explicit tolerance to `Task.sleep`, so a 55 s answer isn't coalesced past agents' 60 s.
- `AgentKeyFiles` takes the key file kind (`.mcp-token` by default); the validator counts string lengths in
  UTF-8 bytes (default) or Unicode scalars (`BridgeConfiguration.stringLength`).
- Tool calls are dispatched asynchronously (`BridgeHandler.handle(_:) async`); cancellation
  and an app-chosen timeout answer come through `ToolCall.context`.
