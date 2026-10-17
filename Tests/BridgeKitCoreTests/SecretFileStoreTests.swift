import Darwin
import Foundation
import Testing
@testable import BridgeKitCore

/// Private key files: 0600 files in a 0700 folder, created new or replacing a safe file, and never
/// through a symlink, a shared folder or an oversize file.
@Suite("Secret files")
struct SecretFileStoreTests {
    static let prefix = "test_mcp_v1_"
    static let first = prefix + String(repeating: "a", count: 64)
    static let next = prefix + String(repeating: "b", count: 64)

    /// A private parent folder per test, removed afterwards.
    final class Scratch {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("bridgekit-secret-files-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }

        deinit {
            chmod(root.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }

        var store: SecretFileStore { SecretFileStore(parent: root, folderName: "agent-keys") }
        var files: AgentKeyFiles { AgentKeyFiles(store: store, keyPrefix: SecretFileStoreTests.prefix) }
    }

    @Test("private create, atomic replace, remove, unsafe path and overwrite checks")
    func agentKeyFiles() throws {
        let scratch = try Scratch()
        let root = scratch.root
        let files = scratch.files
        let id = UUID().uuidString.lowercased()
        let path = try value(files.saveNew(agentID: id, key: Self.first))
        #expect(path.lastPathComponent == id + ".mcp-token")
        #expect(path == files.url(agentID: id))
        #expect(path.deletingLastPathComponent() == scratch.store.directory)
        #expect(mode(path) == 0o600)
        #expect(mode(path.deletingLastPathComponent()) == 0o700)
        #expect(files.status(agentID: id) == .present)
        #expect(files.status(agentID: UUID().uuidString) == .missing)
        #expect(files.status(agentID: "not-a-uuid") == .unsafe)
        // An unsafe folder makes the file unsafe too, so rotation refuses early.
        chmod(path.deletingLastPathComponent().path, 0o755)
        #expect(files.status(agentID: id) == .unsafe)
        chmod(path.deletingLastPathComponent().path, 0o700)
        chmod(path.path, 0o644)
        #expect(files.status(agentID: id) == .unsafe)
        chmod(path.path, 0o600)
        let absent = SecretFileStore(parent: root.appendingPathComponent("absent"), folderName: "agent-keys")
        #expect(AgentKeyFiles(store: absent, keyPrefix: Self.prefix).status(agentID: id) == .missing)
        // The bare key, no newline, so agents can read it directly.
        #expect(try Data(contentsOf: path) == Data(Self.first.utf8))
        try failure(files.saveNew(agentID: id, key: Self.next), .alreadyExists)
        #expect(try value(scratch.store.canReplace(clientID: id, kind: .mcpKey)) == path)
        _ = try value(files.replace(agentID: id, key: Self.next))
        #expect(try Data(contentsOf: path) == Data(Self.next.utf8))
        #expect(mode(path) == 0o600)
        try value(files.remove(agentID: id))
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(files.status(agentID: id) == .missing)

        // A symlink where the file belongs is never followed, replaced or removed.
        let symlinkTarget = root.appendingPathComponent("target")
        try Data("not-a-credential".utf8).write(to: symlinkTarget)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: symlinkTarget)
        #expect(files.status(agentID: id) == .unsafe)
        try failure(files.saveNew(agentID: id, key: Self.first), .alreadyExists)
        try failure(scratch.store.canReplace(clientID: id, kind: .mcpKey), .unsafeExistingFile)
        try failure(files.replace(agentID: id, key: Self.first), .unsafeExistingFile)
        try failure(files.remove(agentID: id), .unsafeExistingFile)
        #expect(try Data(contentsOf: symlinkTarget) == Data("not-a-credential".utf8))
        try FileManager.default.removeItem(at: path)

        // A shared file is refused the same way.
        _ = try value(files.saveNew(agentID: id, key: Self.first))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        try failure(scratch.store.canReplace(clientID: id, kind: .mcpKey), .unsafeExistingFile)
        try failure(files.replace(agentID: id, key: Self.next), .unsafeExistingFile)
        try failure(files.remove(agentID: id), .unsafeExistingFile)
        try FileManager.default.removeItem(at: path)

        try failure(files.saveNew(agentID: "../escape", key: Self.first), .invalidCredential)
        try failure(files.saveNew(agentID: id, key: "short"), .invalidCredential)
        // A key with another app's prefix, or upper-case hex, is not this app's key.
        try failure(files.saveNew(agentID: id, key: "ekb_mcp_v1_" + String(repeating: "a", count: 64)),
                    .invalidCredential)
        try failure(files.saveNew(agentID: id, key: Self.prefix + String(repeating: "A", count: 64)),
                    .invalidCredential)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try failure(files.saveNew(agentID: id, key: Self.first), .unsafeDirectory)
        #expect(files.status(agentID: id) == .unsafe)
        #expect(leftovers(scratch.store.directory).isEmpty)
    }

