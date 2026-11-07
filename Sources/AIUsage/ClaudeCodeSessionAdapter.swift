import Foundation
import CryptoKit
import Security

/// Keeps parked Claude Code OAuth credentials in Keychain and installs a selected credential
/// into the Keychain entry Claude Code uses for the live configuration directory.
struct ClaudeCodeSessionAdapter {
    let manager: DurableAccountSessionManager

    init(
        configDirectory: URL,
        indexURL: URL,
        credentialStore: any ManagedClaudeCredentialStoring = KeychainManagedClaudeCredentialStore()
    ) {
        let config = configDirectory.standardizedFileURL
        manager = DurableAccountSessionManager(
            tool: .claudeCode,
            indexURL: indexURL,
            identify: {
                let data = try ClaudeCodeCredentialVault.sessionBundle(
                    credential: ClaudeCodeCredentialVault.nativeCredential(configDirectory: config),
                    configDirectory: config
                )
                return (String(data: data, encoding: .utf8) ?? "", Self.fingerprint(data), Self.label(data))
            },
            stage: { source, accountID in
                guard let data = source.data(using: .utf8) else { throw ClaudeCodeSessionError.invalidCredential }
                try credentialStore.save(data, accountID: accountID)
                guard try credentialStore.load(accountID: accountID) == data else {
                    throw ClaudeCodeSessionError.managedCredentialVerificationFailed
                }
                return ClaudeCodeCredentialVault.reference(accountID)
            },
            activate: { reference in
                guard let accountID = ClaudeCodeCredentialVault.accountID(from: reference) else {
                    throw ClaudeCodeSessionError.invalidReference
                }
                let data = try credentialStore.load(accountID: accountID)
                try ClaudeCodeCredentialVault.installLive(data, configDirectory: config)
                try ClaudeCodeCredentialVault.updateAccountMetadata(data, configDirectory: config)
            },
            recoverInterrupted: { journal in
                try Self.recoverInterruptedActivation(journal, configDirectory: config)
            },
            importIdentityMatches: { existing, fingerprint, label in
                existing.identityFingerprint == fingerprint || Self.sameEmail(existing.label, label)
            },
            removeMergedAccount: { account in
                guard let accountID = ClaudeCodeCredentialVault.accountID(from: account.sessionReference) else { return }
                try? credentialStore.remove(accountID: accountID)
            },
            removeAccountResource: { account, _ in
                guard let accountID = ClaudeCodeCredentialVault.accountID(from: account.sessionReference) else { return }
                try credentialStore.remove(accountID: accountID)
            }
        )
    }

    static func sameEmail(_ lhs: String, _ rhs: String?) -> Bool {
        guard let rhs,
              let leftEmail = emailPart(lhs),
              let rightEmail = emailPart(rhs) else { return false }
        return leftEmail.caseInsensitiveCompare(rightEmail) == .orderedSame
    }

    private static func emailPart(_ label: String) -> String? {
        let email = label.components(separatedBy: " · ").first?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let email, email.contains("@") else { return nil }
        return email
    }

    private static func recoverInterruptedActivation(_ journal: AccountSessionJournal, configDirectory: URL) throws {
        guard journal.operation == .activate, journal.tool == .claudeCode else { return }
        guard let stagedReference = journal.stagedReference else {
            let live = try ClaudeCodeCredentialVault.nativeCredential(configDirectory: configDirectory)
            let liveBundle = ClaudeCodeCredentialVault.sessionBundle(credential: live, configDirectory: configDirectory)
            guard Self.fingerprint(liveBundle) == journal.previousFingerprint else {
                throw AccountSessionError.recoveryRequired("the previous Claude Code credential was not durably staged")
            }
            return
        }
        guard let previousID = journal.previousID,
              ClaudeCodeCredentialVault.accountID(from: stagedReference) == previousID else {
            throw AccountSessionError.recoveryRequired("the previous Claude Code credential has no recoverable vault entry")
        }

        do {
            let previousCredential = try ClaudeCodeCredentialVault.managedCredential(accountID: previousID)
            try ClaudeCodeCredentialVault.installLive(previousCredential, configDirectory: configDirectory)
            try ClaudeCodeCredentialVault.updateAccountMetadata(previousCredential, configDirectory: configDirectory)
        } catch {
            throw AccountSessionError.recoveryRequired("the previous Claude Code credential could not be restored from Keychain")
        }
    }

