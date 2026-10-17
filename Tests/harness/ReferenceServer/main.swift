import BridgeKitCore
import Darwin
import Foundation

// bridgekit-reference-server: the real listener, gate, MCP server and key
// files, with a tiny app on top (status, echo and write_note tools, a fake
// approval panel and an in-memory activity log). Offline: loopback only.
//
// Environment: BRIDGEKIT_TEST_DIR (a private temp folder, required),
// BRIDGEKIT_TEST_PORT (default 0, any free port), BRIDGEKIT_TEST_CALL_TIMEOUT
// (seconds, default 55). Prints {"port":…,"agents":{name:{"id","key"}}} on
// stdout, then answers one JSON control command per stdin line, and exits
// when stdin closes.

let keyPrefix = "ref_mcp_v1_"

struct Agent {
    let id: String
    let name: String
    var digest: Data
    var paused = false
    var removed = false
    var canWrite: Bool
    var asks: Bool
}

struct ActivityRow {
    let command: String
    let outcome: String
    let agentID: String?
    let agent: String?
}

@MainActor
final class App {
    var agents = [String: Agent]()
    var on = true
    var approvalMode = "allow"
    var activity = [ActivityRow]()
    var connections = [String: MCPServer.Connection]()
    private var waiting = [(id: UUID, resume: (String) -> Void)]()

    var pendingCount: Int { waiting.count }

    func record(_ command: String, _ outcome: String, _ call: ToolCall?) {
        activity.insert(ActivityRow(command: command, outcome: outcome, agentID: call?.agent.id,
                                    agent: call?.agentName), at: 0)
    }

    /// Waits for `answer`, a cancellation, or (approval mode "timeout") nothing.
    func approve(_ call: ToolCall) async -> String {
        switch approvalMode {
        case "allow": return "allowed"
        case "deny": return "denied"
        case "timeout": return "timed_out"
        default: break
        }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            var resumed = false
            let resume: (String) -> Void = { decision in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: decision)
            }
            waiting.append((id, resume))
            call.context.onCancel { [weak self] in
                self?.waiting.removeAll { $0.id == id }
                resume("cancelled")
            }
        }
    }

    @discardableResult
    func answer(_ decision: String) -> Bool {
        guard !waiting.isEmpty else { return false }
        let first = waiting.removeFirst()
        first.resume(decision)
        return true
    }

    func withdrawAll() {
        while answer("withdrawn") {}
    }
}

final class Authenticator: AgentAuthenticator {
    let app: App

    init(app: App) { self.app = app }

    func authenticate(_ key: PresentedKey) async -> AuthenticationOutcome {
        await MainActor.run {
            let candidates = app.agents.values.filter { !$0.removed }.map { (id: $0.id, digest: $0.digest) }
            guard let id = AgentKey.firstMatch(key.digest, in: candidates), let agent = app.agents[id] else {
                return .rejected
            }
            return .authenticated(AuthenticatedAgent(id: agent.id, name: agent.name))
        }
    }
}

@MainActor
final class Registry: ToolRegistry {
    let contract: ToolContract
    let app: App

    init(app: App) {
        self.app = app
        guard let url = Bundle.module.url(forResource: "tools", withExtension: "json"),
              let data = try? Data(contentsOf: url), let contract = try? ToolContract(json: data) else {
            fatalError("tools.json is missing or invalid")
        }
        self.contract = contract
    }

    var serverInstructions: String { contract.serverInstructions }

    func tool(named name: String) -> ToolDefinition? { contract.tool(named: name) }

    func visibleTools(for agent: AuthenticatedAgent) -> [ToolDefinition] {
        let record = app.agents[agent.id]
        return contract.tools.filter { tool in
            switch tool.name {
            case "status": return true
            case "write_note": return record?.canWrite == true
            default: return record?.name != "none"
            }
        }
    }

    func failureResult(_ failure: ToolFailure, tool: String, arguments: [String: Any]?) -> ToolResult {
        switch failure {
        case .invalidArguments(let detail): Pipeline.error("Invalid arguments: \(detail).", code: "invalid_arguments")
        case .timeout: Pipeline.error("No answer in time. If this was a change, it may have happened.", code: "timeout")
        }
    }
}

/// The app's request pipeline: on/off, agent state, visibility, limits,
/// approval, then the tool, with an Activity row for each call.
final class Pipeline: BridgeHandler {
    let app: App
    let registry: Registry
    let limiter: RateLimiter

    init(app: App, registry: Registry, limiter: RateLimiter) {
        self.app = app
        self.registry = registry
        self.limiter = limiter
    }

    static func error(_ text: String, code: String) -> ToolResult {
        ToolResult(["content": [["type": "text", "text": "\(text) (code: \(code))"]], "isError": true])
    }

