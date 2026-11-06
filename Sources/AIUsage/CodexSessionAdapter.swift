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
            fileManager: fileManager
        )
    }

    private static func stage(source: URL, accountID: String, under root: URL, fileManager fm: FileManager) throws -> URL {
        guard isDirectory(source, fm: fm), hasAuth(source, fm: fm) else { throw CodexSessionAdapterError.invalidSource }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let destination = root.appendingPathComponent("\(safeComponent(accountID))-\(UUID().uuidString.lowercased())", isDirectory: true)
        do {
            try fm.copyItem(at: source, to: destination)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.appendingPathComponent("auth.json").path)
            try syncTree(at: destination, fm: fm)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
            try syncDirectory(destination.deletingLastPathComponent())
            return destination
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    private static func activate(reference: URL, live: URL, spareRoot: URL, isBusy: () -> Bool, fileManager fm: FileManager) throws {
        guard isDirectory(reference, fm: fm), hasAuth(reference, fm: fm) else { throw CodexSessionAdapterError.missingAuth }
        guard isDirectory(live, fm: fm) else { throw CodexSessionAdapterError.missingLiveHome }
        try requireSafeToChange(live: live, isBusy: isBusy)
        guard volume(live) != nil, volume(live) == volume(reference) else { throw CodexSessionAdapterError.crossVolume }

        let parent = live.deletingLastPathComponent()
        let incoming = parent.appendingPathComponent(".codex-adapter-incoming-\(UUID().uuidString)", isDirectory: true)
        let outgoing = spareRoot.appendingPathComponent("parked-\(UUID().uuidString.lowercased())", isDirectory: true)
        try fm.createDirectory(at: spareRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try fm.copyItem(at: reference, to: incoming)
            try syncTree(at: incoming, fm: fm)
            try fm.moveItem(at: live, to: outgoing)
            do {
                try fm.moveItem(at: incoming, to: live)
                try syncDirectory(parent)
                try syncDirectory(spareRoot)
            } catch {
                try? fm.moveItem(at: outgoing, to: live)
                throw error
            }
        } catch {
            try? fm.removeItem(at: incoming)
            throw error
        }
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
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { throw CodexSessionAdapterError.syncFailed }
        var directories: [URL] = [root]
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true { directories.append(item) }
            else { try syncFile(item) }
        }
        for directory in directories.reversed() { try syncDirectory(directory) }
    }

    private static func syncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CodexSessionAdapterError.syncFailed }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CodexSessionAdapterError.syncFailed }
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CodexSessionAdapterError.syncFailed }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CodexSessionAdapterError.syncFailed }
    }

    private static func volume(_ url: URL) -> AnyHashable? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? AnyHashable
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
