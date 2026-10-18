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

macOS 14 or later, Swift 6, no dependencies. Apache-2.0.

## Use

```swift
.package(url: "https://github.com/bereciartua/bridgekit", exact: "0.1.1")
```

Apps pin an exact version. Breaking changes bump the minor version while in 0.x.

## Test

```bash
sh scripts/test.sh
```

Runs the Swift Testing suites, then the reference harness in `Tests/harness`: a small server
with an echo tool and a write tool behind a fake approval panel, driven by `mcp_test.py` and
`launcher_test.py` over real loopback sockets.

## Linking without SwiftPM

An app built with plain `swiftc` (EK Bridge's `build.sh`) links the static library:

```bash
swift build -c release --product BridgeKitCore --arch arm64 --arch x86_64
```

This leaves a universal `libBridgeKitCore.a` and `BridgeKitCore.swiftmodule` in
`.build/out/Products/Release`; pass that folder to `swiftc` with `-I` and `-L`, and add
`-lBridgeKitCore`.

## Provenance

The code was moved from EK Bridge; [PROVENANCE.md](PROVENANCE.md) lists the source commit of
every file.
