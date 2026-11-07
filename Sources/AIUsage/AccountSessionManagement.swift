import Foundation
import Darwin
import CryptoKit

enum ManagedAccountTool: String, Codable, CaseIterable, Sendable { case codex, claudeCode, antigravity, claudeDesktop }

struct ManagedAccountRecord: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var label: String
    var tool: ManagedAccountTool
    var sessionReference: String
    var identityFingerprint: String
    var registeredAt: Date
}

/// `identify` returns an opaque reference and a stable, non-secret identity.
/// `stage` durably preserves the outgoing session using the tool's safe storage
/// operation. Copy-backed adapters retain the live session; move-backed adapters
/// may leave the app signed out. `activate` installs a preserved reference.
protocol AccountSessionManaging: Sendable {
    func registerCurrentAccount(label: String?) throws -> ManagedAccountRecord
    func stashActiveSession() throws -> ManagedAccountRecord?
    func activateAccount(_ id: String) throws
}

struct AccountSessionIndex: Codable, Equatable, Sendable {
    var schema = 1
    var accounts: [ManagedAccountRecord] = []
    var inUse: [ManagedAccountTool: String] = [:]
    var journal: AccountSessionJournal?
    var completedMigrations: Set<String> = []

    private enum CodingKeys: String, CodingKey { case schema, accounts, inUse, journal, completedMigrations }

    init(schema: Int = 1, accounts: [ManagedAccountRecord] = [], inUse: [ManagedAccountTool: String] = [:], journal: AccountSessionJournal? = nil, completedMigrations: Set<String> = []) {
        self.schema = schema; self.accounts = accounts; self.inUse = inUse; self.journal = journal; self.completedMigrations = completedMigrations
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        accounts = try values.decodeIfPresent([ManagedAccountRecord].self, forKey: .accounts) ?? []
        inUse = try values.decodeIfPresent([ManagedAccountTool: String].self, forKey: .inUse) ?? [:]
        journal = try values.decodeIfPresent(AccountSessionJournal.self, forKey: .journal)
        completedMigrations = try values.decodeIfPresent(Set<String>.self, forKey: .completedMigrations) ?? []
    }
}

struct AccountSessionJournal: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Sendable { case stash, activate, importSession, removeAccount }
    var operation: Operation
    var tool: ManagedAccountTool
    var accountID: String
    var previousID: String?
    var previousFingerprint: String
    var targetFingerprint: String
    var stagedReference: String?
    var startedAt: Date
}

final class DurableAccountSessionManager: AccountSessionManaging, @unchecked Sendable {
    typealias Identify = @Sendable () throws -> (reference: String, fingerprint: String, label: String?)
    typealias Stage = @Sendable (_ source: String, _ accountID: String) throws -> String
    typealias Activate = @Sendable (_ reference: String) throws -> Void
    typealias IsSafeToChange = @Sendable () throws -> Void
    typealias ImportIdentityMatches = @Sendable (_ existing: ManagedAccountRecord, _ fingerprint: String, _ label: String?) -> Bool
    typealias RemoveMergedAccount = @Sendable (_ account: ManagedAccountRecord) -> Void
    typealias RemoveAccountResource = @Sendable (_ account: ManagedAccountRecord, _ isInUse: Bool) throws -> Void
    typealias IndexWriter = @Sendable (_ data: Data, _ url: URL, _ fileManager: FileManager) throws -> Void

    private let tool: ManagedAccountTool
    private let indexURL: URL
    private let operationLockURL: URL
    private let identify: Identify
    private let stage: Stage
    private let activate: Activate
    private let safeToChange: IsSafeToChange
    private let movesSessions: Bool
    private let recoverInterrupted: @Sendable (AccountSessionJournal) throws -> Void
    private let importIdentityMatches: ImportIdentityMatches
    private let removeMergedAccount: RemoveMergedAccount
    private let removeAccountResource: RemoveAccountResource
    private let indexWriter: IndexWriter
    private let fileManager: FileManager

