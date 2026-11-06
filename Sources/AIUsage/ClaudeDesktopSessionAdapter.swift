import AppKit
import CryptoKit
import CSQLite3
import Darwin
import Foundation

/// Claude Desktop owns these files. This adapter only renames them while the app is closed;
/// it never copies, decrypts, or sends the session cookie.
struct ClaudeDesktopSessionAdapter {
    let manager: DurableAccountSessionManager
    static let signedOutFingerprint = "claude-desktop-signed-out-v1"

    init(liveDataURL: URL, parkedRootURL: URL, indexURL: URL,
         isAppRunning: @escaping @Sendable () -> Bool = Self.isClaudeRunning,
         fileManager: FileManager = .default) {
        let live = liveDataURL.standardizedFileURL
        let parked = parkedRootURL.standardizedFileURL
        let fm = SendableFileManager(fileManager)
        manager = DurableAccountSessionManager(
            tool: .claudeDesktop,
            indexURL: indexURL,
            identify: { try Self.identity(in: live, fileManager: fm.value) },
            stage: { source, accountID in
                guard !isAppRunning() else { throw ClaudeDesktopSessionError.appRunning }
                return try Self.stage(source: URL(fileURLWithPath: source), accountID: accountID,
                                      live: live, parkedRoot: parked, fileManager: fm.value).path
            },
            activate: { reference in
                guard !isAppRunning() else { throw ClaudeDesktopSessionError.appRunning }
                try Self.activate(reference: URL(fileURLWithPath: reference), live: live,
                                  parkedRoot: parked, fileManager: fm.value)
            },
            safeToChange: {
                guard !isAppRunning() else { throw ClaudeDesktopSessionError.appRunning }
                try Self.validateRoots(live: live, parkedRoot: parked, fileManager: fm.value)
            },
            movesSessions: true,
            recoverInterrupted: { journal in
                guard !isAppRunning() else { throw ClaudeDesktopSessionError.appRunning }
                try Self.recover(journal: journal, live: live, parkedRoot: parked,
                                 fileManager: fm.value)
            },
            fileManager: fileManager
        )
    }

    private static let sessionItems = [
        "Cookies", "Cookies-journal", "Local Storage", "Session Storage",
        "IndexedDB/https_claude.ai_0.indexeddb.leveldb",
        "IndexedDB/https_claude.ai_0.indexeddb.blob", "WebStorage", "File System",
        "Service Worker", "Platform Notifications", "CdmStorage.db", "CdmStorage.db-journal",
        "declarative_performance_observer.db", "declarative_performance_observer.db-journal",
        "Partitions", "chrome-import-sites.json", "builtin-mcp-auth",
        "custom3p-builtin-mcp.json", "custom3p-builtin-mcp.json.journal",
        "session-popouts.json", "local-sessions.json"
    ]

