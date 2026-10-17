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
