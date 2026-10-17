import Darwin
import Foundation

public enum CredentialFileStatus: Equatable, Sendable {
    case present
    case missing
    /// Wrong owner, mode, type or size: never replaced automatically.
    case unsafe
}

/// One kind of secret file an app keeps per agent, named `<uuid><suffix>`.
public struct SecretFileKind: Hashable, Sendable {
    public let fileSuffix: String
    public let maxBytes: Int

    public init(fileSuffix: String, maxBytes: Int) {
        self.fileSuffix = fileSuffix
        self.maxBytes = maxBytes
    }

    /// An MCP bearer key: the bare key with no newline, so agents can read it
    /// directly (`${file:…}`, `$(cat …)`, the launcher).
    public static let mcpKey = SecretFileKind(fileSuffix: ".mcp-token", maxBytes: 128)
}

public enum CredentialFileError: String, Error, Sendable {
    case invalidCredential
    case unsafeDirectory
    case unsafeExistingFile
    case alreadyExists
    case missingFile
    case writeFailed
    case removeFailed
}

/// Private secrets (agent keys) live outside the app's agent store, which keeps
/// only digests. The path is fixed by agent UUID; no caller-supplied path
/// enters file APIs. Files are 0600 in a 0700 folder, written through a
/// temporary file and `linkat`/`renameat`, then fsynced with their folder.
/// This protects against other UIDs, not a malicious process with the same UID.
public final class SecretFileStore: Sendable {
    public let parent: URL
    public let directory: URL

    /// `parent` must exist and be private; `folderName` is created inside it on first write.
    public init(parent: URL, folderName: String) {
        self.parent = parent
        directory = parent.appendingPathComponent(folderName, isDirectory: true)
    }

    public func url(for clientID: String, kind: SecretFileKind) -> URL? {
        guard let uuid = UUID(uuidString: clientID) else { return nil }
        return directory.appendingPathComponent(uuid.uuidString.lowercased() + kind.fileSuffix)
    }

    /// Whether the file exists and is safe, without reading it.
    public func status(clientID: String, kind: SecretFileKind) -> CredentialFileStatus {
        guard let destination = url(for: clientID, kind: kind) else { return .unsafe }
        var info = stat()
        // Folders that exist must be private and owned, or nothing is written.
        for folder in [parent, directory] {
            if lstat(folder.path, &info) != 0 {
                if errno == ENOENT { return .missing }
                return .unsafe
            }
            guard Self.safeDirectory(info) else { return .unsafe }
        }
        if lstat(destination.path, &info) != 0 { return errno == ENOENT ? .missing : .unsafe }
        return Self.safe(info, kind: kind) ? .present : .unsafe
    }

    public func canReplace(clientID: String, kind: SecretFileKind)
        -> Result<URL, CredentialFileError> {
        guard let destination = url(for: clientID, kind: kind) else {
            return .failure(.invalidCredential)
        }
        do {
            let fd = try openDirectory(create: false)
            defer { close(fd) }
            guard Self.safeFile(name: destination.lastPathComponent, kind: kind, in: fd) else {
                return .failure(.unsafeExistingFile)
            }
            return .success(destination)
        } catch let error as CredentialFileError { return .failure(error) }
        catch { return .failure(.unsafeDirectory) }
    }

