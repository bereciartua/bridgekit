# BridgeKit

The protocol and security core shared by Mac apps that serve local MCP (Model
Context Protocol) servers to AI agents: [EK Bridge](https://github.com/bereciartua/ek-bridge)
and Funes Vault.

`BridgeKitCore` has:

- a loopback-only HTTP/1.1 server (`LoopbackHTTPServer`, strict parser, limits and deadlines);
- MCP over Streamable HTTP, stateless, in the 2026-07-28 era and the three legacy ones
  (`MCPServer`, `MCPService`, `MCPHTTPGate`: Host, Origin and tunnel-header checks);
- bearer keys (`AgentKey`: issue, SHA-256 digest, constant-time match) and private key files
  (`SecretFileStore`, `AgentKeyFiles`: 0600 files in a 0700 folder, `O_NOFOLLOW`, atomic);
- rate limits and a failed-authentication lockout (`RateLimiter`);
- argument validation against a tool contract (`ToolContract`, `JSONSchemaValidator`);
- the stdio launcher agents run (`BridgeLauncher`: relay, Claude Code `headers`, `check`,
  listener verification before a key is sent);
- one-click agent config writing (`AgentConfigWriter`, `SetupJSON`, `ExecutableLocator`).

It holds no domain types. An app plugs in through `BridgeConfiguration` (names, port, key
prefix, limits, wording), `AgentAuthenticator` (its own agent store), `ToolRegistry` (its tool
contract and visibility) and `BridgeHandler` (its request pipeline).

`BridgeKitRemote` (0.4.0) adds Remote Access for cloud agents, on top of the core:

- a second loopback listener for a tunnel the user runs (`RemoteMCPService`, `RemoteHTTPGate`:
  a 128-bit secret path, the `Host` allowlist, a per-address lockout, health nonces), handing
  authenticated calls to the same `MCPServer` with `remote: true`;
- an OAuth 2.1 authorization server for claude.ai, ChatGPT and Gemini Enterprise (`OAuthServer`:
  RFC 9728 and 8414 metadata, PKCE S256, a pairing window the user opens and approves with a
  six-digit code, rotating refresh tokens with reuse detection, dynamic registration and clients
  set up ahead), with its state in a 0600 file that fails closed;
- the client-metadata fetch (`CIMDFetcher`: https to public addresses only, no redirects or
  proxies, 16 KB, 5 s);
- read-only tunnel checks (`TunnelChecks`, `TunnelHealth`: Tailscale Funnel, Cloudflare Tunnel,
  ngrok, quick tunnels), the Switch Tunnel state (`TunnelSwitch`), the reachability test
  (`RemoteProbe`) and `KeepAwake`;
- Tailscale Funnel's port 443 shared by several apps on one Mac (`RemotePaths`, `FunnelPorts`,
  `TailscaleFunnelCommand`): each adds only its own paths (`RemoteConfiguration.publicPaths`),
  so no app replaces another's entry, and claude.ai and ChatGPT, which only connect to 443,
  reach all of them.

An app plugs in through `RemoteBridgeConfiguration` (port, token prefixes, scope, `User-Agent`,
store folder, `RemoteTexts`) and `RemoteAuthenticator` (which agent a remote credential belongs
to, and whether it may be used from the internet). Tunnel results are typed; each app words them.

macOS 14 or later, Swift 6, no dependencies. Apache-2.0.

## Use

```swift
.package(url: "https://github.com/bereciartua/bridgekit", exact: "0.4.0")
```

Apps pin an exact version. Breaking changes bump the minor version while in 0.x.

## Test

```bash
sh scripts/test.sh
```

Runs the Swift Testing suites, then the reference harness in `Tests/harness`: a small server
with an echo tool and a write tool behind a fake approval panel, and its Remote Access listener
with a fake sign-in approver, driven by `mcp_test.py`, `remote_test.py` and `launcher_test.py`
over real loopback sockets.

## Linking without SwiftPM

An app built with plain `swiftc` (EK Bridge's `build.sh`) links the static library:

```bash
swift build -c release --product BridgeKitCore --arch arm64 --arch x86_64
swift build -c release --product BridgeKitRemote --arch arm64 --arch x86_64
```

This leaves universal `libBridgeKitCore.a` and `libBridgeKitRemote.a`, with their
`.swiftmodule`s, in `.build/out/Products/Release`; pass that folder to `swiftc` with `-I` and
`-L`, and add `-lBridgeKitCore -lBridgeKitRemote`.

## Provenance

The code was moved from EK Bridge; [PROVENANCE.md](PROVENANCE.md) lists the source commit of
every file.