    static func success(_ structured: [String: Any]) -> ToolResult {
        let data = (try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys])) ?? Data()
        return ToolResult(["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
                           "structuredContent": structured, "isError": false])
    }

    func handle(_ call: ToolCall) async -> ToolResult {
        let (early, asks) = await MainActor.run { () -> (ToolResult?, Bool) in
            let refuse = { (code: String, text: String) -> (ToolResult?, Bool) in
                self.app.record(call.name, "error:" + code, call)
                return (Self.error(text, code: code), false)
            }
            guard app.on else { return refuse("bridge_off", "The reference server is off.") }
            guard let agent = app.agents[call.agent.id], !agent.removed else {
                return refuse("forbidden", "Not allowed.")
            }
            if agent.paused { return refuse("agent_paused", "This agent is paused.") }
            guard registry.visibleTools(for: call.agent).contains(where: { $0.name == call.name }) else {
                return refuse("forbidden", "Not allowed: this agent can't use \(call.name).")
            }
            let isWrite = registry.tool(named: call.name)?.isWrite ?? true
            if case .limited(let wait) = limiter.allow(call.agent.id, write: isWrite) {
                return refuse("rate_limited", "Too many requests. Wait \(wait) s.")
            }
            return (nil, isWrite && agent.asks)
        }
        if let early { return early }
        return await run(call, asks: asks)
    }

    private func run(_ call: ToolCall, asks: Bool) async -> ToolResult {
        switch call.name {
        case "status":
            return await MainActor.run {
                app.record(call.name, "success", call)
                return Self.success(["on": true])
            }
        case "echo":
            let text = call.arguments["text"] as? String ?? ""
            let delay = (call.arguments["delay_ms"] as? NSNumber)?.intValue ?? 0
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                if Task.isCancelled {
                    await MainActor.run { app.record(call.name, "error:cancelled", call) }
                    return Self.error("Cancelled.", code: "cancelled")
                }
            }
            return await MainActor.run {
                app.record(call.name, "success", call)
                return Self.success(["text": text])
            }
        default:
            let note = call.arguments["note"] as? String ?? ""
            if asks {
                let decision = await app.approve(call)
                guard decision == "allowed" else {
                    let code = ["denied": "approval_denied", "cancelled": "cancelled",
                                "timed_out": "approval_timed_out"][decision] ?? "scope_changed"
                    await MainActor.run { app.record(call.name, "error:" + code, call) }
                    return Self.error("Not written.", code: code)
                }
            }
            if note.hasPrefix("slow") {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled {
                    await MainActor.run { app.record(call.name, "error:cancelled", call) }
                    return Self.error("Cancelled.", code: "cancelled")
                }
            }
            return await MainActor.run {
                limiter.recordWrite(call.agent.id)
                app.record(call.name, "success", call)
                return Self.success(["written": note])
            }
        }
    }
}

@MainActor
final class Harness {
    let directory: URL
    let app = App()
    let limiter = RateLimiter()
    let counters = MCPTrafficCounters()
    let keyFiles: AgentKeyFiles
    let configuration: BridgeConfiguration
    let service: MCPService
    var lastPort = 0

    init(directory: URL, timeout: TimeInterval) {
        self.directory = directory
        keyFiles = AgentKeyFiles(store: SecretFileStore(parent: directory, folderName: "agent-keys"),
                                 keyPrefix: keyPrefix)
        configuration = BridgeConfiguration(
            identity: BridgeIdentity(displayName: "Reference Bridge", bundleID: "dev.bridgekit.reference",
                                     dataFolder: directory, version: "0.1.0"),
            mcpPort: 0, keyPrefix: keyPrefix, serverKey: "reference", launcherName: "reference-mcp",
            serverDescription: "BridgeKitCore's reference server.", agentMetaKey: "dev.bridgekit.reference/agent",
            toolCallTimeout: timeout, forwardedHeaderPrefixes: ["x-forwarded-", "forwarded", "cf-", "tailscale-"],
            texts: BridgeTexts(
                unavailable: "Reference Bridge can't read its agents.",
                unauthorized: "Reference Bridge doesn't recognize this agent's key.",
                tunnelRefused: "This port is only for agents on this Mac; tunnels aren't accepted."))
        let registry = Registry(app: app)
        let app = self.app
        let server = MCPServer(configuration: configuration, authenticator: Authenticator(app: app),
                               tools: registry, handler: Pipeline(app: app, registry: registry, limiter: limiter),
                               limiter: limiter, counters: counters,
                               didConnect: { id, connection in app.connections[id] = connection })
        service = MCPService(server: server, limiter: limiter, counters: counters,
                             endpointFile: MCPEndpointFile(directory: directory))
    }

    /// agent: reads and writes · full: the same · reader: no writes ·
    /// none: only status · ask: writes need approval.
    func makeAgents() -> [String: [String: String]] {
        var result = [String: [String: String]]()
        for (name, canWrite, asks) in [("agent", true, false), ("full", true, false), ("reader", false, false),
                                       ("none", false, false), ("ask", true, true)] {
            let id = UUID().uuidString.lowercased()
            let key = AgentKey.issue(prefix: keyPrefix)
            guard case .success = keyFiles.saveNew(agentID: id, key: key) else { fatalError("key file for \(name)") }
            app.agents[id] = Agent(id: id, name: name, digest: AgentKey.digest(key), canWrite: canWrite, asks: asks)
            result[name] = ["id": id, "key": key]
        }
        return result
    }

