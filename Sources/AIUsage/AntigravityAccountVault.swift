import Foundation
import Security
import CryptoKit

struct AntigravityAccount: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var identity: String
    var addedAt: Date

    var displayName: String {
        AntigravityCredentials.emailOnlyIdentity(identity)
            ?? NSLocalizedString("Antigravity account", comment: "")
    }
}

struct AntigravityStoredCredentialSelection: Sendable {
    let data: Data?
}

enum AntigravityAccountVault {
    static let accountsDefaultsKey = "antigravity.accounts"
    static let activeDefaultsKey = "antigravity.activeAccountID"
    private static let keychainService = "com.local.aiusage.antigravity.accounts"

    static func managedSessionAdapter(
        indexURL: URL,
        defaults: UserDefaults = .standard,
        removeCredential: @escaping @Sendable (String) throws -> Void = AntigravityAccountVault.deleteCredentialData
    ) -> DurableAccountSessionManager {
        let defaultsBox = SendableDefaults(defaults)
        return DurableAccountSessionManager(
            tool: .antigravity,
            indexURL: indexURL,
            identify: {
                let home = FileManager.default.homeDirectoryForCurrentUser
                let cliData = try? Data(contentsOf: home.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token"))
                guard let data = preferredLiveData(defaults: defaultsBox.value, cliData: cliData),
                      let credentials = AntigravityCredentials.decode(data) else {
                    throw AccountSessionError.unidentified
                }
                let reference = activeCredentialReference(defaults: defaultsBox.value) ?? "live"
                let fingerprint = SHA256.hash(data: Data((credentials.identityLabel ?? data.base64EncodedString()).utf8))
                    .map { String(format: "%02x", $0) }.joined()
                return (reference, fingerprint, credentials.identityLabel)
            },
            stage: { source, _ in
                if source != "live" {
                    guard credentialData(id: source) != nil else { throw AccountSessionError.unidentified }
                    return source
                }
                guard let data = liveCredentialData(defaults: defaultsBox.value), !data.isEmpty else {
                    throw AccountSessionError.unidentified
                }
                let id = UUID().uuidString.lowercased()
                try saveCredentialData(data, id: id)
                defaultsBox.value.set(id, forKey: activeDefaultsKey)
                return id
            },
            activate: { reference in
                guard reference == "live" || credentialData(id: reference) != nil else { throw AccountSessionError.accountMissing }
                if reference == "live" { defaultsBox.value.removeObject(forKey: activeDefaultsKey) }
                else { defaultsBox.value.set(reference, forKey: activeDefaultsKey) }
            },
            removeAccountResource: { account, isInUse in
                try removeCredential(account.sessionReference)
                if isInUse || defaultsBox.value.string(forKey: activeDefaultsKey) == account.id {
                    defaultsBox.value.removeObject(forKey: activeDefaultsKey)
                }
            }
        )
    }

    static func migrationRecords(defaults: UserDefaults = .standard) throws -> ([ManagedAccountRecord], String?) {
        let accounts = accounts(defaults: defaults)
        let activeID = activeAccountID(defaults: defaults)
        var credentialIDs = Set<String>()
        for account in accounts {
            if try credentialDataForMigration(id: account.id) != nil { credentialIDs.insert(account.id) }
        }
        return migrateAntigravityAccounts(accounts, availableCredentialIDs: credentialIDs, activeID: activeID)
    }

    private static func preferredLiveData(defaults: UserDefaults, cliData: Data?) -> Data? {
        if let id = activeAccountID(defaults: defaults), let data = credentialData(id: id) { return data }
        return AntigravityCredentials.preferredData(keychainData: AntigravityCredentials.keychainData(), cliData: cliData)
    }

    private static func liveCredentialData(defaults: UserDefaults) -> Data? {
        guard let id = activeCredentialReference(defaults: defaults) else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let cliData = try? Data(contentsOf: home.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token"))
            return AntigravityCredentials.preferredData(keychainData: AntigravityCredentials.keychainData(), cliData: cliData)
        }
        return credentialData(id: id)
    }

    private static func activeCredentialReference(defaults: UserDefaults) -> String? {
        activeAccountID(defaults: defaults)
    }

    static func accounts(defaults: UserDefaults = .standard) -> [AntigravityAccount] {
        guard let data = defaults.data(forKey: accountsDefaultsKey),
              let accounts = try? JSONDecoder().decode([AntigravityAccount].self, from: data) else { return [] }
        return accounts
    }

    static func activeAccountID(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: activeDefaultsKey)
    }

