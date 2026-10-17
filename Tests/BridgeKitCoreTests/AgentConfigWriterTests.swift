import Foundation
import Testing
@testable import BridgeKitCore

// One-click agent setup: the JSON merge keeps every other key and the user's
// formatting (goldens in fixtures/agent-config; UPDATE_GOLDENS=1 rewrites the
// source copies), refuses what it can't read, never writes a key, and `apply`
// backs up, writes atomically and refuses a file that changed. Also
// ExecutableLocator with a fake file system. The entries are EK Bridge's.
@Suite("Agent config writer")
struct AgentConfigWriterTests {
    static let key = "ek-bridge"
    static let launcherPath = "/Applications/EKBridge.app/Contents/MacOS/bridge-mcp"
    static let clientID = "3f2a9c1e-7b4d-4e8a-9c21-5d6f0a1b2c3d"
    static let stdio: [(String, SetupJSON)] = [
        ("command", .string(launcherPath)), ("args", .strings(["--client", clientID])),
    ]
    /// Claude Desktop's entry.
    static let desktop = SetupJSON.object(stdio)
    /// Cursor's entry.
    static let cursor = SetupJSON.object([("type", .string("stdio"))] + stdio)
    /// Gemini CLI's entry, with its timeout.
    static let gemini = SetupJSON.object(stdio + [("timeout", .number(60000))])
    /// Codex's config.toml table.
    static let table = SetupTOML.table(key, stdio)
    static let appName = "EK Bridge"

    // MARK: JSON merge goldens

    struct Merge: Sendable, CustomTestStringConvertible {
        let name: String
        let input: String?
        var entry = AgentConfigWriterTests.desktop
        let outcome: ConfigChange.Outcome
        var testDescription: String { name }
    }

    static let merges: [Merge] = [
        Merge(name: "missing-file", input: nil, outcome: .created),
        Merge(name: "empty-file", input: "", outcome: .added),
        Merge(name: "empty-object", input: "{}\n", outcome: .added),
        Merge(name: "pretty-sorted", input: """
            {
              "globalShortcut": "",
              "mcpServers": {
                "filesystem": {
                  "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/tester/Desktop"],
                  "command": "npx"
                }
              }
            }

            """, outcome: .added),
        Merge(name: "compact",
              input: #"{"mcpServers":{"filesystem":{"command":"npx","args":["-y","x"]}},"theme":"dark"}"#,
              outcome: .added),
        Merge(name: "unsorted-tabs",
              input: "{\n\t\"zeta\": 1,\n\t\"mcpServers\": {\n\t\t\"b\": {\"command\": \"b\"},\n\t\t\"a\": {\"command\": \"a\"}\n\t},\n\t\"alpha\": [1, 2]\n}\n",
              entry: cursor, outcome: .added),
        Merge(name: "no-servers-key", input: "{\n    \"preferences\": {\"quickEntry\": true}\n}\n", outcome: .added),
        Merge(name: "empty-servers", input: "{\n  \"mcpServers\": {}\n}\n", entry: cursor, outcome: .added),
        Merge(name: "unicode-and-slashes",
              input: "{\n  \"note\": \"caf\\u00e9 · ünïcode · https:\\/\\/example.com/path\",\n  \"mcpServers\": {\n    \"x\": {\"url\": \"https:\\/\\/a.example\"}\n  }\n}\n",
              outcome: .added),
        Merge(name: "replace-different", input: """
            {
              "mcpServers": {
                "ek-bridge": {
                  "command": "/Users/tester/Downloads/EKBridge.app/Contents/MacOS/bridge-mcp",
                  "args": ["--client", "old"]
                },
                "other": {"command": "x"}
              }
            }

            """, outcome: .replaced),
    ]

    @Test("merges keep every key and the file's formatting", arguments: merges)
    func merge(_ merge: Merge) throws {
        let result = try AgentConfigWriter.merge(current: merge.input.map { Data($0.utf8) }, key: Self.key,
                                                 entry: merge.entry)
        #expect(result.outcome == merge.outcome)
        let text = String(decoding: result.after, as: UTF8.self)
        #expect(!text.contains("ekb_mcp_v1_"), "holds no key")
        try golden(merge.name, text)
    }

    @Test("an identical entry is unchanged, byte for byte")
    func identical() throws {
        let identical = "{\n  \"mcpServers\": {\"ek-bridge\": \(Self.desktop.text)}\n}\n"
        let same = try AgentConfigWriter.merge(current: Data(identical.utf8), key: Self.key, entry: Self.desktop)
        #expect(same.outcome == .unchanged)
        #expect(same.after == Data(identical.utf8))
    }

