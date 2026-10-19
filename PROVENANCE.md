# Provenance

Every file in `Sources/BridgeKitCore` was moved from EK Bridge
(`bereciartua/ek-bridge`), version 0.11.1, commit
`9c726f2c903a190d5303c28c1c6e7464544905fa`. The first commit in this repository
(`Import tier-1 files verbatim`) holds the unmodified copies, so `git diff` from
it shows every change made while generalizing.

| BridgeKitCore file | EK Bridge source (9c726f2) | Changes |
|---|---|---|
| `HTTP/HTTPMessage.swift` | `Sources/MCP/HTTPMessage.swift` | Public API, memberwise `HTTPLimits` init |
| `HTTP/LoopbackHTTPServer.swift` | `Sources/MCP/LoopbackHTTPServer.swift` | Limits and connection cap as parameters; state reported on the server's queue |
| `MCP/JSONRPC.swift` | `Sources/MCP/JSONRPC.swift` | Public API |
| `MCP/MCPEndpointFile.swift` | `Sources/MCP/MCPEndpointFile.swift` | Public API |
| `MCP/MCPServer.swift` | `Sources/MCP/MCPServer.swift` | `MCPHTTPGate` reads its texts, origins and tunnel headers from `BridgeConfiguration`; tools from `ToolRegistry`; calls go to `BridgeHandler` (async) instead of `RequestPipeline`; authentication through `AgentAuthenticator` |
| `MCP/MCPService.swift` | `Sources/MCP/MCPService.swift` | Configuration-driven; `Task { @MainActor }` hops |
| `MCP/JSONSchemaValidator.swift` | `Sources/MCP/MCPToolCatalog.swift` (argument validation) | Extracted, unchanged rules |
| `MCP/ToolContract.swift` | `Sources/MCP/MCPToolCatalog.swift` (`$defs` inlining, contract loading) | Extracted; drops `$comment` keys |
| `MCP/Seams.swift` | `Sources/ClientRegistry.swift` (token issue, digest, constant-time compare, `sanitizedAgent`) | New seam types; `AgentKey`, `AgentName` |
| `Limits/RateLimiter.swift` | `Sources/MCP/RateLimiter.swift` | Public API |
| `Files/SafePath.swift` | `Sources/SafePath.swift` | Public API |
| `Keys/SecretFiles.swift` | `Sources/ClientCredentialFiles.swift` | Generic `SecretFileStore` and `SecretFileKind`; `AgentKeyFiles` for MCP keys |
| `Launcher/BridgeLauncher.swift` | `Sources/MCPLauncher.swift` | Names, paths, key prefix, option name, texts, probe tool and test mode come from `LauncherConfiguration` |
| `Launcher/LauncherConfiguration.swift` | — | New |
| `Setup/AgentConfigWriter.swift` | `Sources/AgentConfigWriter.swift` | Backup tag as a parameter; error messages take the app's name |
| `Setup/SetupJSON.swift` | `Sources/AgentSetup.swift` (`SetupJSON`, `SetupTOML`) | Public API |
| `Setup/ExecutableLocator.swift` | `Sources/ExecutableLocator.swift` | Public API |

Tests:

| BridgeKit test | EK Bridge source (9c726f2) |
|---|---|
| `Tests/BridgeKitCoreTests/*` | `Tests/HTTPMessageTests.swift`, `RateLimiterTests.swift`, `ClientCredentialFilesTests.swift`, `AgentConfigWriterTests.swift`, `MCPGateTests.swift` (gate, JSON-RPC, listener), `MCPToolCatalogTests.swift` (validator), converted to Swift Testing |
| `Tests/harness/mcp_test.py` | `Tests/mcp_test.py`, protocol checks only |
| `Tests/harness/launcher_test.py` | `Tests/launcher_test.py` |

Not moved (each store in EK Bridge keeps its own copy for now): the inline private-file read
and write helpers in `ActivityStore`, `ClientRegistry`, `WriteJournal` and `LocalBridge`.
`SafePath` covers new code.