    func id(_ name: String?) -> String? { app.agents.values.first { $0.name == name }?.id }

    func control(_ command: [String: Any]) -> [String: Any] {
        let agent = id(command["agent"] as? String)
        switch command["cmd"] as? String {
        case "bridge":
            app.on = command["on"] as? Bool ?? true
            if !app.on { app.withdrawAll() }
            return ["ok": true]
        case "approval":
            app.approvalMode = command["mode"] as? String ?? "allow"
            return ["ok": true]
        case "answer":
            return ["ok": app.answer(command["decision"] as? String == "deny" ? "denied" : "allowed")]
        case "pending":
            return ["pending": app.pendingCount]
        case "activity":
            return ["activity": app.activity.map { row -> [String: Any] in
                var value: [String: Any] = ["command": row.command, "outcome": row.outcome,
                                            "agentID": row.agentID as Any? ?? NSNull()]
                if let agent = row.agent { value["agent"] = agent }
                return value
            }]
        case "pause":
            guard let agent else { return ["ok": false] }
            app.agents[agent]?.paused = command["on"] as? Bool ?? true
            return ["ok": true]
        case "revoke":
            guard let agent else { return ["ok": false] }
            app.agents[agent]?.removed = true
            _ = keyFiles.remove(agentID: agent)
            return ["ok": true]
        case "reset_key":
            guard let agent else { return ["ok": false] }
            let key = AgentKey.issue(prefix: keyPrefix)
            guard case .success = keyFiles.replace(agentID: agent, key: key) else { return ["ok": false] }
            app.agents[agent]?.digest = AgentKey.digest(key)
            return ["ok": true, "key": key]
        case "connection":
            guard let agent, let connection = app.connections[agent] else { return ["connection": NSNull()] }
            return ["connection": ["agent": connection.agent as Any? ?? NSNull()]]
        case "counters":
            let snapshot = counters.snapshot
            return ["requests": snapshot.requests, "authFailures": snapshot.authFailures,
                    "byStatus": Dictionary(uniqueKeysWithValues: snapshot.byStatus.map { (String($0), $1) })]
        case "stop":
            service.stop()
            return ["ok": true]
        case "start":
            service.start(port: command["port"] as? Int ?? lastPort)
            return ["ok": true]
        default:
            return ["error": "unknown command"]
        }
    }
}

enum Output {
    static func line(_ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

@MainActor
func startControl(_ harness: Harness) {
    let box = UncheckedHarness(harness)
    Thread.detachNewThread {
        while let line = readLine() {
            let command = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
            let sendable = UncheckedCommand(command)
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { Output.line(box.value.control(sendable.value)) }
            }
        }
        DispatchQueue.main.sync {
            MainActor.assumeIsolated { box.value.service.stop() }
        }
        exit(0)
    }
}

struct UncheckedHarness: @unchecked Sendable { let value: Harness; init(_ value: Harness) { self.value = value } }
struct UncheckedCommand: @unchecked Sendable { let value: [String: Any]; init(_ value: [String: Any]) { self.value = value } }

setvbuf(stdout, nil, _IONBF, 0)
let environment = ProcessInfo.processInfo.environment
guard let path = environment["BRIDGEKIT_TEST_DIR"] else {
    FileHandle.standardError.write(Data("BRIDGEKIT_TEST_DIR is required\n".utf8))
    exit(2)
}
MainActor.assumeIsolated {
    let timeout = TimeInterval(environment["BRIDGEKIT_TEST_CALL_TIMEOUT"] ?? "") ?? 55
    let harness = Harness(directory: URL(fileURLWithPath: path, isDirectory: true), timeout: timeout)
    let agents = harness.makeAgents()
    var announced = false
    harness.service.statusChanged = { status in
        switch status {
        case .listening(let port):
            harness.lastPort = port
            if !announced {
                announced = true
                Output.line(["port": port, "agents": agents])
                startControl(harness)
            }
        case .failed(let failure):
            if !announced {
                FileHandle.standardError.write(Data("listener failed: \(failure)\n".utf8))
                exit(1)
            }
        default: break
        }
    }
    harness.service.start(port: Int(environment["BRIDGEKIT_TEST_PORT"] ?? "0") ?? 0)
}
// The main run loop, not dispatchMain(): dispatchMain() drains the main
// queue off the main thread, which Swift 6's main-actor checks refuse.
let keepAlive = Timer(timeInterval: 86_400, repeats: true) { _ in }
RunLoop.main.add(keepAlive, forMode: .default)
while true { RunLoop.main.run() }
