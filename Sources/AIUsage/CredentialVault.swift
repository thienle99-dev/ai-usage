import Foundation
import Security

/// Stores credentials owned by AIUsage in one Keychain item. Legacy
/// provider-specific items are removed after their values are verified here.
enum AIUsageCredentialVault {
    private static let service = "com.aiusagemonitor.shared-credentials"
    private static let account = "provider-credentials-v1"
    private static let lock = CredentialVaultLock()

    static func data(
        for key: String,
        migrating legacyValue: () throws -> Data? = { nil },
        deletingLegacy: () throws -> Void = {}
    ) throws -> Data? {
        try withLock {
            var values = try readValues()
            if let value = values[key] {
                try? deletingLegacy()
                return value
            }
            guard let legacy = try legacyValue() else { return nil }
            values[key] = legacy
            do {
                try writeValues(values)
                guard try readValues()[key] == legacy else { return legacy }
            } catch {
                return legacy
            }
            try? deletingLegacy()
            return legacy
        }
    }

    static func set(_ data: Data, for key: String) throws {
        try withLock {
            var values = try readValues()
            values[key] = data
            try writeValues(values)
        }
    }

    static func remove(_ key: String) throws {
        try withLock {
            var values = try readValues()
            values.removeValue(forKey: key)
            try writeValues(values)
        }
    }

    static func legacyData(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CredentialVaultError.keychain(status)
        }
        return data
    }

    static func deleteLegacyData(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialVaultError.keychain(status)
        }
    }

    private static func readValues() throws -> [String: Data] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(returnData: true) as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CredentialVaultError.keychain(status)
        }
        guard let values = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data] else {
            throw CredentialVaultError.keychain(errSecDecode)
        }
        return values
    }

    private static func writeValues(_ values: [String: Data]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        let status = SecItemUpdate(query(returnData: false) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query(returnData: false)
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addition as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                let retryStatus = SecItemUpdate(query(returnData: false) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
                guard retryStatus == errSecSuccess else { throw CredentialVaultError.keychain(retryStatus) }
            } else if addStatus != errSecSuccess {
                throw CredentialVaultError.keychain(addStatus)
            }
        } else if status != errSecSuccess {
            throw CredentialVaultError.keychain(status)
        }
    }

    private static func query(returnData: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if returnData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }

    private static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.value.lock()
        defer { lock.value.unlock() }
        return try body()
    }
}

private final class CredentialVaultLock: @unchecked Sendable {
    let value = NSRecursiveLock()
}

enum CredentialVaultError: Error {
    case keychain(OSStatus)
}