    static func fingerprint(_ data: Data) -> String {
        let (credential, metadata) = ClaudeCodeCredentialVault.sessionParts(data)
        let oauth = credential["claudeAiOauth"] as? [String: Any] ?? credential
        let account = metadata["oauthAccount"] as? [String: Any] ?? metadata
        let stable = ["email", "accountEmail", "accountUuid", "accountUUID", "organizationUuid", "organizationUUID", "orgUuid"]
            .compactMap { account[$0] as? String }
        if !stable.isEmpty { return stable.joined(separator: ":") }
        let token = (oauth["accessToken"] as? String) ?? ""
        if let claims = jwtClaims(token) {
            let claimIdentity = ["sub", "account_id", "organization_id", "org_id"].compactMap { claims[$0] as? String }
            if !claimIdentity.isEmpty { return claimIdentity.joined(separator: ":") }
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func label(_ data: Data, fallback: String? = nil) -> String? {
        let (credential, metadata) = ClaudeCodeCredentialVault.sessionParts(data)
        let oauth = credential["claudeAiOauth"] as? [String: Any] ?? credential
        let account = metadata["oauthAccount"] as? [String: Any] ?? metadata
        let storedIdentity = (account["email"] as? String) ?? (account["accountEmail"] as? String)
            ?? (oauth["email"] as? String) ?? (oauth["accountEmail"] as? String)
        let fallbackIdentity = fallback?.components(separatedBy: " · ").first
        let identity = storedIdentity ?? fallbackIdentity
        let subscriptionType = (oauth["subscriptionType"] as? String)
            ?? (account["subscriptionType"] as? String)
            ?? (account["subscription_type"] as? String)
        let rateLimitTier = (oauth["rateLimitTier"] as? String)
            ?? (account["organizationRateLimitTier"] as? String)
            ?? (account["rate_limit_tier"] as? String)
        let plan = UsageParsing.claudePlan(subscriptionType: subscriptionType, rateLimitTier: rateLimitTier)
        guard let identity else { return fallback }
        guard let plan else { return storedIdentity ?? fallback }
        return "\(identity) · \(plan)"
    }

    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while encoded.count.isMultiple(of: 4) == false { encoded.append("=") }
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

enum ClaudeCodeSessionError: LocalizedError {
    case invalidCredential, invalidReference, keychain(OSStatus), missingCredential, credentialChangedDuringRefresh, managedCredentialVerificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidCredential: String(localized: "Claude Code returned an unreadable credential.")
        case .invalidReference: String(localized: "The saved Claude Code credential reference is invalid.")
        case .keychain: String(localized: "Could not access Claude Code credentials in Keychain.")
        case .missingCredential: String(localized: "Sign in to Claude Code before saving this account.")
        case .credentialChangedDuringRefresh: String(localized: "Claude Code credentials changed during quota refresh. Refresh this account before switching.")
        case .managedCredentialVerificationFailed: String(localized: "The saved Claude Code credential could not be verified.")
        }
    }
}

enum ClaudeCodeCredentialVault {
    private static let managedService = "com.aiusagemonitor.claudecode-session"
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    static func reference(_ accountID: String) -> String { "keychain://claude-code/\(accountID)" }

    static func accountID(from reference: String) -> String? {
        let prefix = "keychain://claude-code/"
        guard reference.hasPrefix(prefix) else { return nil }
        return String(reference.dropFirst(prefix.count))
    }

    static func nativeCredential(configDirectory: URL) throws -> Data {
        for service in nativeServices(configDirectory: configDirectory) {
            var query = baseQuery(service: service)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data, !data.isEmpty { return data }
            if status == errSecInteractionNotAllowed || status == errSecAuthFailed { throw ClaudeCodeSessionError.keychain(status) }
        }
        let file = configDirectory.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: file), !data.isEmpty { return data }
        throw ClaudeCodeSessionError.missingCredential
    }