    @Test func refusals() {
        func refuses(_ input: String, _ expected: (ConfigWriteError) -> Bool, _ name: String) {
            do {
                _ = try AgentConfigWriter.merge(current: Data(input.utf8), key: Self.key, entry: Self.desktop)
                Issue.record("\(name) should be refused")
            } catch let error as ConfigWriteError {
                #expect(expected(error), "\(name): \(error)")
                #expect(!error.message(appName: Self.appName).isEmpty)
            } catch {
                Issue.record("\(name): \(error)")
            }
        }
        refuses("{\"mcpServers\": {,}", { if case .invalidJSON = $0 { true } else { false } }, "invalid JSON")
        refuses("// comment\n{}", { if case .invalidJSON = $0 { true } else { false } }, "comments")
        refuses("[1, 2]", { $0 == .notAnObject }, "top-level array")
        refuses("\"text\"", { if case .invalidJSON = $0 { true } else { $0 == .notAnObject } }, "fragment")
        refuses("{\"mcpServers\": [1]}", { $0 == .rootNotAnObject("mcpServers") }, "servers not an object")
        refuses("{\"a\": \"" + String(repeating: "x", count: 1_000_001) + "\"}", { $0 == .tooLarge }, "over 1 MB")
    }

    @Test("error messages name the app")
    func messages() {
        let errors: [ConfigWriteError] = [
            .invalidJSON("x"), .notAnObject, .rootNotAnObject("mcpServers"), .tooLarge, .unreadable,
            .unwritable("disk full"), .changedSinceReading, .verificationFailed, .existingEntry("ek-bridge"),
            .inlineTable("mcp_servers"), .notText,
        ]
        for error in errors {
            let message = error.message(appName: Self.appName)
            #expect(!message.isEmpty, "\(error)")
        }
        #expect(ConfigWriteError.notAnObject.message(appName: "Funes")
                == "The file doesn't hold a JSON object, so Funes won't change it.")
        #expect(ConfigWriteError.verificationFailed.message(appName: Self.appName).hasPrefix("EK Bridge couldn't"))
        #expect(ConfigWriteError.invalidJSON("bad").message(appName: Self.appName)
                == "The file isn't valid JSON (bad), so EK Bridge won't change it.")
    }

    @Test("diff lines: the added entry, with context")
    func diff() throws {
        let before = Data("{\n  \"a\": 1\n}\n".utf8)
        let after = try AgentConfigWriter.merge(current: before, key: Self.key, entry: Self.desktop).after
        let lines = AgentConfigWriter.diff(before, after)
        #expect(lines.contains { $0.kind == .added && $0.text.contains("\"ek-bridge\"") })
        #expect(lines.contains { $0.kind == .removed && $0.text == "  \"a\": 1" })
        #expect(lines.first?.kind == .context)
        #expect(!lines.contains { $0.text.contains("ekb_mcp_v1_") })
    }

    // MARK: Codex TOML and Gemini CLI

    @Test("Codex TOML appends and refusals, Gemini CLI merge")
    func codexAndGemini() throws {
        let key = Self.key, table = Self.table
        #expect(table == "[mcp_servers.ek-bridge]\ncommand = \"\(Self.launcherPath)\"\n"
                + "args = [\"--client\", \"\(Self.clientID)\"]")
        func toml(_ input: String?) throws -> (String, ConfigChange.Outcome) {
            let result = try AgentConfigWriter.appendTOML(current: input.map { Data($0.utf8) }, key: key, table: table)
            let text = String(decoding: result.after, as: UTF8.self)
            #expect(!text.contains("ekb_mcp_v1_"), "never a key")
            return (text, result.outcome)
        }
        func refused(_ input: String, _ expected: ConfigWriteError) {
            do {
                _ = try toml(input)
                Issue.record("should be refused: \(input)")
            } catch let error as ConfigWriteError {
                #expect(error == expected)
            } catch {
                Issue.record("\(error)")
            }
        }
        // A missing file is created with the table.
        let (created, createdOutcome) = try toml(nil)
        #expect(createdOutcome == .created && created == table + "\n")
        // Appended after everything else, which is kept byte for byte.
        let existing = "# my settings\nmodel = \"gpt-5-codex\"\n\n[mcp_servers.other]\ncommand = \"x\"   # keep\n"
        let (added, addedOutcome) = try toml(existing)
        #expect(addedOutcome == .added && added == existing + "\n" + table + "\n")
        // No trailing newline: one is added first.
        let (noNewline, _) = try toml("model = \"o3\"")
        #expect(noNewline == "model = \"o3\"\n\n" + table + "\n")
        // The same table already there (spacing and quotes aside): unchanged.
        let quoted = table.replacingOccurrences(of: "[mcp_servers.ek-bridge]", with: "[ mcp_servers.\"ek-bridge\" ]")
        let (same, sameOutcome) = try toml("model = \"o3\"\n\n" + quoted + "\n\n[profiles.x]\nmodel = \"o3\"\n")
        #expect(sameOutcome == .unchanged && same.hasPrefix("model"))
        // Anything else that defines it is refused, never rewritten.
        refused("[mcp_servers.ek-bridge]\ncommand = \"/somewhere/else\"\n", .existingEntry("ek-bridge"))
        refused("[mcp_servers]\nek-bridge = { command = \"x\" }\n", .existingEntry("ek-bridge"))
        refused("mcp_servers.ek-bridge.command = \"x\"\n", .existingEntry("ek-bridge"))
        refused("[mcp_servers.ek-bridge.env]\nA = \"1\"\n", .existingEntry("ek-bridge"))
        refused("mcp_servers = { other = { command = \"x\" } }\n", .inlineTable("mcp_servers"))
        #expect(throws: ConfigWriteError.notText) {
            try AgentConfigWriter.appendTOML(current: Data([0xff, 0xfe, 0x00]), key: key, table: table)
        }
        // Comments mentioning it don't count.
        let (commented, commentedOutcome) = try toml("# [mcp_servers.ek-bridge] was here\n")
        #expect(commentedOutcome == .added && commented.hasSuffix(table + "\n"))
        // Gemini CLI: the JSON merge, with its timeout, next to other settings.
        let geminiMerged = try AgentConfigWriter.merge(
            current: Data(#"{"theme": "Default", "mcpServers": {"other": {"command": "x"}}}"#.utf8), key: key,
            entry: Self.gemini)
        let geminiText = String(decoding: geminiMerged.after, as: UTF8.self)
        #expect(geminiMerged.outcome == .added)
        #expect(geminiText.contains("\"timeout\":60000"))
        #expect(geminiText.contains("\"theme\": \"Default\""))
        #expect(!geminiText.contains("ekb_mcp_v1_"))
        try golden("codex-config-appended", added)  // TOML text, in the suite's .json golden file
    }

    @Test("TOML table names: bare keys stay bare, others are quoted")
    func tomlNames() {
        #expect(SetupTOML.table("funes", [("command", .string("/x"))]) == "[mcp_servers.funes]\ncommand = \"/x\"")
        #expect(SetupTOML.table("my app", [("args", .strings(["a", "b\"c"]))])
                == "[mcp_servers.\"my app\"]\nargs = [\"a\", \"b\\\"c\"]")
    }

    // MARK: Apply

    @Test("backups, atomic writes, changed-file refusal and symlinks")
    func apply() throws {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("agent-config-tests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }
        let key = Self.key, entry = Self.desktop

        // A new file in a new folder: the folder is private, no backup.
        let fresh = folder.appendingPathComponent("Claude/claude_desktop_config.json")
        let created = try AgentConfigWriter.preview(fileURL: fresh, key: key, entry: entry)
        #expect(created.outcome == .created && created.before == nil)
        let createdBackup = try AgentConfigWriter.apply(created, tag: "ekbridge", backupSuffix: "20261008-120000")
        #expect(createdBackup == nil)
        #expect(fileManager.contents(atPath: fresh.path) == created.after)
        let folderMode = try fileManager.attributesOfItem(atPath: fresh.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(folderMode == 0o700)

        // An existing file keeps its permissions and gets a private backup.
        let existing = folder.appendingPathComponent("mcp.json")
        let original = Data("{\n  \"mcpServers\": {\"x\": {\"command\": \"x\"}}\n}\n".utf8)
        fileManager.createFile(atPath: existing.path, contents: original, attributes: [.posixPermissions: 0o644])
        let change = try AgentConfigWriter.preview(fileURL: existing, key: key, entry: entry)
        let backup = try #require(try AgentConfigWriter.apply(change, tag: "ekbridge", backupSuffix: "20261008-120000"),
                                  "backup expected")
        #expect(backup.lastPathComponent == "mcp.json.ekbridge-backup-20261008-120000")
        #expect(fileManager.contents(atPath: backup.path) == original)
        let backupMode = try fileManager.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int
        #expect(backupMode == 0o600)
        #expect(fileManager.contents(atPath: existing.path) == change.after)
        let fileMode = try fileManager.attributesOfItem(atPath: existing.path)[.posixPermissions] as? Int
        #expect(fileMode == 0o644)
        let leftovers = try fileManager.contentsOfDirectory(atPath: folder.path)
            .filter { $0.contains(".ekbridge-") && !$0.contains("backup") }
        #expect(leftovers.isEmpty, "no temporary files left")
        // Applying again is "already set up": nothing written.
        let again = try AgentConfigWriter.preview(fileURL: existing, key: key, entry: entry)
        let againBackup = try AgentConfigWriter.apply(again, tag: "ekbridge", backupSuffix: "x")
        #expect(again.outcome == .unchanged && againBackup == nil)

        // The file changed between preview and Add: nothing is written.
        let racing = folder.appendingPathComponent("racing.json")
        fileManager.createFile(atPath: racing.path, contents: Data("{}".utf8))
        let stale = try AgentConfigWriter.preview(fileURL: racing, key: key, entry: entry)
        fileManager.createFile(atPath: racing.path, contents: Data("{\"edited\": true}".utf8))
        #expect(throws: ConfigWriteError.changedSinceReading) {
            try AgentConfigWriter.apply(stale, tag: "ekbridge", backupSuffix: "x")
        }
        #expect(fileManager.contents(atPath: racing.path) == Data("{\"edited\": true}".utf8))
        #expect(!fileManager.fileExists(atPath: racing.path + ".ekbridge-backup-x"))

        // A symbolic link (dotfiles) is followed: the link stays, its target changes.
        let target = folder.appendingPathComponent("dotfiles-mcp.json")
        fileManager.createFile(atPath: target.path, contents: Data("{}\n".utf8))
        let link = folder.appendingPathComponent("linked.json")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        let linked = try AgentConfigWriter.preview(fileURL: link, key: key, entry: entry)
        try AgentConfigWriter.apply(linked, tag: "ekbridge", backupSuffix: "y")
        #expect((try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil, "the link stays a link")
        #expect(fileManager.contents(atPath: target.path) == linked.after)
        #expect(AgentConfigWriter.backupSuffix(Date(timeIntervalSince1970: 1_791_475_330),
                                               timeZone: try #require(TimeZone(identifier: "UTC"))) == "20261008-160210")
    }

    // MARK: Executable locator

    /// The fake file system and login shell the locator sees.
    final class FakeSystem: @unchecked Sendable {
        private let lock = NSLock()
        private var _files: Set<String> = []
        private var _shell: String?

        var files: Set<String> {
            get { lock.withLock { _files } }
            set { lock.withLock { _files = newValue } }
        }

        var shell: String? {
            get { lock.withLock { _shell } }
            set { lock.withLock { _shell = newValue } }
        }
    }

    @Test("the executable locator")
    func locator() {
        let home = "/Users/tester"
        let system = FakeSystem()
        let locator = ExecutableLocator(isExecutable: { system.files.contains($0) },
                                        loginShellLookup: { _ in system.shell })
        #expect(locator.locate("claude", home: home) == nil)
        system.files = ["/opt/homebrew/bin/claude", home + "/.claude/local/claude"]
        #expect(locator.locate("claude", home: home) == home + "/.claude/local/claude", "the native install first")
        system.files = ["/opt/homebrew/bin/claude"]
        #expect(locator.locate("claude", home: home) == "/opt/homebrew/bin/claude")
        system.files = ["/Users/tester/.nvm/versions/node/v22/bin/claude"]
        system.shell = "/Users/tester/.nvm/versions/node/v22/bin/claude\n"
        #expect(locator.locate("claude", home: home) == "/Users/tester/.nvm/versions/node/v22/bin/claude")
        system.shell = "claude: aliased to something"
        #expect(locator.locate("claude", home: home) == nil, "only absolute paths")
        system.shell = "/missing/claude"
        #expect(locator.locate("claude", home: home) == nil, "only files that exist and run")
        #expect(!ExecutableLocator.candidates("codex", home: home).contains(home + "/.claude/local/codex"))
    }

    @Test("the process runner: an argument array, output and exit code, and the timeout")
    func processRunner() {
        let echo = ProcessRunner.run("/bin/echo", ["a b", "c"], timeout: 5)
        #expect(echo?.exitCode == 0)
        #expect(echo?.output == "a b c\n")
        let slow = ProcessRunner.run("/bin/sleep", ["5"], timeout: 0.3)
        #expect(slow?.timedOut == true)
    }

    // MARK: Goldens

    static let update = ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] == "1"

    func golden(_ name: String, _ text: String) throws {
        if Self.update {
            // The source copies; the bundle is rebuilt from them.
            let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("fixtures/agent-config")
            let url = folder.appendingPathComponent("\(name).json")
            if (try? String(contentsOf: url, encoding: .utf8)) != text {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            return
        }
        let url = try #require(Bundle.module.resourceURL?
            .appendingPathComponent("fixtures/agent-config/\(name).json"))
        let expected = try #require(try? String(contentsOf: url, encoding: .utf8),
                                    "missing golden \(name).json; run with UPDATE_GOLDENS=1")
        #expect(expected == text, "\(name).json differs; run with UPDATE_GOLDENS=1 if intended")
    }
}