## BridgeKitRemote (0.2.0)

Every file in `Sources/BridgeKitRemote` was moved from EK Bridge at commit
`e753b221a6646e6420eb2fe382780bea88493841` (0.11.2 plus BridgeKit 0.1.1). The commit
`Import tier-3 files verbatim from EK Bridge e753b22` holds the unmodified copies, so
`git diff 7693429 -- Sources/BridgeKitRemote Tests/BridgeKitRemoteTests` shows every change.

| BridgeKitRemote file | EK Bridge source (e753b22) | Changes |
|---|---|---|
| `Remote/RemoteMCPService.swift` | `Sources/MCP/RemoteMCPService.swift` | Public API; authenticates through `RemoteAuthenticator` instead of `ClientRegistry`; prefixes, 401 wording and realm from `RemoteBridgeConfiguration`; the gate's tunnel is a `TunnelProvider`; HTTP limits from the core's configuration; `Task` hops to the main actor |
| `Remote/RemoteSeams.swift` | — | New: `RemoteBridgeConfiguration`, `RemoteTexts`, `RemoteAuthenticator` |
| `Remote/RemoteAccessSupport.swift` | `Sources/RemoteAccessSupport.swift` | `KeepAwake(reason:)`; `RemoteProbe` returns `RemoteProbeResult` or `RemoteProbeFailure` instead of localized strings |
| `OAuth/OAuthServer.swift` | `Sources/MCP/OAuthServer.swift` | Scope and token prefixes are instance values from the configuration; page and error wording from `RemoteTexts`; `agentAllowed`/`agentName` (or a `RemoteAuthenticator`) instead of `clientAllowed`/`clientName`; the default timer uses `Task.sleep` |
| `OAuth/OAuthStore.swift` | `Sources/MCP/OAuthStore.swift` | None (same file format) |
| `OAuth/OAuthPages.swift` | `Sources/MCP/OAuthPages.swift` | A value holding the app's name and `RemoteTexts` |
| `OAuth/OAuthTypes.swift` | `Sources/MCP/OAuthTypes.swift` | Public API |
| `OAuth/CIMDFetcher.swift` | `Sources/MCP/CIMDFetcher.swift` | `User-Agent` from the app; `CIMDFetcher.Testing` instead of `#if EVENTKIT_MCP_TEST` hooks |
| `Tunnels/TunnelProvider.swift` | `Sources/AgentSetup.swift` (`TunnelProvider`) and `Sources/TunnelHealth.swift` (`detect(address:)`, `installLink`, `asksForHostname`, `hostname`) | Detection and wire names only; names, summaries, steps, notes and commands stay in the app |
| `Tunnels/TunnelHealth.swift` | `Sources/TunnelHealth.swift` | Without `label`, `detail` and `unreachableReason` (the app words them) |
| `Tunnels/TunnelChecks.swift` | `Sources/TunnelChecks.swift` | `Sendable` checks; results on the main actor |
| `Tunnels/TunnelSwitch.swift` | `Sources/TunnelSwitch.swift` | Without step titles and `inSentence`; `TunnelSwitchSummary.make` takes the app's off commands; `TunnelAddressMemory` takes an optional key |

Tests:

| BridgeKit test | EK Bridge source (e753b22) |
|---|---|
| `Tests/BridgeKitRemoteTests/*` | `Tests/OAuthServerTests.swift`, `CIMDFetcherTests.swift`, `TunnelHealthTests.swift` (with `Tests/tunnel-health`), `TunnelSwitchTests.swift`, the Remote Access candidate checks of `MCPGateTests.swift`, converted to Swift Testing. Assertions on wording that stayed in EK Bridge stay in EK Bridge's tests |
| `Tests/harness/remote_test.py` | `Tests/mcp_test.py` `run_remote` and `run_oauth`, against the reference server |
