import BridgeKitCore
import Foundation

// bridgekit-reference-launcher: BridgeKitCore's launcher, configured for the
// reference server. Test-only: the support folder comes from
// BRIDGEKIT_TEST_SUPPORT_DIR and the server is the harness binary named by
// BRIDGEKIT_TEST_SERVER_PATH, so nothing touches a real app.

let app = "Reference Bridge"
let launcher = "reference-mcp"

BridgeLauncher.run(LauncherConfiguration(
    launcherName: launcher,
    displayName: app,
    keyPrefix: "ref_mcp_v1_",
    supportDirectory: {
        ProcessInfo.processInfo.environment["BRIDGEKIT_TEST_SUPPORT_DIR"] ?? "/var/empty/bridgekit-test-support"
    },
    keyFolderName: "agent-keys",
    agentOption: "agent",
    agentMetaKey: "dev.bridgekit.reference/agent",
    probe: LauncherProbe(tool: "status") { result in
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        guard result["isError"] as? Bool == true else { return .on }
        if text.contains("(code: bridge_off)") {
            return .warning("\(app) is off: tool calls will be refused until it's turned on")
        }
        if text.contains("(code: agent_paused)") {
            return .warning("this agent is paused: tool calls will be refused until it's resumed in \(app)")
        }
        return .warning("status failed: \(text)")
    },
    testMode: LauncherTestMode(serverPathVariable: "BRIDGEKIT_TEST_SERVER_PATH"),
    texts: LauncherTexts(
        help: """
            Usage: \(launcher) --agent ID                      stdio MCP relay
                   \(launcher) --token-file PATH               stdio relay, explicit key file
                   \(launcher) headers --agent ID --url URL    for Claude Code's headersHelper
                   \(launcher) check --agent ID                diagnose a setup
                   \(launcher) --help | --version

            Connects an agent on this Mac to \(app)'s MCP server.

            """,
        agentIDNotUUID: "--agent takes the agent's ID (a UUID), not its name. "
            + "Copy the setup from the agent's page in \(app).",
        squatter: "Another program is using \(app)'s port. Open \(app) and check its settings.",
        rejected: "\(app) doesn't recognize this agent's key. Open the agent in \(app) and check its access.",
        rejectedLog: "the token was rejected. Open the agent in \(app) and check its access.",
        urlMismatch: { target, served in
            "the agent's URL \(target) isn't the one \(app) serves (\(served)). "
                + "Copy the setup again from the agent's page."
        },
        agentNoun: "agent",
        noTools: "no tools available: grant this agent access in \(app)",
        checkRejected: "token rejected: open the agent in \(app) and check its access")))