    static func isClaudeRunning() -> Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").isEmpty {
            return true
        }
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return true }
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.size + 64
        var processIDs = [pid_t](repeating: 0, count: capacity)
        let copiedBytes = processIDs.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count))
        }
        guard copiedBytes > 0 else { return true }
        for processID in processIDs.prefix(Int(copiedBytes) / MemoryLayout<pid_t>.size) where processID > 0 {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let pathLength = path.withUnsafeMutableBufferPointer {
                proc_pidpath(processID, $0.baseAddress, UInt32($0.count))
            }
            guard pathLength > 0 else { continue }
            if belongsToClaudeBundle(String(cString: path)) { return true }
        }
        return false
    }

    private static func belongsToClaudeBundle(_ executablePath: String) -> Bool {
        var candidate = URL(fileURLWithPath: "/")
        for component in URL(fileURLWithPath: executablePath).pathComponents.dropFirst() {
            candidate.appendPathComponent(component)
            guard component.hasSuffix(".app") else { continue }
            if Bundle(url: candidate)?.bundleIdentifier == "com.anthropic.claudefordesktop" { return true }
        }
        return false
    }

    private static func identity(in root: URL, fileManager: FileManager) throws -> (reference: String, fingerprint: String, label: String?) {
        try validateDataRoot(root, fileManager: fileManager)
        let cookies = root.appendingPathComponent("Cookies")
        guard fileManager.fileExists(atPath: cookies.path) else { return (root.path, signedOutFingerprint, nil) }
        guard !isSymbolicLink(cookies) else { throw ClaudeDesktopSessionError.linkedFolder }
        for suffix in ["-journal", "-wal", "-shm"] {
            let sidecar = root.appendingPathComponent("Cookies" + suffix)
            guard !isSymbolicLink(sidecar) else { throw ClaudeDesktopSessionError.linkedFolder }
            if fileManager.fileExists(atPath: sidecar.path),
               (try? Data(contentsOf: sidecar)).map({ !$0.isEmpty }) == true {
                throw ClaudeDesktopSessionError.unsettledCookieStore
            }
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(cookies.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { throw ClaudeDesktopSessionError.unreadableSession }
        defer { sqlite3_close(database) }
        var versionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM meta WHERE key = 'version'", -1, &versionStatement, nil) == SQLITE_OK,
              let versionStatement, sqlite3_step(versionStatement) == SQLITE_ROW else {
            throw ClaudeDesktopSessionError.unreadableSession
        }
        defer { sqlite3_finalize(versionStatement) }
        guard let versionText = sqlite3_column_text(versionStatement, 0) else { throw ClaudeDesktopSessionError.unreadableSession }
        let version = Int(String(cString: versionText)) ?? Int.max
        guard (1...24).contains(version) else { throw ClaudeDesktopSessionError.unsupportedCookieFormat }
        let sql = "SELECT host_key, name, path, encrypted_value FROM cookies WHERE name LIKE 'sessionKey%'"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ClaudeDesktopSessionError.unreadableSession
        }
        defer { sqlite3_finalize(statement) }
        var values: [(host: String, name: String, path: String, data: Data)] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ClaudeDesktopSessionError.unreadableSession }
            guard let hostText = sqlite3_column_text(statement, 0),
                  let nameText = sqlite3_column_text(statement, 1),
                  let pathText = sqlite3_column_text(statement, 2) else {
                throw ClaudeDesktopSessionError.unreadableSession
            }
            let host = String(cString: hostText)
            let name = String(cString: nameText)
            let path = String(cString: pathText)
            guard ["sessionKey", "sessionKeyV2", "sessionKeyV3", "sessionKeyLC", "sessionKeyV3LC"].contains(name) else {
                throw ClaudeDesktopSessionError.unsupportedCookieFormat
            }
            guard host == ".claude.ai" || host == "claude.ai" else {
                throw ClaudeDesktopSessionError.unidentified
            }
            guard let bytes = sqlite3_column_blob(statement, 3) else { throw ClaudeDesktopSessionError.unreadableSession }
            let length = Int(sqlite3_column_bytes(statement, 3))
            let value = Data(bytes: bytes, count: length)
            guard value.starts(with: Data("v10".utf8)) else { throw ClaudeDesktopSessionError.unsupportedCookieFormat }
            values.append((host, name, path, value))
        }
        let keys = values.filter { $0.name == "sessionKey" && $0.path == "/" }
        if values.isEmpty { return (root.path, signedOutFingerprint, nil) }
        guard values.filter({ $0.name == "sessionKey" }).count == 1,
              keys.count == 1, let cookie = keys.first?.data else { throw ClaudeDesktopSessionError.unidentified }
        let fingerprint = SHA256.hash(data: cookie).map { String(format: "%02x", $0) }.joined()
        return (root.path, fingerprint, "Claude Desktop account")
    }

    private static func validateRoots(live: URL, parkedRoot: URL, fileManager: FileManager) throws {
        try validateDataRoot(live, fileManager: fileManager)
        if fileManager.fileExists(atPath: parkedRoot.path) {
            let values = try parkedRoot.resourceValues(forKeys: [.isSymbolicLinkKey, .volumeIdentifierKey])
            let liveValues = try live.resourceValues(forKeys: [.volumeIdentifierKey])
            guard values.isSymbolicLink != true, isOwnedByCurrentUser(parkedRoot) else { throw ClaudeDesktopSessionError.linkedFolder }
            guard let parkedVolume = values.volumeIdentifier as? AnyHashable,
                  let liveVolume = liveValues.volumeIdentifier as? AnyHashable,
                  parkedVolume == liveVolume else {
                throw ClaudeDesktopSessionError.differentVolume
            }
        }
    }

    private static func validateDataRoot(_ root: URL, fileManager: FileManager) throws {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true else { throw ClaudeDesktopSessionError.missingDataFolder }
        guard values.isSymbolicLink != true, isOwnedByCurrentUser(root) else { throw ClaudeDesktopSessionError.linkedFolder }
        if fileManager.fileExists(atPath: root.appendingPathComponent("reset-app-data").path),
           !fileManager.fileExists(atPath: root.appendingPathComponent("reset-app-data.given-up").path) {
            throw ClaudeDesktopSessionError.appResetPending
        }
        let thirdParty = root.deletingLastPathComponent().appendingPathComponent("Claude-3p")
        if fileManager.fileExists(atPath: thirdParty.appendingPathComponent("config.json").path) {
            let config = try? Data(contentsOf: thirdParty.appendingPathComponent("claude_desktop_config.json"))
            let mode = config.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["deploymentMode"] as? String
            guard mode == "1p" else { throw ClaudeDesktopSessionError.thirdPartyDeployment }
        }
    }

    private static func stage(source: URL, accountID: String, live: URL, parkedRoot: URL, fileManager fm: FileManager) throws -> URL {
        guard source.standardizedFileURL == live, try identity(in: live, fileManager: fm).fingerprint.count == 64 else {
            throw ClaudeDesktopSessionError.unidentified
        }
        try validateRoots(live: live, parkedRoot: parkedRoot, fileManager: fm)
        try fm.createDirectory(at: parkedRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parkedRoot.path)
        try validateRoots(live: live, parkedRoot: parkedRoot, fileManager: fm)
        let destination = parkedRoot.appendingPathComponent("parked-\(safeComponent(accountID))", isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else { throw ClaudeDesktopSessionError.parkAlreadyExists }
        try fm.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try moveSessionItems(from: live, to: destination, fileManager: fm)
            try secureTree(at: destination, fileManager: fm)
            try syncDirectory(live)
            try syncDirectory(destination)
            try syncDirectory(parkedRoot)
            return destination
        } catch {
            try? moveSessionItems(from: destination, to: live, fileManager: fm)
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    private static func activate(reference: URL, live: URL, parkedRoot: URL, fileManager fm: FileManager) throws {
        guard reference.deletingLastPathComponent().standardizedFileURL == parkedRoot,
              reference.lastPathComponent.hasPrefix("parked-"), fm.fileExists(atPath: reference.path) else {
            throw ClaudeDesktopSessionError.accountMissing
        }
        try validateRoots(live: live, parkedRoot: parkedRoot, fileManager: fm)
        try validateDataRoot(reference, fileManager: fm)
        guard try identity(in: reference, fileManager: fm).fingerprint.count == 64 else { throw ClaudeDesktopSessionError.unidentified }
        try moveSessionItems(from: reference, to: live, fileManager: fm)
        try syncDirectory(live)
        try syncDirectory(reference.deletingLastPathComponent())
        try? fm.removeItem(at: reference)
    }

    static func recover(journal: AccountSessionJournal, live: URL, parkedRoot: URL, fileManager fm: FileManager) throws {
        guard fm.fileExists(atPath: live.path) else { throw ClaudeDesktopSessionError.missingDataFolder }
        try validateRoots(live: live, parkedRoot: parkedRoot, fileManager: fm)
        switch journal.operation {
        case .importSession:
            break
        case .stash:
            let parked = parkedRoot.appendingPathComponent("parked-\(safeComponent(journal.accountID))")
            try moveSessionItems(from: parked, to: live, fileManager: fm)
        case .activate:
            let incoming = parkedRoot.appendingPathComponent("parked-\(safeComponent(journal.accountID))")
            // The manager writes this marker only after the outgoing session is
            // safely parked. Without it, recover an interrupted outgoing move
            // directly; the target folder still holds its original session.
            if journal.stagedReference != nil {
                try moveSessionItems(from: live, to: incoming, fileManager: fm)
            }
            if let previousID = journal.previousID {
                let outgoing = parkedRoot.appendingPathComponent("parked-\(safeComponent(previousID))")
                try moveSessionItems(from: outgoing, to: live, fileManager: fm)
            } else if journal.previousFingerprint != signedOutFingerprint {
                throw ClaudeDesktopSessionError.recoveryFailed
            }
        }
        try syncDirectory(live)
        if fm.fileExists(atPath: parkedRoot.path) { try syncDirectory(parkedRoot) }
    }

    private static func moveSessionItems(from source: URL, to destination: URL, fileManager fm: FileManager) throws {
        // Validate every source and destination before the first rename. In
        // particular, reject nested symlinks so securing the parked tree can
        // never follow a link out of the account folder.
        var moves: [(source: URL, destination: URL)] = []
        for item in itemPaths {
            let from = source.appendingPathComponent(item)
            guard pathExistsIncludingLinks(from) else { continue }
            try validateSessionTree(at: from, fileManager: fm)
            let to = destination.appendingPathComponent(item)
            if pathExistsIncludingLinks(to) { throw ClaudeDesktopSessionError.recoveryFailed }
            moves.append((from, to))
        }
        for (from, to) in moves {
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.moveItem(at: from, to: to)
        }
    }

    private static func validateSessionTree(at root: URL, fileManager fm: FileManager) throws {
        func attributes(_ url: URL) throws -> stat {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw ClaudeDesktopSessionError.unreadableSession }
            guard (info.st_mode & S_IFMT) != S_IFLNK else { throw ClaudeDesktopSessionError.linkedFolder }
            return info
        }

        let rootAttributes = try attributes(root)
        guard (rootAttributes.st_mode & S_IFMT) == S_IFDIR else { return }
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: []) else {
            throw ClaudeDesktopSessionError.unreadableSession
        }
        for case let item as URL in enumerator { _ = try attributes(item) }
    }

    private static func pathExistsIncludingLinks(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static var itemPaths: [String] {
        let suffixes = ["-journal", "-wal", "-shm", ".journal"]
        var paths = sessionItems
        for item in sessionItems {
            paths.append(contentsOf: suffixes.map { item + $0 })
        }
        return Array(Set(paths)).sorted()
    }

    private static func safeComponent(_ value: String) -> String {
        let cleaned = value.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) ? String($0) : "_" }.joined()
        return cleaned.isEmpty ? "account" : String(cleaned.prefix(80))
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw ClaudeDesktopSessionError.syncFailed }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw ClaudeDesktopSessionError.syncFailed }
    }

    private static func secureTree(at root: URL, fileManager fm: FileManager) throws {
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            throw ClaudeDesktopSessionError.unreadableSession
        }
        var directories = [root]
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true { directories.append(item) }
            else { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: item.path) }
        }
        for directory in directories.reversed() { try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
    }

    private static func isOwnedByCurrentUser(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_uid == getuid()
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }
}