    init(tool: ManagedAccountTool, indexURL: URL, identify: @escaping Identify,
         stage: @escaping Stage, activate: @escaping Activate,
         safeToChange: @escaping IsSafeToChange = {}, movesSessions: Bool = false,
         recoverInterrupted: @escaping @Sendable (AccountSessionJournal) throws -> Void = { _ in },
         importIdentityMatches: @escaping ImportIdentityMatches = { existing, fingerprint, _ in existing.identityFingerprint == fingerprint },
         removeMergedAccount: @escaping RemoveMergedAccount = { _ in },
         removeAccountResource: @escaping RemoveAccountResource = { _, _ in },
         indexWriter: @escaping IndexWriter = { data, url, fileManager in
             try data.write(to: url, options: .atomic)
             try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
         },
         fileManager: FileManager = .default) {
        self.tool = tool; self.indexURL = indexURL
        self.operationLockURL = indexURL.appendingPathExtension("\(tool.rawValue).operation-lock")
        self.identify = identify
        self.stage = stage; self.activate = activate; self.safeToChange = safeToChange
        self.movesSessions = movesSessions; self.recoverInterrupted = recoverInterrupted
        self.importIdentityMatches = importIdentityMatches; self.removeMergedAccount = removeMergedAccount
        self.removeAccountResource = removeAccountResource
        self.indexWriter = indexWriter
        self.fileManager = fileManager
    }

    func registerCurrentAccount(label: String? = nil) throws -> ManagedAccountRecord {
        try withIndex { index in
            try settle(&index)
            if movesSessions { try safeToChange() }
            let live = try identified()
            if tool == .claudeDesktop && live.fingerprint == ClaudeDesktopSessionAdapter.signedOutFingerprint {
                throw AccountSessionError.unidentified
            }
            if let existing = index.accounts.first(where: { $0.tool == tool && $0.identityFingerprint == live.fingerprint }) {
                index.inUse[tool] = existing.id
                return existing
            }
            let record = ManagedAccountRecord(id: UUID().uuidString.lowercased(), label: label ?? live.label ?? "Account",
                tool: tool, sessionReference: live.reference, identityFingerprint: live.fingerprint, registeredAt: .now)
            index.accounts.append(record)
            index.inUse[tool] = record.id
            return record
        }
    }

    func stashActiveSession() throws -> ManagedAccountRecord? {
        try stashActiveSession(label: nil)
    }

    func stashActiveSession(label: String?) throws -> ManagedAccountRecord? {
        try withIndex { index in
            try settle(&index)
            if movesSessions { try safeToChange() }
            let live = try identified()
            if tool == .claudeDesktop && live.fingerprint == ClaudeDesktopSessionAdapter.signedOutFingerprint {
                throw AccountSessionError.unidentified
            }
            let existing = index.accounts.first(where: { $0.tool == tool && $0.identityFingerprint == live.fingerprint })
            var record = existing ?? ManagedAccountRecord(id: UUID().uuidString.lowercased(), label: live.label ?? "Account",
                tool: tool, sessionReference: live.reference, identityFingerprint: live.fingerprint, registeredAt: .now)
            if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                record.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            index.journal = AccountSessionJournal(operation: .stash, tool: tool, accountID: record.id,
                previousID: index.inUse[tool], previousFingerprint: live.fingerprint, targetFingerprint: live.fingerprint,
                stagedReference: nil, startedAt: .now)
            try persist(index) // Journal is durable before the adapter can stage anything.
            let spare = try stage(live.reference, record.id)
            let storedReference = spare
            if let pos = index.accounts.firstIndex(where: { $0.id == record.id }) {
                index.accounts[pos].sessionReference = storedReference
                index.accounts[pos].label = record.label
            }
            else { var staged = record; staged.sessionReference = storedReference; index.accounts.append(staged) }
            index.inUse[tool] = movesSessions ? nil : record.id
            index.journal = nil
            try persist(index) // Spare/index are durable before clearing the journal.
            return index.accounts.first(where: { $0.id == record.id })
        }
    }