    @Test("replace needs an existing safe file; save picks new or replace")
    func replaceVersusNew() throws {
        let scratch = try Scratch()
        let files = scratch.files
        let id = UUID().uuidString
        // Replacing needs a file to replace (and a folder to find it in).
        try failure(files.replace(agentID: id, key: Self.first), .unsafeDirectory)
        _ = try value(files.saveNew(agentID: UUID().uuidString, key: Self.first))
        try failure(files.replace(agentID: id, key: Self.first), .unsafeExistingFile)
        try failure(scratch.store.canReplace(clientID: id, kind: .mcpKey), .unsafeExistingFile)
        // save: new when missing, replace when present.
        let path = try value(files.save(agentID: id, key: Self.first))
        // Upper-case UUIDs name the same lower-case file.
        #expect(path.lastPathComponent == id.lowercased() + ".mcp-token")
        #expect(try Data(contentsOf: path) == Data(Self.first.utf8))
        #expect(try value(files.save(agentID: id, key: Self.next)) == path)
        #expect(try Data(contentsOf: path) == Data(Self.next.utf8))
        #expect(files.status(agentID: id.lowercased()) == .present)
        // Removing what isn't there succeeds, also when the folder doesn't exist yet.
        try value(files.remove(agentID: UUID().uuidString))
        let empty = try Scratch()
        try value(empty.files.remove(agentID: id))
        try failure(empty.files.remove(agentID: "nope"), .invalidCredential)
        #expect(leftovers(scratch.store.directory).isEmpty)
    }

    @Test("size limits, other file types and a symlinked folder")
    func sizeAndTypes() throws {
        let scratch = try Scratch()
        let store = scratch.store
        let small = SecretFileKind(fileSuffix: ".secret", maxBytes: 16)
        let id = UUID().uuidString.lowercased()
        // Data over the kind's limit is refused before anything is written.
        try failure(store.write(clientID: id, kind: small, data: Data(count: 17), replacing: false),
                    .invalidCredential)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
        let path = try value(store.write(clientID: id, kind: small, data: Data(count: 16), replacing: false))
        #expect(path.lastPathComponent == id + ".secret")
        #expect(store.url(for: id, kind: small) == path)
        #expect(store.status(clientID: id, kind: small) == .present)
        // Kinds are separate files.
        #expect(store.status(clientID: id, kind: .mcpKey) == .missing)
        // A file that grew past the limit is unsafe and never replaced.
        try Data(count: 17).write(to: path)
        chmod(path.path, 0o600)
        #expect(store.status(clientID: id, kind: small) == .unsafe)
        try failure(store.canReplace(clientID: id, kind: small), .unsafeExistingFile)
        try failure(store.write(clientID: id, kind: small, data: Data(count: 1), replacing: true),
                    .unsafeExistingFile)
        try failure(store.remove(clientID: id, kind: small), .unsafeExistingFile)
        try FileManager.default.removeItem(at: path)
        // A folder in place of the file.
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        #expect(store.status(clientID: id, kind: small) == .unsafe)
        try failure(store.write(clientID: id, kind: small, data: Data(count: 1), replacing: true),
                    .unsafeExistingFile)
        try failure(store.write(clientID: id, kind: small, data: Data(count: 1), replacing: false),
                    .alreadyExists)
        try FileManager.default.removeItem(at: path)

        // The key folder as a symlink to a private folder is still refused.
        let elsewhere = try Scratch()
        try FileManager.default.removeItem(at: store.directory)
        try FileManager.default.createSymbolicLink(at: store.directory, withDestinationURL: elsewhere.root)
        #expect(store.status(clientID: id, kind: small) == .unsafe)
        try failure(store.write(clientID: id, kind: small, data: Data(count: 1), replacing: false),
                    .unsafeDirectory)
        try failure(store.remove(clientID: id, kind: small), .unsafeDirectory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.root.path).isEmpty)
    }

    @Test("a private folder owned by another user is refused")
    func otherOwner() throws {
        // /var/root is root's own 0700 folder: only the owner check can refuse it.
        let parent = URL(fileURLWithPath: "/private/var/root")
        var info = stat()
        try #require(lstat(parent.path, &info) == 0 && info.st_uid != getuid() && info.st_mode & 0o077 == 0,
                     "needs a private folder owned by another user")
        let store = SecretFileStore(parent: parent, folderName: "keys")
        let id = UUID().uuidString
        #expect(store.status(clientID: id, kind: .mcpKey) == .unsafe)
        try failure(store.write(clientID: id, kind: .mcpKey, data: Data("x".utf8), replacing: false),
                    .unsafeDirectory)
        try failure(store.canReplace(clientID: id, kind: .mcpKey), .unsafeDirectory)
        try failure(store.remove(clientID: id, kind: .mcpKey), .unsafeDirectory)
    }

    // MARK: Helpers

    func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    /// Temporary files left in the key folder.
    func leftovers(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix(".tmp-") }
    }

    struct UnexpectedFailure: Error, CustomStringConvertible {
        let error: CredentialFileError
        var description: String { "unexpected \(error)" }
    }

    struct UnexpectedSuccess: Error {}

    @discardableResult
    func value<T>(_ result: Result<T, CredentialFileError>,
                  sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
        switch result {
        case .success(let value): return value
        case .failure(let error):
            Issue.record("unexpected \(error)", sourceLocation: sourceLocation)
            throw UnexpectedFailure(error: error)
        }
    }

    func failure<T>(_ result: Result<T, CredentialFileError>, _ expected: CredentialFileError,
                    sourceLocation: SourceLocation = #_sourceLocation) throws {
        switch result {
        case .success:
            Issue.record("expected \(expected)", sourceLocation: sourceLocation)
            throw UnexpectedSuccess()
        case .failure(let error):
            #expect(error == expected, sourceLocation: sourceLocation)
        }
    }
}