private final class SendableFileManager: @unchecked Sendable {
    let value: FileManager
    init(_ value: FileManager) { self.value = value }
}

enum ClaudeDesktopSessionError: LocalizedError, Equatable {
    case appRunning, appResetPending, thirdPartyDeployment, missingDataFolder, linkedFolder, differentVolume, unidentified, unreadableSession
    case unsettledCookieStore, unsupportedCookieFormat, parkAlreadyExists, accountMissing, recoveryFailed, syncFailed

    var errorDescription: String? {
        switch self {
        case .appRunning: String(localized: "Quit Claude Desktop before switching accounts.")
        case .appResetPending: String(localized: "Claude Desktop is resetting its data. Finish or cancel the reset before switching.")
        case .thirdPartyDeployment: String(localized: "Claude Desktop uses a third-party deployment; its session was left untouched.")
        case .missingDataFolder: String(localized: "Claude Desktop data folder was not found. Open Claude Desktop and sign in first.")
        case .linkedFolder: String(localized: "Claude Desktop data folder is a symbolic link; no files were moved.")
        case .differentVolume: String(localized: "Claude Desktop session storage is on another volume; no files were moved.")
        case .unidentified: String(localized: "Claude Desktop login could not be identified safely.")
        case .unreadableSession: String(localized: "Claude Desktop session data could not be read.")
        case .unsettledCookieStore: String(localized: "Claude Desktop cookie storage has pending changes; reopen and quit Claude before switching.")
        case .unsupportedCookieFormat: String(localized: "Claude Desktop uses an unsupported session-cookie format.")
        case .parkAlreadyExists: String(localized: "A Claude Desktop session folder already exists for this account.")
        case .accountMissing: String(localized: "The selected Claude Desktop session folder is missing.")
        case .recoveryFailed: String(localized: "An interrupted Claude Desktop account change needs manual recovery.")
        case .syncFailed: String(localized: "Claude Desktop session changes could not be written safely.")
        }
    }
}
