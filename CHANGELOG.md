# Changelog

## 0.1.1 (unreleased)

- JSON-RPC ids are capped at 1,024 bytes as a response writes them (quotes and escapes included),
  so an app can budget a response exactly instead of reserving room for an id as long as the
  body. `BridgeConfiguration.maxIDBytes` sets the cap (default `JSONRPC.defaultMaxIDBytes`);
  `JSONRPC.parse(_:maxIDBytes:)` applies it.
- A message with a longer id gets `-32600` Invalid Request with `"id": null` (HTTP 400), checked
  before any other error that would echo the id. This changes behaviour for clients that send
  ids over 1 KiB. No real MCP client does: they send counters or UUIDs. Integer ids (at most 20
  bytes) are never affected.
- `ToolCall.id` carries the request's id, and `JSONRPCID.encodedByteCount` gives the bytes it
  takes in the response. `ToolCall.init` takes `id:` with a default, so existing calls still
  compile.
- `JSONRPCParseError` has a new case, `.idTooLong`. An exhaustive `switch` over it needs the case;
  neither EK Bridge nor Funes has one.

## 0.1.0

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