    /// Imports an independently authenticated session without changing the selected account.
    /// The caller supplies a stable, non-secret identity obtained from the tool's account metadata.
    @discardableResult
    func importSession(reference: String, fingerprint: String, label: String?) throws -> ManagedAccountRecord {
        guard !reference.isEmpty, !fingerprint.isEmpty else { throw AccountSessionError.unidentified }
        return try withIndex { index in
            try settle(&index)
            let matchingPositions = index.accounts.indices.filter { position in
                let existing = index.accounts[position]
                return existing.tool == tool && importIdentityMatches(existing, fingerprint, label)
            }
            if !matchingPositions.isEmpty {
                let activeID = index.inUse[tool]
                let keeperPosition = matchingPositions.first(where: { index.accounts[$0].id == activeID }) ?? matchingPositions[0]
                let existing = index.accounts[keeperPosition]
                let duplicateRecords = matchingPositions
                    .filter { $0 != keeperPosition }
                    .map { index.accounts[$0] }
                let duplicateIDs = Set(duplicateRecords.map(\.id))
                index.journal = AccountSessionJournal(
                    operation: .importSession, tool: tool, accountID: existing.id,
                    previousID: index.inUse[tool], previousFingerprint: "", targetFingerprint: fingerprint,
                    stagedReference: nil, startedAt: .now
                )
                try persist(index)
                let savedReference = try stage(reference, existing.id)
                var updated = existing
                updated.sessionReference = savedReference
                updated.identityFingerprint = fingerprint
                if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    updated.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                index.accounts[keeperPosition] = updated
                index.accounts.removeAll { duplicateIDs.contains($0.id) }
                if let inUseID = index.inUse[tool], duplicateIDs.contains(inUseID) {
                    index.inUse[tool] = updated.id
                }
                index.journal = nil
                try persist(index)
                for duplicate in duplicateRecords { removeMergedAccount(duplicate) }
                return updated
            }

            let record = ManagedAccountRecord(
                id: stableImportedID(fingerprint), label: label ?? "Account", tool: tool,
                sessionReference: reference, identityFingerprint: fingerprint, registeredAt: .now
            )
            index.journal = AccountSessionJournal(
                operation: .importSession, tool: tool, accountID: record.id,
                previousID: index.inUse[tool], previousFingerprint: "", targetFingerprint: fingerprint,
                stagedReference: nil, startedAt: .now
            )
            try persist(index)
            let savedReference = try stage(reference, record.id)
            var saved = record
            saved.sessionReference = savedReference
            index.accounts.append(saved)
            index.journal = nil
            try persist(index)
            return saved
        }
    }

    func activateAccount(_ id: String) throws {
        try withIndex { index in
            try settle(&index)
            try safeToChange()
            guard let selected = index.accounts.first(where: { $0.id == id && $0.tool == tool }) else { throw AccountSessionError.accountMissing }
            let live = try identified()
            if live.fingerprint == selected.identityFingerprint {
                if movesSessions, live.reference != selected.sessionReference {
                    throw AccountSessionError.recoveryRequired("the same login exists in both Claude's live folder and its parked folder")
                }
                index.inUse[tool] = selected.id
                return
            }
            let current = index.accounts.first(where: { $0.tool == tool && $0.identityFingerprint == live.fingerprint })
            let isSignedOutDesktop = movesSessions && tool == .claudeDesktop && live.fingerprint == ClaudeDesktopSessionAdapter.signedOutFingerprint
            if tool == .claudeDesktop && !isSignedOutDesktop && current == nil {
                throw AccountSessionError.unidentified
            }
            let indexedCurrent = index.accounts.first(where: {
                $0.id == index.inUse[tool] && $0.identityFingerprint == live.fingerprint
            })
            let previousID = current?.id ?? indexedCurrent?.id ?? (isSignedOutDesktop ? nil : UUID().uuidString.lowercased())
            index.journal = AccountSessionJournal(operation: .activate, tool: tool, accountID: selected.id,
                previousID: previousID, previousFingerprint: live.fingerprint, targetFingerprint: selected.identityFingerprint,
                stagedReference: nil, startedAt: .now)
            try persist(index) // Intent is durable before creating the outgoing spare.
            if !isSignedOutDesktop {
                guard let previousID else { throw AccountSessionError.recoveryRequired("the outgoing session could not be identified") }
                let spare = try stage(live.reference, previousID)
                if let current, let pos = index.accounts.firstIndex(where: { $0.id == current.id }) {
                    index.accounts[pos].sessionReference = spare
                } else {
                    index.accounts.append(ManagedAccountRecord(id: previousID, label: live.label ?? "Account", tool: tool,
                        sessionReference: spare, identityFingerprint: live.fingerprint, registeredAt: .now))
                }
                index.journal?.stagedReference = spare
                try persist(index) // Outgoing session is durably parked before installing the selected one.
            } else {
                index.journal?.stagedReference = "signed-out"
                try persist(index)
            }
            try activate(selected.sessionReference)
            if movesSessions, let selectedPosition = index.accounts.firstIndex(where: { $0.id == selected.id }) {
                index.accounts[selectedPosition].sessionReference = try identified().reference
            }
            index.inUse[tool] = selected.id
            index.journal = nil
            try persist(index) // Final index commit precedes journal removal in that same atomic write.
        }
    }

