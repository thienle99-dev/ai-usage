import Foundation
import Darwin

/// Codex-specific filesystem operations for the durable account-session manager.
/// All locations are supplied by the caller so tests and future callers can use
/// an isolated Codex home and account store.
struct CodexSessionAdapter {
    let manager: DurableAccountSessionManager

    init(liveHomeURL: URL, spareRootURL: URL, indexURL: URL,
         identify: DurableAccountSessionManager.Identify? = nil,
         isBusy: @escaping @Sendable () -> Bool = Self.codexLoginIsRunning,
         fileManager: FileManager = .default) {
        let live = liveHomeURL.standardizedFileURL
        let root = spareRootURL.standardizedFileURL
        let identifyLive = identify ?? {
            let data = try awaitCodexIdentity(home: live)
            let parsed = try UsageParsing.codex(data)
            return (live.path, parsed.accountID ?? "", parsed.account)
        }
        let fileManagerBox = SendableFileManager(fileManager)
        manager = DurableAccountSessionManager(
            tool: .codex,
            indexURL: indexURL,
            identify: identifyLive,
            stage: { source, accountID in try Self.stage(source: URL(fileURLWithPath: source), accountID: accountID, under: root, fileManager: fileManagerBox.value).path },
            activate: { reference in try Self.activate(reference: URL(fileURLWithPath: reference), live: live, spareRoot: root, isBusy: isBusy, fileManager: fileManagerBox.value) },
            safeToChange: { try Self.requireSafeToChange(live: live, isBusy: isBusy) },
            recoverInterrupted: { journal in
                try Self.recoverInterrupted(
                    journal: journal, live: live, spareRoot: root, identify: identifyLive,
                    isBusy: isBusy, fileManager: fileManagerBox.value
                )
            },
            removeAccountResource: { account, _ in
                try Self.removeSavedSession(
                    reference: account.sessionReference,
                    accountID: account.id,
                    liveHome: live,
                    spareRoot: root,
                    fileManager: fileManagerBox.value
                )
            },
            fileManager: fileManager
        )
    }