    static func activeCredential(defaults: UserDefaults = .standard) -> AntigravityStoredCredentialSelection? {
        guard let id = activeAccountID(defaults: defaults) else { return nil }
        return AntigravityStoredCredentialSelection(data: credentialData(id: id))
    }

    @discardableResult
    static func save(_ data: Data, identity: String, defaults: UserDefaults = .standard) throws -> AntigravityAccount {
        var entries = accounts(defaults: defaults)
        let matchingIndex = identity.isEmpty ? nil : entries.firstIndex { $0.identity.caseInsensitiveCompare(identity) == .orderedSame }
        let account = matchingIndex.map { entries[$0] } ?? AntigravityAccount(
            id: UUID().uuidString.lowercased(),
            identity: identity,
            addedAt: .now
        )
        try saveCredentialData(data, id: account.id)
        if let matchingIndex {
            entries[matchingIndex].identity = identity
        } else {
            entries.append(account)
        }
        persist(entries, defaults: defaults)
        defaults.set(account.id, forKey: activeDefaultsKey)
        return account
    }

    static func select(_ id: String?, defaults: UserDefaults = .standard) {
        guard let id else {
            defaults.removeObject(forKey: activeDefaultsKey)
            return
        }
        guard accounts(defaults: defaults).contains(where: { $0.id == id }) else { return }
        defaults.set(id, forKey: activeDefaultsKey)
    }

    static func remove(_ id: String, defaults: UserDefaults = .standard) throws {
        var entries = accounts(defaults: defaults)
        guard entries.contains(where: { $0.id == id }) else { return }
        try deleteCredentialData(id: id)
        entries.removeAll { $0.id == id }
        persist(entries, defaults: defaults)
        if activeAccountID(defaults: defaults) == id {
            defaults.removeObject(forKey: activeDefaultsKey)
        }
    }

    private static func persist(_ accounts: [AntigravityAccount], defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: accountsDefaultsKey)
        }
    }

    static func credentialData(id: String) -> Data? {
        try? credentialDataForMigration(id: id)
    }

    private static func credentialDataForMigration(id: String) throws -> Data? {
        do {
            return try AIUsageCredentialVault.data(for: credentialKey(id)) {
                try legacyCredentialData(id: id)
            } deletingLegacy: {
                try AIUsageCredentialVault.deleteLegacyData(service: keychainService, account: id)
            }
        } catch let CredentialVaultError.keychain(status) {
            throw AntigravityAccountVaultError.keychain(status)
        }
    }

    private static func legacyCredentialData(id: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AntigravityAccountVaultError.keychain(status) }
        guard let data = result as? Data else { throw AntigravityAccountVaultError.keychain(errSecDecode) }
        return data
    }

    static func saveCredentialData(_ data: Data, id: String) throws {
        do {
            try AIUsageCredentialVault.set(data, for: credentialKey(id))
        } catch let CredentialVaultError.keychain(status) {
            throw AntigravityAccountVaultError.keychain(status)
        }
    }

    static func deleteCredentialData(id: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id
        ]
        do {
            try AIUsageCredentialVault.remove(credentialKey(id))
        } catch let CredentialVaultError.keychain(status) {
            throw AntigravityAccountVaultError.keychain(status)
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AntigravityAccountVaultError.keychain(status)
        }
    }

    private static func credentialKey(_ id: String) -> String { "antigravity/account/\(id)" }
}

func migrateAntigravityAccounts(_ accounts: [AntigravityAccount], availableCredentialIDs: Set<String>, activeID: String?) -> ([ManagedAccountRecord], String?) {
    let records = accounts.compactMap { account -> ManagedAccountRecord? in
        guard availableCredentialIDs.contains(account.id) else { return nil }
        let fingerprint = SHA256.hash(data: Data(account.identity.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        return ManagedAccountRecord(id: account.id, label: account.identity, tool: .antigravity,
            sessionReference: account.id, identityFingerprint: fingerprint, registeredAt: account.addedAt)
    }
    return (records, records.contains(where: { $0.id == activeID }) ? activeID : nil)
}

private final class SendableDefaults: @unchecked Sendable {
    let value: UserDefaults
    init(_ value: UserDefaults) { self.value = value }
}

enum AntigravityAccountVaultError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            String(format: NSLocalizedString("Could not access the Antigravity account in Keychain (error %ld).", comment: ""), status)
        }
    }
}