    func currentIndex() throws -> AccountSessionIndex {
        let directory = indexURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = try AdvisoryFileLock(url: indexURL.appendingPathExtension("lock"))
        try lock.acquire(); defer { lock.release() }
        guard fileManager.fileExists(atPath: indexURL.path) else { return AccountSessionIndex() }
        return try JSONDecoder().decode(AccountSessionIndex.self, from: Data(contentsOf: indexURL))
    }

    func acquireOperationLock() throws -> AccountSessionOperationLease {
        try AccountSessionOperationLease(url: operationLockURL)
    }

    func acquireAccountLock(_ accountID: String) throws -> AccountSessionOperationLease {
        try AccountSessionOperationLease(url: operationLockURL.appendingPathExtension("account-\(accountID)"))
    }

    func removeAccount(_ id: String) throws {
        try withIndex { index in
            try settle(&index)
            guard index.accounts.contains(where: { $0.id == id && $0.tool == tool }) else { return }
            index.journal = AccountSessionJournal(
                operation: .removeAccount, tool: tool, accountID: id,
                previousID: index.inUse[tool], previousFingerprint: "", targetFingerprint: "",
                stagedReference: nil, startedAt: .now
            )
        }
        // The deletion intent is durable before any credential or session resource is removed.
        // settle() retries cleanup after an error or process interruption.
        try withIndex { index in try settle(&index) }
    }

    func markExternalSessionInUse() throws {
        try withIndex { index in
            try settle(&index)
            index.inUse[tool] = nil
        }
    }

    /// Imports previously saved accounts exactly once. No adapter callbacks or
    /// filesystem mutations are involved in this index-only transaction.
    @discardableResult
    func importAccountsOnce(_ records: [ManagedAccountRecord], migrationID: String, activeAccountID: String? = nil) throws -> Bool {
        let operationLease = try acquireOperationLock()
        defer { withExtendedLifetime(operationLease) {} }
        let directory = indexURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let lock = try AdvisoryFileLock(url: indexURL.appendingPathExtension("lock"))
        try lock.acquire(); defer { lock.release() }
        var index: AccountSessionIndex
        if fileManager.fileExists(atPath: indexURL.path) {
            index = try JSONDecoder().decode(AccountSessionIndex.self, from: Data(contentsOf: indexURL))
        } else { index = AccountSessionIndex() }
        try settle(&index)
        if index.completedMigrations.contains(migrationID) { return false }
        for record in records where !index.accounts.contains(where: { $0.sessionReference == record.sessionReference }) {
            index.accounts.append(record)
        }
        if let activeAccountID,
           let activeRecord = records.first(where: { $0.id == activeAccountID }),
           let storedRecord = index.accounts.first(where: { $0.sessionReference == activeRecord.sessionReference && $0.tool == tool }) {
            index.inUse[tool] = storedRecord.id
        }
        index.completedMigrations.insert(migrationID)
        try persist(index)
        return true
    }