    private static func removeSavedSession(
        reference: String,
        accountID: String,
        liveHome: URL,
        spareRoot: URL,
        fileManager fm: FileManager
    ) throws {
        let target = URL(fileURLWithPath: reference, isDirectory: true).standardizedFileURL
        let root = spareRoot.standardizedFileURL
        guard target != liveHome.standardizedFileURL else { return }
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard target.path.hasPrefix(rootPrefix),
              target.lastPathComponent.hasPrefix(safeComponent(accountID) + "-") else { return }
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0 else {
            if errno == ENOENT { return }
            throw CodexSessionAdapterError.invalidSource
        }
        guard (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              rootInfo.st_uid == geteuid() else { throw CodexSessionAdapterError.invalidSource }
        var targetInfo = stat()
        guard lstat(target.path, &targetInfo) == 0 else {
            if errno == ENOENT { return }
            throw CodexSessionAdapterError.invalidSource
        }
        guard (targetInfo.st_mode & S_IFMT) == S_IFDIR,
              targetInfo.st_uid == geteuid() else { throw CodexSessionAdapterError.invalidSource }
        try fm.removeItem(at: target)
        try syncDirectory(root)
    }

    private static func stage(source: URL, accountID: String, under root: URL, fileManager fm: FileManager) throws -> URL {
        guard isDirectory(source, fm: fm), hasAuth(source, fm: fm) else { throw CodexSessionAdapterError.invalidSource }
        CodexSwitchDiagnostics.log("stage.begin source_auth_present=true")
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let destination = root.appendingPathComponent("\(safeComponent(accountID))-\(UUID().uuidString.lowercased())", isDirectory: true)
        do {
            var skippedSockets = 0
            try copySessionDirectory(from: source, to: destination, fileManager: fm, skippedSockets: &skippedSockets)
            CodexSwitchDiagnostics.log("stage.copy.complete auth_present=\(hasAuth(destination, fm: fm)) sockets_skipped=\(skippedSockets)")
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.appendingPathComponent("auth.json").path)
            try syncTree(at: destination, fm: fm)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
            try syncDirectory(destination.deletingLastPathComponent())
            CodexSwitchDiagnostics.log("stage.complete auth_present=\(hasAuth(destination, fm: fm))")
            return destination
        } catch {
            CodexSwitchDiagnostics.log("stage.failed error_type=\(String(describing: type(of: error)))")
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    /// Codex keeps live IPC sockets inside its home directory. They are runtime
    /// endpoints, not account state, and FileManager cannot copy Unix sockets.
    private static func copySessionDirectory(from source: URL, to destination: URL, fileManager fm: FileManager, skippedSockets: inout Int) throws {
        var sourceInfo = stat()
        guard lstat(source.path, &sourceInfo) == 0, (sourceInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw CodexSessionAdapterError.invalidSource
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        do {
            for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: []) {
                var itemInfo = stat()
                guard lstat(item.path, &itemInfo) == 0 else { throw CocoaError(.fileReadUnknown) }
                let itemType = itemInfo.st_mode & S_IFMT
                if itemType == S_IFSOCK {
                    skippedSockets += 1
                    continue
                }

                let copy = destination.appendingPathComponent(item.lastPathComponent, isDirectory: itemType == S_IFDIR)
                if itemType == S_IFDIR {
                    try copySessionDirectory(from: item, to: copy, fileManager: fm, skippedSockets: &skippedSockets)
                } else {
                    do { try fm.copyItem(at: item, to: copy) }
                    catch {
                        CodexSwitchDiagnostics.log("copy.entry.failed kind=\(itemType == S_IFLNK ? "symlink" : itemType == S_IFREG ? "file" : "special") error_type=\(String(describing: type(of: error)))")
                        throw error
                    }
                }
            }
            try fm.setAttributes([.posixPermissions: Int(sourceInfo.st_mode & 0o777)], ofItemAtPath: destination.path)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    private static func activate(reference: URL, live: URL, spareRoot: URL, isBusy: () -> Bool, fileManager fm: FileManager) throws {
        guard isDirectory(reference, fm: fm), hasAuth(reference, fm: fm) else { throw CodexSessionAdapterError.missingAuth }
        guard isDirectory(live, fm: fm) else { throw CodexSessionAdapterError.missingLiveHome }
        CodexSwitchDiagnostics.log("activate.begin target_auth_present=true live_auth_present=\(hasAuth(live, fm: fm))")
        try requireSafeToChange(live: live, isBusy: isBusy)
        guard volume(live) != nil, volume(live) == volume(reference) else { throw CodexSessionAdapterError.crossVolume }

        let parent = live.deletingLastPathComponent()
        let incoming = parent.appendingPathComponent(".codex-adapter-incoming-\(UUID().uuidString)", isDirectory: true)
        let outgoing = spareRoot.appendingPathComponent("parked-\(UUID().uuidString.lowercased())", isDirectory: true)
        try fm.createDirectory(at: spareRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var step = "copy_target"
        do {
            var skippedSockets = 0
            try copySessionDirectory(from: reference, to: incoming, fileManager: fm, skippedSockets: &skippedSockets)
            CodexSwitchDiagnostics.log("activate.copy_target.complete auth_present=\(hasAuth(incoming, fm: fm)) sockets_skipped=\(skippedSockets)")
            step = "sync_target"
            try syncTree(at: incoming, fm: fm)
            step = "park_live_home"
            try fm.moveItem(at: live, to: outgoing)
            CodexSwitchDiagnostics.log("activate.live_parked auth_present=\(hasAuth(outgoing, fm: fm))")
            step = "install_target"
            do {
                try fm.moveItem(at: incoming, to: live)
                CodexSwitchDiagnostics.log("activate.target_installed auth_present=\(hasAuth(live, fm: fm))")
                step = "sync_live_parent"
                try syncDirectory(parent)
                step = "sync_spare_root"
                try syncDirectory(spareRoot)
                step = "remove_parked_home"
                try fm.removeItem(at: outgoing)
                try removeTransitionArtifacts(parent: parent, spareRoot: spareRoot, fileManager: fm)
                CodexSwitchDiagnostics.log("activate.complete live_auth_present=\(hasAuth(live, fm: fm))")
            } catch {
                if !isDirectory(live, fm: fm) {
                    do {
                        try fm.moveItem(at: outgoing, to: live)
                        CodexSwitchDiagnostics.log("activate.rollback.complete live_auth_present=\(hasAuth(live, fm: fm))")
                    } catch {
                        CodexSwitchDiagnostics.log("activate.rollback.failed error_type=\(String(describing: type(of: error)))")
                    }
                }
                throw error
            }
        } catch {
            CodexSwitchDiagnostics.log("activate.failed step=\(step) error_type=\(String(describing: type(of: error)))")
            try? fm.removeItem(at: incoming)
            throw error
        }
    }

    private static func recoverInterrupted(
        journal: AccountSessionJournal,
        live: URL,
        spareRoot: URL,
        identify: DurableAccountSessionManager.Identify,
        isBusy: @Sendable () -> Bool,
        fileManager fm: FileManager
    ) throws {
        guard journal.operation == .activate, journal.tool == .codex else { return }
        guard !CodexAppServerActivity.isActive, !isBusy() else { throw CodexSessionAdapterError.busy }

        let parent = live.deletingLastPathComponent()
        if isDirectory(live, fm: fm) {
            let fingerprint: String
            do { fingerprint = try identify().fingerprint }
            catch { throw AccountSessionError.recoveryRequired("the live Codex session could not be identified; recovery files were preserved") }
            guard fingerprint == journal.previousFingerprint || fingerprint == journal.targetFingerprint else {
                throw AccountSessionError.recoveryRequired("the live Codex identity matches neither side of the interrupted switch")
            }
        } else {
            guard let stagedReference = journal.stagedReference, stagedReference != "signed-out" else {
                throw AccountSessionError.recoveryRequired("the previous Codex session has no durable recovery copy")
            }
            let staged = URL(fileURLWithPath: stagedReference, isDirectory: true)
            guard isDirectory(staged, fm: fm), hasAuth(staged, fm: fm) else {
                throw AccountSessionError.recoveryRequired("the durable copy of the previous Codex session is unavailable")
            }

            let recovery = parent.appendingPathComponent(".codex-adapter-recovery-\(UUID().uuidString)", isDirectory: true)
            do {
                var skippedSockets = 0
                try copySessionDirectory(from: staged, to: recovery, fileManager: fm, skippedSockets: &skippedSockets)
                CodexSwitchDiagnostics.log("recovery.copy_previous.complete auth_present=\(hasAuth(recovery, fm: fm)) sockets_skipped=\(skippedSockets)")
                try syncTree(at: recovery, fm: fm)
                try fm.moveItem(at: recovery, to: live)
                try syncDirectory(parent)
            } catch {
                try? fm.removeItem(at: recovery)
                throw AccountSessionError.recoveryRequired("the previous Codex session could not be restored from its durable copy")
            }

            do {
                let restored = try identify()
                guard restored.fingerprint == journal.previousFingerprint else {
                    throw AccountSessionError.recoveryRequired("the restored Codex session does not match the previous account")
                }
            } catch {
                throw AccountSessionError.recoveryRequired("the previous Codex session was restored, but its identity could not be verified")
            }
        }

        try removeTransitionArtifacts(parent: parent, spareRoot: spareRoot, fileManager: fm)
    }

    private static func removeTransitionArtifacts(parent: URL, spareRoot: URL, fileManager fm: FileManager) throws {
        if isDirectory(parent, fm: fm) {
            let temporaryDirectories = try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey])
                .filter { $0.lastPathComponent.hasPrefix(".codex-adapter-incoming-") || $0.lastPathComponent.hasPrefix(".codex-adapter-recovery-") }
            for directory in temporaryDirectories { try fm.removeItem(at: directory) }
        }
        guard isDirectory(spareRoot, fm: fm) else { return }
        let parkedDirectories = try fm.contentsOfDirectory(at: spareRoot, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.lastPathComponent.hasPrefix("parked-") }
        for directory in parkedDirectories { try fm.removeItem(at: directory) }
    }

    private static func requireSafeToChange(live: URL, isBusy: () -> Bool) throws {
        guard isDirectory(live, fm: .default) else { throw CodexSessionAdapterError.missingLiveHome }
        if CodexAppServerActivity.isActive || isBusy() { throw CodexSessionAdapterError.busy }
    }

    /// Only an in-progress `codex login` writes auth.json. Codex 0.167+ keeps a
    /// long-lived `app-server` daemon running, so matching app-server here would
    /// make every switch refuse with "busy" on a normal install.
    static func codexLoginIsRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "(^|/)(codex|CodexCLI) login( |$)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
        catch { return false }
    }

    private static func isDirectory(_ url: URL, fm: FileManager) -> Bool {
        var directory = ObjCBool(false)
        return fm.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    private static func hasAuth(_ url: URL, fm: FileManager) -> Bool {
        var directory = ObjCBool(false)
        let auth = url.appendingPathComponent("auth.json")
        return fm.fileExists(atPath: auth.path, isDirectory: &directory) && !directory.boolValue
    }

    private static func safeComponent(_ value: String) -> String {
        let cleaned = value.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) ? String($0) : "_" }.joined()
        return cleaned.isEmpty ? "account" : String(cleaned.prefix(80))
    }

    private static func syncTree(at root: URL, fm: FileManager) throws {
        CodexSwitchDiagnostics.log("sync.tree.begin")
        var directories: [URL] = [root]
        try collectSyncableItems(in: root, directories: &directories, fileManager: fm)
        for directory in directories.reversed() { try syncDirectory(directory) }
        CodexSwitchDiagnostics.log("sync.tree.complete directories=\(directories.count)")
    }

    private static func collectSyncableItems(in directory: URL, directories: inout [URL], fileManager fm: FileManager) throws {
        for item in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: []) {
            var itemInfo = stat()
            guard lstat(item.path, &itemInfo) == 0 else { throw CodexSessionAdapterError.syncFailed }
            switch itemInfo.st_mode & S_IFMT {
            case S_IFDIR:
                directories.append(item)
                try collectSyncableItems(in: item, directories: &directories, fileManager: fm)
            case S_IFREG:
                try syncFile(item)
            default:
                // Symlinks, sockets, pipes, and device files are not durable
                // session data and cannot be synchronized as regular files.
                continue
            }
        }
    }

