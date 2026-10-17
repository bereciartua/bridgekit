import Foundation

/// Everything app-specific about the stdio launcher.
public struct LauncherConfiguration: Sendable {
    /// "bridge-mcp" · "funes-mcp": the log prefix and the name in messages.
    public var launcherName: String
    public var displayName: String
    /// The key shape the launcher accepts from a key file (same as the server's).
    public var keyPrefix: String
    /// The app's data folder; the endpoint file and key folder are inside it.
    public var supportDirectory: @Sendable () -> String
    /// "client-credentials" · "agent-keys".
    public var keyFolderName: String
    public var keyFileSuffix: String
    /// The option naming the agent by id: "client" (`--client ID`) · "agent".
    public var agentOption: String
    /// The `_meta` key `server/discover` names the agent under.
    public var agentMetaKey: String
    /// The tool `check` calls to learn whether the app is on.
    public var probe: LauncherProbe?
    /// Set only in test builds: the server is a plain harness binary.
    public var testMode: LauncherTestMode?
    public var texts: LauncherTexts

    public init(launcherName: String, displayName: String, keyPrefix: String,
                supportDirectory: @escaping @Sendable () -> String, keyFolderName: String,
                keyFileSuffix: String = SecretFileKind.mcpKey.fileSuffix, agentOption: String,
                agentMetaKey: String, probe: LauncherProbe? = nil, testMode: LauncherTestMode? = nil,
                texts: LauncherTexts) {
        self.launcherName = launcherName
        self.displayName = displayName
        self.keyPrefix = keyPrefix
        self.supportDirectory = supportDirectory
        self.keyFolderName = keyFolderName
        self.keyFileSuffix = keyFileSuffix
        self.agentOption = agentOption
        self.agentMetaKey = agentMetaKey
        self.probe = probe
        self.testMode = testMode
        self.texts = texts
    }
}

/// `check` calls this read-only tool and asks the app what the result means.
public struct LauncherProbe: Sendable {
    public enum Verdict: Sendable, Equatable {
        case on
        case warning(String)
    }

    public var tool: String
    /// Gets the `tools/call` result object.
    public var interpret: @Sendable ([String: Any]) -> Verdict

    public init(tool: String, interpret: @escaping @Sendable ([String: Any]) -> Verdict) {
        self.tool = tool
        self.interpret = interpret
    }
}

/// Test builds stand a plain harness binary in for the app bundle: the
/// listener check compares the endpoint's process to this path instead of
/// the enclosing app's bundle ID. uid and socket checks stay real.
public struct LauncherTestMode: Sendable {
    /// The environment variable holding the harness binary's path.
    public var serverPathVariable: String

    public init(serverPathVariable: String) {
        self.serverPathVariable = serverPathVariable
    }
}

/// The launcher's app-specific words.
public struct LauncherTexts: Sendable {
    /// `--help`.
    public var help: String
    /// `--<agentOption>` got something other than a UUID.
    public var agentIDNotUUID: String
    /// Another process holds the app's port.
    public var squatter: String
    /// The JSON-RPC error after a 401.
    public var rejected: String
    /// The stderr line after a 401.
    public var rejectedLog: String
    /// `headers`: the agent's URL isn't the one the app serves (agent's URL, served URL).
    public var urlMismatch: @Sendable (String, String) -> String
    /// "client" · "agent", in `check`'s lines.
    public var agentNoun: String
    /// `check`: the agent sees no tools.
    public var noTools: String
    /// `check`: the key was refused.
    public var checkRejected: String

    public init(help: String, agentIDNotUUID: String, squatter: String, rejected: String, rejectedLog: String,
                urlMismatch: @escaping @Sendable (String, String) -> String, agentNoun: String, noTools: String,
                checkRejected: String) {
        self.help = help
        self.agentIDNotUUID = agentIDNotUUID
        self.squatter = squatter
        self.rejected = rejected
        self.rejectedLog = rejectedLog
        self.urlMismatch = urlMismatch
        self.agentNoun = agentNoun
        self.noTools = noTools
        self.checkRejected = checkRejected
    }
}

/// The configuration of this process's launcher, set once by `BridgeLauncher.run`.
enum Launcher {
    nonisolated(unsafe) static var config: LauncherConfiguration!
}