    private func identified() throws -> (reference: String, fingerprint: String, label: String?) {
        let live = try identify()
        guard !live.fingerprint.isEmpty else { throw AccountSessionError.unidentified }
        return live
    }

    private func stableImportedID(_ fingerprint: String) -> String {
        let digest = SHA256.hash(data: Data((tool.rawValue + ":" + fingerprint).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "\(tool.rawValue)-\(digest.prefix(24))"
    }

    /// Recovery decision table (always consult live identity): previous fingerprint =>
    /// retain/restore previous in-use id and clear intent; target fingerprint => commit
    /// target as in-use and clear intent; anything else or unidentified => throw without
    /// changing the index. This works because staging is durable before activation.
    private func settle(_ index: inout AccountSessionIndex) throws {
        guard let journal = index.journal else { return }
        if journal.operation == .removeAccount {
            guard journal.tool == tool else {
                throw AccountSessionError.recoveryRequired("another provider's account deletion must be recovered first")
            }
            if let position = index.accounts.firstIndex(where: { $0.id == journal.accountID && $0.tool == tool }) {
                try removeAccountResource(index.accounts[position], index.inUse[tool] == journal.accountID)
                index.accounts.remove(at: position)
                if index.inUse[tool] == journal.accountID { index.inUse[tool] = nil }
            }
            index.journal = nil
            return
        }
        if journal.operation == .importSession {
            // Imports never touch the live CLI session or its in-use selection. A
            // pending sign-in draft owns retry/cleanup if the process was interrupted.
            index.journal = nil
            return
        }
        if movesSessions { try safeToChange() }
        try recoverInterrupted(journal)
        let live = try identified()
        if live.fingerprint == journal.previousFingerprint {
            if let previousID = journal.previousID { index.inUse[tool] = previousID }
            index.journal = nil
        } else if live.fingerprint == journal.targetFingerprint {
            index.inUse[tool] = journal.accountID
            index.journal = nil
        } else {
            throw AccountSessionError.recoveryRequired("live identity does not match either journal endpoint")
        }
    }

    private func withIndex<T>(_ body: (inout AccountSessionIndex) throws -> T) throws -> T {
        let operationLease = try acquireOperationLock()
        defer { withExtendedLifetime(operationLease) {} }
        let directory = indexURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let lock = try AdvisoryFileLock(url: indexURL.appendingPathExtension("lock"))
        try lock.acquire(); defer { lock.release() }
        var index: AccountSessionIndex
        if fileManager.fileExists(atPath: indexURL.path) {
            index = try JSONDecoder().decode(AccountSessionIndex.self, from: Data(contentsOf: indexURL))
        } else { index = AccountSessionIndex() }
        let result = try body(&index)
        try persist(index)
        return result
    }

    private func persist(_ index: AccountSessionIndex) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try indexWriter(encoder.encode(index), indexURL, fileManager)
    }
}

final class AccountSessionOperationLease: @unchecked Sendable {
    private var descriptor: Int32 = -1

    init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AccountSessionError.lockFailed }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            descriptor = -1
            throw AccountSessionError.lockFailed
        }
    }

    deinit {
        if descriptor >= 0 {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }
}

private final class AdvisoryFileLock {
    private let url: URL
    private var descriptor: Int32 = -1
    init(url: URL) throws {
        self.url = url
        descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AccountSessionError.lockFailed }
    }
    func acquire() throws {
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw AccountSessionError.lockFailed }
    }
    func release() { if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 } }
    deinit { release() }
}

enum AccountSessionError: LocalizedError, Equatable {
    case unidentified, accountMissing, lockFailed, recoveryRequired(String)
    var errorDescription: String? {
        switch self {
        case .unidentified: String(localized: "The active account could not be identified safely.")
        case .accountMissing: String(localized: "The selected account is no longer registered.")
        case .lockFailed: String(localized: "Could not acquire the account storage lock.")
        case .recoveryRequired: String(localized: "An interrupted account change needs recovery before switching.")
        }
    }
}