    private static func syncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            CodexSwitchDiagnostics.log("sync.file.open_failed errno=\(errno)")
            throw CodexSessionAdapterError.syncFailed
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            CodexSwitchDiagnostics.log("sync.file.fsync_failed errno=\(errno)")
            throw CodexSessionAdapterError.syncFailed
        }
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            CodexSwitchDiagnostics.log("sync.directory.open_failed errno=\(errno)")
            throw CodexSessionAdapterError.syncFailed
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            CodexSwitchDiagnostics.log("sync.directory.fsync_failed errno=\(errno)")
            throw CodexSessionAdapterError.syncFailed
        }
    }

    private static func volume(_ url: URL) -> AnyHashable? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? AnyHashable
    }
}

enum CodexSwitchDiagnostics {
    static func log(_ event: String) {
        #if DEBUG
        FileHandle.standardError.write(Data("[CodexSwitch] \(event)\n".utf8))
        #endif
    }
}

enum CodexAppServerActivity {
    private static let state = ActivityState()
    static var isActive: Bool { state.isActive }
    static func withActivity<T>(_ body: () throws -> T) rethrows -> T {
        state.begin()
        defer { state.end() }
        return try body()
    }
}

private final class ActivityState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return count > 0 }
    func begin() { lock.lock(); count += 1; lock.unlock() }
    func end() { lock.lock(); count -= 1; lock.unlock() }
}

