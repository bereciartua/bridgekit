# Changelog

## 0.4.1

A Remote Access setup on Tailscale Funnel's port 8443 or 10000 can move to 443, which claude.ai and ChatGPT need. Such setups come from 0.3.0's other public ports or a port picked by hand; until now they showed as running, or got start commands for the old port.

- `TailscaleFunnelCommand.moveTo443(_:address:)` returns a `FunnelPorts.Move` once 443 can take the app's paths (`FunnelPorts.sharable(443)`). It's nil when the app is on 443 already, or the check couldn't read what Funnel serves.
- The move has:
  - `from`: the address's port, else where Remote Access runs or is incomplete;
  - `start`: the app's paths on 443 that 443 doesn't forward to it yet;
  - `off`: what it has on the old port, by path, or `--set-path /` for a whole-port entry;
  - `address`: the address without a port, for the app's address editor.
- Additive only.

## 0.4.0

Apps share Tailscale Funnel's **port 443 by path**. 0.3.0 gave a second app another public port, but claude.ai and ChatGPT only connect to 443 (anthropics/claude-ai-mcp#373).

- `RemotePaths` and `RemoteConfiguration.publicPaths`: the four paths Remote Access answers, one list for the gate, the OAuth server and the tunnel commands. They are the secret prefix, and the protected-resource, authorization-server and OpenID discovery documents with the secret prefix after their name. The gate now answers discovery only under those three names.
- `TailscaleFunnelCommand.start(port:publicPort:paths:)` adds one path entry per path, each forwarding to the same path. `off(publicPort:paths:)` removes them, always naming the path: a bare `tailscale funnel --https=443 off` turns off every app on the port. `off(_:address:paths:)` also turns off a whole-port `/` entry from before by path, and `resetPath` swaps the old secret's paths for the new ones.
- `FunnelPorts` reads path entries, and decides from the app's port and paths:
  - `running`: all paths, or a whole-port `/` from before;
  - `incomplete`, with the missing paths;
  - `publicPort`: 443 unless it has a tailnet-only entry, which Funnel would make public, or a raw TCP forwarder;
  - `reachesCloudAgents` and `pathsToAdd`.
- `ToolJSON.target` reads a forwarding target's port and path.
- Breaking:
  - `TunnelChecks.check`, `TunnelProbes.check`, `TailscaleStatus.parse` and `result` take the app's public paths.
  - New `TunnelHealth.incomplete(address:missing:)`.
  - `NotRunningReason.allPortsTaken` is now `noSharablePort`.
  - `TailscaleFunnelCommand`'s single-port `start(port:publicPort:)` and `off(port:publicPort:)` are gone.
  - `FunnelPorts.Entry` has `handlers` instead of `targets` (still available, computed) and `tcpForward`.

## 0.3.0

Several apps can now share Tailscale Funnel on one Mac. Funes Vault and EK Bridge both use it,
and each app's guide used to offer `tailscale funnel --bg <port>`, which takes port 443 and
replaces whatever another app serves there.

- `FunnelPorts` reads every entry of `tailscale funnel status --json`: Funnel, tailnet-only Serve
  and TCP forwarders, by public port. `publicPort` is where Remote Access already runs, else the
  first of 443, 8443 and 10000 with nothing served on it; `inTheWay` lists what it passed over.
- `TailscaleFunnelCommand` gives the start and off commands for a public port (443 keeps the
  short form) and the port in an address.
- Breaking:
  - `TunnelChecks.Done` receives a `TunnelCheckResult` (the health, plus `FunnelPorts` for
    Tailscale) instead of a `TunnelHealth`.
  - A Funnel entry that forwards to another local port is no longer `.wrongPort`: it belongs to
    another app. `.wrongPort` is now only for the ports an app names in `mistakenPorts`
    (`TunnelChecks.live(mistakenPorts:)`, `TailscaleStatus.parse(…mistakenPorts:)`), such as its
    local MCP port.
  - New `TunnelHealth.NotRunningReason.allPortsTaken`.
  - `TunnelSwitchSummary.make`'s `offCommands` also gets the address being left, so the off
    command targets its port.

## 0.2.0

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