    static func sessionBundle(credential: Data, configDirectory: URL) -> Data {
        let credentialObject = (try? JSONSerialization.jsonObject(with: credential)) as? [String: Any] ?? [:]
        let metadataURL = configDirectory.appendingPathComponent(".claude.json")
        let metadata = (try? Data(contentsOf: metadataURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let bundle: [String: Any] = ["credential": credentialObject, "accountMetadata": metadata]
        return (try? JSONSerialization.data(withJSONObject: bundle, options: [.sortedKeys])) ?? credential
    }

    static func sessionParts(_ data: Data) -> (credential: [String: Any], metadata: [String: Any]) {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let credential = root["credential"] as? [String: Any] {
            return (credential, root["accountMetadata"] as? [String: Any] ?? [:])
        }
        return (root, [:])
    }

    static func saveManaged(_ data: Data, accountID: String) throws {
        do {
            try AIUsageCredentialVault.set(data, for: managedCredentialKey(accountID))
        } catch let CredentialVaultError.keychain(status) {
            throw ClaudeCodeSessionError.keychain(status)
        }
    }

    static func managedCredential(accountID: String) throws -> Data {
        do {
            guard let data = try AIUsageCredentialVault.data(for: managedCredentialKey(accountID), migrating: {
                try readIfExists(service: managedService, account: accountID)
            }, deletingLegacy: {
                try AIUsageCredentialVault.deleteLegacyData(service: managedService, account: accountID)
            }) else {
                throw ClaudeCodeSessionError.keychain(errSecItemNotFound)
            }
            return data
        } catch let error as CredentialVaultError {
            if case .keychain(let status) = error { throw ClaudeCodeSessionError.keychain(status) }
            throw error
        }
    }

    static func deleteManagedCredential(accountID: String) throws {
        try AIUsageCredentialVault.remove(managedCredentialKey(accountID))
        try AIUsageCredentialVault.deleteLegacyData(service: managedService, account: accountID)
    }

    private static func managedCredentialKey(_ accountID: String) -> String { "claude/managed/\(accountID)" }

    static func accessToken(from data: Data) throws -> String {
        let (root, _) = sessionParts(data)
        let oauth = root["claudeAiOauth"] as? [String: Any] ?? root
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw ClaudeCodeSessionError.invalidCredential
        }
        return token
    }

    static func refreshedCredential(
        from data: Data,
        using loader: any HTTPDataLoading,
        now: Date = .now,
        force: Bool = false
    ) async throws -> Data {
        let (credential, _) = sessionParts(data)
        var oauth = credential["claudeAiOauth"] as? [String: Any] ?? [:]
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue / 1_000)
        }
        if !force, expiresAt.map({ $0 > now.addingTimeInterval(60) }) ?? true { return data }
        guard let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty else {
            throw ProviderFailure.credentials(String(localized: "Claude Code session expired. Sign in again."))
        }

        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauth["clientId"] as? String ?? oauthClientID
        ])
        request.timeoutInterval = 20

        let responseData: Data
        let response: URLResponse
        do { (responseData, response) = try await loader.data(for: request) }
        catch { throw ProviderFailure.network(String(localized: "Could not refresh the Claude Code session.")) }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderFailure.invalidResponse(String(localized: "Claude Code token refresh returned no HTTP response."))
        }
        guard http.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let accessToken = body["access_token"] as? String,
              let expiresIn = (body["expires_in"] as? NSNumber)?.doubleValue else {
            if http.statusCode == 400 || http.statusCode == 401 {
                throw ProviderFailure.credentials(String(localized: "Claude Code session expired. Sign in again."))
            }
            if http.statusCode != 200 { throw ProviderFailure.http(http.statusCode) }
            throw ProviderFailure.invalidResponse(String(localized: "Claude Code token refresh returned an invalid response."))
        }

        oauth["accessToken"] = accessToken
        if let rotatedRefreshToken = body["refresh_token"] as? String, !rotatedRefreshToken.isEmpty {
            oauth["refreshToken"] = rotatedRefreshToken
        }
        oauth["expiresAt"] = (now.addingTimeInterval(expiresIn).timeIntervalSince1970 * 1_000) as NSNumber
        var updatedCredential = credential
        updatedCredential["claudeAiOauth"] = oauth
        let root: [String: Any]
        if var bundle = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           bundle["credential"] != nil {
            bundle["credential"] = updatedCredential
            root = bundle
        } else {
            root = updatedCredential
        }
        guard JSONSerialization.isValidJSONObject(root) else {
            throw ClaudeCodeSessionError.invalidCredential
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    static func installLive(_ data: Data, configDirectory: URL) throws {
        let service = liveService(configDirectory: configDirectory)
        let (credential, _) = sessionParts(data)
        let liveData = try JSONSerialization.data(withJSONObject: credential, options: [.sortedKeys])
        let query = baseQuery(service: service)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: liveData] as CFDictionary)
        if status == errSecItemNotFound {
            try save(liveData, service: service, account: "Claude Code")
        } else if status != errSecSuccess {
            throw ClaudeCodeSessionError.keychain(status)
        }
    }

    static func synchronizeRefreshedLiveCredential(previous: Data, updated: Data, configDirectory: URL) throws {
        let live = try nativeCredential(configDirectory: configDirectory)
        if sameOAuthTokens(live, updated) {
            try updateAccountMetadata(updated, configDirectory: configDirectory)
            return
        }
        guard sameOAuthTokens(live, previous) else {
            throw ClaudeCodeSessionError.credentialChangedDuringRefresh
        }
        try installLive(updated, configDirectory: configDirectory)
        try updateAccountMetadata(updated, configDirectory: configDirectory)
    }

    private static func sameOAuthTokens(_ lhs: Data, _ rhs: Data) -> Bool {
        func tokens(_ data: Data) -> (access: String?, refresh: String?) {
            let (credential, _) = sessionParts(data)
            let oauth = credential["claudeAiOauth"] as? [String: Any] ?? credential
            return (oauth["accessToken"] as? String, oauth["refreshToken"] as? String)
        }
        let left = tokens(lhs)
        let right = tokens(rhs)
        guard let leftAccess = left.access, let leftRefresh = left.refresh,
              let rightAccess = right.access, let rightRefresh = right.refresh else { return false }
        return leftAccess == rightAccess && leftRefresh == rightRefresh
    }

    static func removeTemporary(configDirectory: URL) {
        let query = baseQuery(service: scopedService(configDirectory: configDirectory))
        SecItemDelete(query as CFDictionary)
    }

    static func updateAccountMetadata(_ data: Data, configDirectory: URL) throws {
        let metadataURL = configDirectory.appendingPathComponent(".claude.json")
        let (credential, bundledMetadata) = sessionParts(data)
        var metadata = (try? JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL))) as? [String: Any] ?? [:]
        var account = bundledMetadata["oauthAccount"] as? [String: Any] ?? [:]
        if let credentialAccount = credential["oauthAccount"] as? [String: Any] {
            account.merge(credentialAccount) { _, new in new }
        }
        if let oauth = credential["claudeAiOauth"] as? [String: Any] {
            for key in ["email", "accountUuid", "organizationUuid", "organizationRole"] {
                if let value = oauth[key] { account[key] = value }
            }
        }
        if account.isEmpty { metadata.removeValue(forKey: "oauthAccount") }
        else { metadata["oauthAccount"] = account }
        guard JSONSerialization.isValidJSONObject(metadata) else { return }
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: metadataURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
    }

    static func liveService(
        configDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        nativeServices(configDirectory: configDirectory, environment: environment, homeDirectory: homeDirectory).first
            ?? "Claude Code-credentials"
    }

    private static func nativeServices(
        configDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        let defaultDirectory = homeDirectory.appendingPathComponent(".claude", isDirectory: true).standardizedFileURL
        let configured = environment["CLAUDE_CONFIG_DIR"] != nil
            || configDirectory.standardizedFileURL != defaultDirectory
        return configured ? [scopedService(configDirectory: configDirectory)] : ["Claude Code-credentials", "Claude Code"]
    }

    private static func scopedService(configDirectory: URL) -> String {
        let path = configDirectory.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(digest.prefix(8))"
    }

    private static func save(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addition as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ClaudeCodeSessionError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw ClaudeCodeSessionError.keychain(status)
        }
    }

    private static func read(service: String, account: String) throws -> Data {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw ClaudeCodeSessionError.keychain(status) }
        return data
    }

    private static func readIfExists(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ClaudeCodeSessionError.keychain(status) }
        return data
    }

    private static func baseQuery(service: String, account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }
}

protocol ManagedClaudeCredentialStoring: Sendable {
    func load(accountID: String) throws -> Data
    func save(_ data: Data, accountID: String) throws
    func remove(accountID: String) throws
}

struct KeychainManagedClaudeCredentialStore: ManagedClaudeCredentialStoring {
    func load(accountID: String) throws -> Data {
        try ClaudeCodeCredentialVault.managedCredential(accountID: accountID)
    }

    func save(_ data: Data, accountID: String) throws {
        try ClaudeCodeCredentialVault.saveManaged(data, accountID: accountID)
    }

    func remove(accountID: String) throws {
        try ClaudeCodeCredentialVault.deleteManagedCredential(accountID: accountID)
    }
}
