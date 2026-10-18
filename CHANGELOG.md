# Changelog

## 0.2.0 (unreleased)

- New product, `BridgeKitRemote`: EK Bridge's Remote Access tier, moved from EK Bridge at
  e753b22 (0.11.2 plus BridgeKit 0.1.1) with its tests. The Remote Access listener, its HTTP
  gate and health nonces; the OAuth 2.1 authorization server, its store
  (`remote-connections.json`, unchanged format) and sign-in pages; the client-metadata fetch;
  the tunnel checks, parsers and Switch Tunnel state; the reachability test and `KeepAwake`.
- Apps configure it with `RemoteBridgeConfiguration`: the default port, the remote-token,
  access, refresh and client-secret prefixes, the OAuth scope, the client-metadata `User-Agent`
  and the store's folder, and `RemoteTexts` for 401s and the sign-in pages
  (`RemoteTexts.standard(displayName:agent:)` gives EK Bridge's words with `agent: "client"`).
- `RemoteAuthenticator` is the app's side: a remote token to an agent, whether an OAuth agent
  still has cloud access, and its name.
- Tunnel status, the reachability test's failures (`RemoteProbeFailure`) and `TunnelProvider`
  are typed; the words, commands and steps for each tunnel stay in the app. The health route
  reports the tunnel by `TunnelProvider.wireName`, as before.
- `CIMDFetcher` takes the `User-Agent` and an explicit `CIMDFetcher.Testing` value for a local
  HTTPS fixture, instead of EK Bridge's compile-time test flag.
- The reference server gains the remote listener and a fake sign-in approver;
  `Tests/harness/remote_test.py` (from EK Bridge's `run_remote` and `run_oauth`) drives it.
- BridgeKitCore is unchanged.

## 0.1.1

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
- A client that pipelines requests without reading the replies can no longer make the server
  buffer them without limit. On macOS 15 a flood of unread 404s grew the server by 215 MB in
  3 s. `HTTPConnection` now reads more only after the parser has used what it holds, and starts
  the next request only once the network stack has taken the last reply. A reply the stack
  hasn't taken within 30 s closes the connection (`HTTPConnection.writeTimeout`). This was
  present in 0.1.0 and in EK Bridge 0.11.2, where the code came from.

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
