import Foundation
import Security

struct AntigravityAccount: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var identity: String
    var addedAt: Date

    var displayName: String { identity.isEmpty ? NSLocalizedString("Antigravity account", comment: "") : identity }
}

struct AntigravityStoredCredentialSelection: Sendable {
    let data: Data?
}

enum AntigravityAccountVault {
    static let accountsDefaultsKey = "antigravity.accounts"
    static let activeDefaultsKey = "antigravity.activeAccountID"
    private static let keychainService = "com.local.aiusage.antigravity.accounts"

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

    private static func credentialData(id: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func saveCredentialData(_ data: Data, id: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            update.forEach { add[$0.key] = $0.value }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw AntigravityAccountVaultError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw AntigravityAccountVaultError.keychain(status)
        }
    }

    private static func deleteCredentialData(id: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AntigravityAccountVaultError.keychain(status)
        }
    }
}

enum AntigravityAccountVaultError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            String(format: NSLocalizedString("Could not securely store the Antigravity account (Keychain error %ld).", comment: ""), status)
        }
    }
}