    public func remove(clientID: String, kind: SecretFileKind)
        -> Result<Void, CredentialFileError> {
        guard let destination = url(for: clientID, kind: kind) else {
            return .failure(.invalidCredential)
        }
        var directoryInfo = stat()
        if lstat(directory.path, &directoryInfo) != 0 && errno == ENOENT {
            guard lstat(parent.path, &directoryInfo) == 0,
                  Self.safeDirectory(directoryInfo) else { return .failure(.unsafeDirectory) }
            return .success(())
        }
        do {
            let fd = try openDirectory(create: false)
            defer { close(fd) }
            let name = destination.lastPathComponent
            var info = stat()
            if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                return errno == ENOENT ? .success(()) : .failure(.removeFailed)
            }
            guard Self.safe(info, kind: kind) else { return .failure(.unsafeExistingFile) }
            guard unlinkat(fd, name, 0) == 0, fsync(fd) == 0 else {
                return .failure(.removeFailed)
            }
            return .success(())
        } catch let error as CredentialFileError { return .failure(error) }
        catch { return .failure(.unsafeDirectory) }
    }

    /// Writes `data` as a new file (`replacing` false: fails if one exists) or
    /// over an existing safe one (`replacing` true: fails if there's none).
    public func write(clientID: String, kind: SecretFileKind, data: Data, replacing: Bool)
        -> Result<URL, CredentialFileError> {
        guard let destination = url(for: clientID, kind: kind), data.count <= kind.maxBytes else {
            return .failure(.invalidCredential)
        }
        do {
            let directoryFD = try openDirectory(create: !replacing)
            defer { close(directoryFD) }
            let name = destination.lastPathComponent
            var info = stat()
            let exists = fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0
            if replacing {
                guard exists, Self.safe(info, kind: kind) else { return .failure(.unsafeExistingFile) }
            } else if exists {
                return .failure(.alreadyExists)
            } else if errno != ENOENT {
                return .failure(.unsafeExistingFile)
            }
            let temporary = ".tmp-\(UUID().uuidString.lowercased())"
            let tempFD = openat(directoryFD, temporary,
                                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard tempFD >= 0 else { return .failure(.writeFailed) }
            defer { unlinkat(directoryFD, temporary, 0) }
            guard fchmod(tempFD, 0o600) == 0 else {
                close(tempFD)
                return .failure(.writeFailed)
            }
            let written = data.withUnsafeBytes { bytes -> Bool in
                guard let base = bytes.baseAddress else { return false }
                var offset = 0
                while offset < data.count {
                    let count = Darwin.write(tempFD, base.advanced(by: offset), data.count - offset)
                    if count <= 0 { return false }
                    offset += count
                }
                return fsync(tempFD) == 0
            }
            close(tempFD)
            guard written else { return .failure(.writeFailed) }
            let installed = replacing
                ? renameat(directoryFD, temporary, directoryFD, name) == 0
                : linkat(directoryFD, temporary, directoryFD, name, 0) == 0
            guard installed, fsync(directoryFD) == 0 else { return .failure(.writeFailed) }
            return .success(destination)
        } catch let error as CredentialFileError { return .failure(error) }
        catch { return .failure(.unsafeDirectory) }
    }

    private func openDirectory(create: Bool) throws -> Int32 {
        var info = stat()
        guard lstat(parent.path, &info) == 0, Self.safeDirectory(info) else {
            throw CredentialFileError.unsafeDirectory
        }
        if create && mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
            throw CredentialFileError.unsafeDirectory
        }
        guard lstat(directory.path, &info) == 0, Self.safeDirectory(info) else {
            throw CredentialFileError.unsafeDirectory
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CredentialFileError.unsafeDirectory }
        guard fstat(fd, &info) == 0, Self.safeDirectory(info) else {
            close(fd)
            throw CredentialFileError.unsafeDirectory
        }
        return fd
    }

    private static func safeDirectory(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid() &&
            info.st_mode & 0o077 == 0
    }

    private static func safeFile(name: String, kind: SecretFileKind, in directoryFD: Int32) -> Bool {
        var info = stat()
        return fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && safe(info, kind: kind)
    }

    private static func safe(_ info: stat, kind: SecretFileKind) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() &&
            info.st_mode & 0o777 == 0o600 && info.st_size <= kind.maxBytes
    }
}

/// MCP key files for one app: `<parent>/<folder>/<uuid><suffix>` (`.mcp-token` by default).
public struct AgentKeyFiles: Sendable {
    public let store: SecretFileStore
    public let keyPrefix: String
    public let kind: SecretFileKind

    public init(store: SecretFileStore, keyPrefix: String, kind: SecretFileKind = .mcpKey) {
        self.store = store
        self.keyPrefix = keyPrefix
        self.kind = kind
    }

    public func url(agentID: String) -> URL? { store.url(for: agentID, kind: kind) }

    public func status(agentID: String) -> CredentialFileStatus { store.status(clientID: agentID, kind: kind) }

    public func saveNew(agentID: String, key: String) -> Result<URL, CredentialFileError> {
        write(agentID: agentID, key: key, replacing: false)
    }

    public func replace(agentID: String, key: String) -> Result<URL, CredentialFileError> {
        write(agentID: agentID, key: key, replacing: true)
    }

    /// Saves `key`, replacing a safe existing file.
    public func save(agentID: String, key: String) -> Result<URL, CredentialFileError> {
        write(agentID: agentID, key: key, replacing: status(agentID: agentID) == .present)
    }

    public func remove(agentID: String) -> Result<Void, CredentialFileError> {
        store.remove(clientID: agentID, kind: kind)
    }

    private func write(agentID: String, key: String, replacing: Bool) -> Result<URL, CredentialFileError> {
        guard AgentKey.isValid(key, prefix: keyPrefix) else { return .failure(.invalidCredential) }
        return store.write(clientID: agentID, kind: kind, data: Data(key.utf8), replacing: replacing)
    }
}
