import Foundation

struct CodexMigrationSkip: Equatable, Sendable {
    var path: String
    var reason: Reason

    enum Reason: String, Equatable, Sendable {
        case folderMissing, notDirectory, missingAuthFile, missingAccountID, ambiguousIdentity
    }
}

struct CodexMigrationResult: Equatable, Sendable {
    var records: [ManagedAccountRecord]
    var activeAccountID: String?
    var skipped: [CodexMigrationSkip]
}

/// Converts the old saved-home preferences into index records. This function
/// only checks paths and auth.json presence; it never opens credential files.
func migrateCodexHomes(_ homes: [CodexHome], activeHomePath: String?, now: Date = .now,
                       fileManager: FileManager = .default) -> CodexMigrationResult {
    var records: [ManagedAccountRecord] = []
    var skipped: [CodexMigrationSkip] = []
    var fingerprints = Set<String>()
    var activeID: String?

    for home in homes {
        let url = URL(fileURLWithPath: home.path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: home.path, isDirectory: &isDirectory) else {
            skipped.append(CodexMigrationSkip(path: home.path, reason: .folderMissing)); continue
        }
        guard isDirectory.boolValue else {
            skipped.append(CodexMigrationSkip(path: home.path, reason: .notDirectory)); continue
        }
        guard fileManager.fileExists(atPath: url.appendingPathComponent("auth.json").path) else {
            skipped.append(CodexMigrationSkip(path: home.path, reason: .missingAuthFile)); continue
        }
        guard let fingerprint = home.lastSeenAccountID,
              !fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            skipped.append(CodexMigrationSkip(path: home.path, reason: .missingAccountID)); continue
        }
        guard fingerprints.insert(fingerprint).inserted else {
            skipped.append(CodexMigrationSkip(path: home.path, reason: .ambiguousIdentity)); continue
        }
        let id = UUID().uuidString.lowercased()
        let record = ManagedAccountRecord(id: id,
            label: home.lastSeenEmail ?? home.lastSeenAccount ?? url.lastPathComponent,
            tool: .codex, sessionReference: home.path, identityFingerprint: fingerprint,
            registeredAt: home.lastSeenAt ?? now)
        records.append(record)
        if home.path == activeHomePath { activeID = id }
    }
    return CodexMigrationResult(records: records, activeAccountID: activeID, skipped: skipped)
}