private final class SendableFileManager: @unchecked Sendable {
    let value: FileManager
    init(_ value: FileManager) { self.value = value }
}

private func awaitCodexIdentity(home: URL) throws -> Data {
    // LocalCodexAppServerDataSource is async by design. Run its query on a
    // dedicated thread so the synchronous manager closure can still use it.
    let semaphore = DispatchSemaphore(value: 0)
    let result = LockedCodexIdentityResult()
    Task {
        do { result.set(.success(try await LocalCodexAppServerDataSource(codexHome: home).read())) }
        catch { result.set(.failure(error)) }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get().get()
}

private final class LockedCodexIdentityResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Data, Error>?
    func set(_ value: Result<Data, Error>) { lock.lock(); defer { lock.unlock() }; self.value = value }
    func get() -> Result<Data, Error> { lock.lock(); defer { lock.unlock() }; return value ?? .failure(CodexSessionAdapterError.identityFailed) }
}

enum CodexSessionAdapterError: LocalizedError {
    case invalidSource, missingAuth, missingLiveHome, crossVolume, busy, syncFailed, identityFailed
    var errorDescription: String? {
        switch self {
        case .invalidSource: "The Codex home is missing or has no auth.json."
        case .missingAuth: "The stored Codex home is missing auth.json."
        case .missingLiveHome: "The live Codex home is missing."
        case .crossVolume: "The live and stored Codex homes must be on the same volume."
        case .busy: "Codex login or app-server activity is in progress."
        case .syncFailed: "Could not durably sync the staged Codex home."
        case .identityFailed: "Could not read the Codex account identity."
        }
    }
}
