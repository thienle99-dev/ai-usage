import Foundation
import Security
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads the OAuth credential already created by Antigravity and queries its
/// Cloud Code quota endpoint. Refreshed tokens stay in memory and are never
/// written back to Antigravity's Keychain item or legacy token file.
struct AntigravityProvider: UsageProvider {
    let provider = Provider.antigravity
    private let loader: any HTTPDataLoading
    private let homeDirectory: URL
    private let credentialReader: @Sendable () -> Data?
    private let clientProvider: @Sendable () -> AntigravityOAuthClient?

    init(
        loader: any HTTPDataLoading = URLSessionDataLoader(),
        homeDirectory: URL? = nil,
        credentialReader: @escaping @Sendable () -> Data? = { AntigravityCredentials.keychainData() },
        clientProvider: @escaping @Sendable () -> AntigravityOAuthClient? = { AntigravityOAuthClientResolver.resolve() }
    ) {
        self.loader = loader
        self.homeDirectory = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        self.credentialReader = credentialReader
        self.clientProvider = clientProvider
    }

    func fetch() async throws -> UsageSnapshot {
        let cliCredential = AntigravityCredentials.decode(
            try? Data(contentsOf: homeDirectory.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token"))
        )
        let keychainCredential = AntigravityCredentials.decode(credentialReader())
        let now = Date.now.addingTimeInterval(60)
        guard var credential = [keychainCredential, cliCredential].compactMap({ $0 }).max(by: { lhs, rhs in
            let lhsFresh = lhs.expiry.map { $0 > now } ?? true
            let rhsFresh = rhs.expiry.map { $0 > now } ?? true
            if lhsFresh != rhsFresh { return !lhsFresh && rhsFresh }
            return (lhs.expiry ?? .distantPast) < (rhs.expiry ?? .distantPast)
        }) else {
            throw ProviderFailure.credentials("Sign in to Antigravity first. Its OAuth credential was not found.")
        }
        var accessToken = credential.accessToken
        if credential.expiry.map({ $0 <= .now.addingTimeInterval(60) }) != false,
           let refreshToken = credential.refreshToken {
            credential = try await refresh(refreshToken: refreshToken, preserving: credential.identityLabel)
            accessToken = credential.accessToken
        }
        guard let accessToken, !accessToken.isEmpty else {
            throw ProviderFailure.credentials("Antigravity session expired. Sign in to Antigravity again.")
        }
        var request = URLRequest(url: URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity/1.11.3 macOS/\(ProcessInfo.processInfo.machineArchitecture)", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 20
        let (data, response) = try await perform(request, service: "Antigravity")
        guard let http = response as? HTTPURLResponse else { throw ProviderFailure.invalidResponse("Antigravity returned no HTTP response.") }
        guard http.statusCode == 200 else { throw ProviderFailure.http(http.statusCode) }
        let windows = try AntigravityParsing.windows(data)
        let account = await fetchAccount(accessToken: accessToken) ?? credential.identityLabel
        return UsageSnapshot(provider: .antigravity, windows: windows, account: account, lastSuccess: .now)
    }

    private func fetchAccount(accessToken: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8
        guard let (data, response) = try? await loader.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let name = (root["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = (root["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = [name, email].compactMap { $0 }.filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private func refresh(refreshToken: String, preserving identityLabel: String?) async throws -> AntigravityCredentials {
        guard let client = clientProvider() else {
            throw ProviderFailure.credentials("Antigravity session expired. Update or install Antigravity.app, or set ANTIGRAVITY_OAUTH_CLIENT_ID and ANTIGRAVITY_OAUTH_CLIENT_SECRET, then sign in again.")
        }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = AntigravityCredentials.formBody([
            "client_id": client.id,
            "client_secret": client.secret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ])
        request.timeoutInterval = 20
        let (data, response) = try await perform(request, service: "Google OAuth")
        guard let http = response as? HTTPURLResponse else { throw ProviderFailure.invalidResponse("Google OAuth returned no HTTP response.") }
        guard http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["access_token"] as? String,
              let seconds = root["expires_in"] as? NSNumber else {
            if http.statusCode == 400 || http.statusCode == 401 {
                throw ProviderFailure.credentials("Antigravity session expired. Sign in to Antigravity again.")
            }
            throw ProviderFailure.http(http.statusCode)
        }
        return AntigravityCredentials(accessToken: token, refreshToken: refreshToken, expiry: .now.addingTimeInterval(seconds.doubleValue), identityLabel: identityLabel)
    }

    private func perform(_ request: URLRequest, service: String) async throws -> (Data, URLResponse) {
        do { return try await loader.data(for: request) }
        catch { throw ProviderFailure.network("Could not reach \(service). Check your network and try again.") }
    }
}

/// OAuth client for refreshing the Antigravity session. Values are never
/// hardcoded: explicit `ANTIGRAVITY_OAUTH_CLIENT_ID` /
/// `ANTIGRAVITY_OAUTH_CLIENT_SECRET` entries win, otherwise the pair is
/// discovered from the installed Antigravity/Gemini app bundle that ships it.
/// Reference: research/CodexBar/docs/antigravity.md (client discovery) and
/// research/CodexBar/Sources/CodexBarCore/Providers/Antigravity/AntigravityOAuthCredentialsStore.swift.
/// Limitation: bundle layouts are unofficial and reverse-engineered; discovery
/// is best-effort and returns nil when the pair is absent or ambiguous.
struct AntigravityOAuthClient: Sendable, Equatable {
    let id: String
    let secret: String
}

enum AntigravityOAuthClientResolver {
    /// Bounds memory use when scanning large language-server binaries.
    static let artifactScanChunkBytes = 1024 * 1024
    private static let artifactScanOverlapBytes = 4096
    static let clientIDPattern = #"[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com"#
    static let clientSecretPattern = #"GOCSPX-[A-Za-z0-9_-]{28}"#

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationRoots: [URL]? = nil,
        fileManager: FileManager = .default
    ) -> AntigravityOAuthClient? {
        let trimmed: (String?) -> String? = {
            guard let value = $0?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        if let id = trimmed(environment["ANTIGRAVITY_OAUTH_CLIENT_ID"]),
           let secret = trimmed(environment["ANTIGRAVITY_OAUTH_CLIENT_SECRET"]) {
            return AntigravityOAuthClient(id: id, secret: secret)
        }
        if let applicationRoots {
            return discover(applicationRoots: applicationRoots, fileManager: fileManager)
        }
        return installedClient
    }

    /// A large installed language-server binary only needs to be scanned once
    /// per app process when refreshing an expired session.
    private static let installedClient = discover()

    static func discover(applicationRoots: [URL]? = nil, fileManager: FileManager = .default) -> AntigravityOAuthClient? {
        let roots = applicationRoots ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        // Fast path: the standard bundle name needs no Info.plist lookup.
        for root in roots {
            if let client = scan(bundle: root.appendingPathComponent("Antigravity.app", isDirectory: true)) {
                return client
            }
        }
        for root in roots {
            for bundle in matchingBundles(under: root, fileManager: fileManager) {
                if let client = scan(bundle: bundle) { return client }
            }
        }
        return nil
    }

    private static let artifactRelativePaths = [
        "Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm",
        "Contents/Resources/app/extensions/antigravity/bin/language_server_macos_x64",
        "Contents/Resources/app/extensions/antigravity/bin/language_server_macos",
        "Contents/Resources/app/out/main.js",
        "Contents/Resources/bin/language_server",
        "Contents/Resources/bin/language_server_macos",
        "Contents/MacOS/Gemini"
    ]

    private static let antigravityBundleIDs: Set<String> = [
        "com.google.antigravity", "com.google.antigravity-ide", "com.google.GeminiMacOS"
    ]

    private static func scan(bundle: URL) -> AntigravityOAuthClient? {
        for relative in artifactRelativePaths {
            let url = bundle.appendingPathComponent(relative)
            if let client = unambiguousClient(in: url) { return client }
        }
        return nil
    }

    /// Scans the entire artifact without loading a large executable into memory.
    /// OAuth values are only inspected in memory and are never logged or stored.
    private static func unambiguousClient(in artifactURL: URL) -> AntigravityOAuthClient? {
        guard let handle = try? FileHandle(forReadingFrom: artifactURL) else { return nil }
        defer { try? handle.close() }

        var buffer = Data()
        var clientIDs = Set<String>()
        var clientSecrets = Set<String>()
        do {
            while let chunk = try handle.read(upToCount: artifactScanChunkBytes), !chunk.isEmpty {
                buffer.append(chunk)
                let text = String(decoding: buffer, as: UTF8.self)
                clientIDs.formUnion(matches(clientIDPattern, in: text))
                clientSecrets.formUnion(matches(clientSecretPattern, in: text))
                guard clientIDs.count <= 1, clientSecrets.count <= 1 else { return nil }

                if buffer.count > artifactScanOverlapBytes {
                    buffer = Data(buffer.suffix(artifactScanOverlapBytes))
                }
            }
        } catch {
            return nil
        }
        guard let id = clientIDs.first, let secret = clientSecrets.first else { return nil }
        return AntigravityOAuthClient(id: id, secret: secret)
    }

    private static func matchingBundles(under root: URL, fileManager: FileManager) -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        let gemini = root.appendingPathComponent("Gemini.app", isDirectory: true)
        var candidates = [gemini]
        if let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            candidates += entries.filter { $0.pathExtension == "app" }
        }
        for url in candidates {
            let key = url.standardizedFileURL.path
            guard !seen.contains(key), url.lastPathComponent != "Antigravity.app" else { continue }
            seen.insert(key)
            guard let identifier = Bundle(url: url)?.bundleIdentifier,
                  antigravityBundleIDs.contains(identifier) else { continue }
            urls.append(url)
        }
        return urls
    }

    /// Returns the pair only when the text contains exactly one client id and
    /// exactly one secret; multiple distinct values mean mixed artifacts.
    static func unambiguousClient(in text: String) -> AntigravityOAuthClient? {
        guard let id = singleMatch(clientIDPattern, in: text),
              let secret = singleMatch(clientSecretPattern, in: text) else { return nil }
        return AntigravityOAuthClient(id: id, secret: secret)
    }

    private static func singleMatch(_ pattern: String, in text: String) -> String? {
        let values = matches(pattern, in: text)
        return values.count == 1 ? values.first : nil
    }

    private static func matches(_ pattern: String, in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return Set(matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } })
    }
}

private extension ProcessInfo {
    var machineArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
}

private struct AntigravityCredentials {
    let accessToken: String?
    let refreshToken: String?
    let expiry: Date?
    let identityLabel: String?

    static func keychainData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "gemini",
            kSecAttrAccount as String: "antigravity",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func decode(_ data: Data?) -> AntigravityCredentials? {
        guard let data else { return nil }
        var payload = data
        let prefix = Data("go-keyring-base64:".utf8)
        if payload.starts(with: prefix) {
            guard let decoded = Data(base64Encoded: payload.dropFirst(prefix.count)) else { return nil }
            payload = decoded
        }
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let token = root["token"] as? [String: Any] else { return nil }
        let expiry = (token["expiry"] as? String).flatMap(parseDate)
        let claims = (token["id_token"] as? String).flatMap(jwtClaims)
        let name = (claims?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = ((claims?["email"] as? String) ?? (token["email"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = [name, email].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return AntigravityCredentials(
            accessToken: token["access_token"] as? String,
            refreshToken: token["refresh_token"] as? String,
            expiry: expiry,
            identityLabel: identity.isEmpty ? nil : identity
        )
    }

    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let components = token.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return nil }
        var payload = String(components[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.keys.sorted().map { key in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\((fields[key] ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

enum AntigravityParsing {
    static func windows(_ data: Data) throws -> [UsageWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFailure.invalidResponse("Antigravity returned malformed quota data.")
        }
        let groups = (root["groups"] as? [[String: Any]])
            ?? ((root["response"] as? [String: Any])?["groups"] as? [[String: Any]])
            ?? ((root["summary"] as? [String: Any])?["groups"] as? [[String: Any]])
        guard let groups else { throw ProviderFailure.invalidResponse("Antigravity returned an unrecognized quota response.") }

        var windows: [UsageWindow] = []
        for group in groups {
            let groupName = (group["displayName"] as? String) ?? (group["name"] as? String) ?? ""
            let lower = groupName.lowercased()
            let prefix: String
            if lower.contains("gemini") { prefix = "Gemini" }
            else if lower.contains("claude") || lower.contains("gpt") { prefix = "Claude / GPT" }
            else { continue }
            guard let buckets = group["buckets"] as? [[String: Any]] else { continue }
            var addedPeriods = Set<String>()
            for bucket in buckets where !isDisabled(bucket["disabled"]) {
                let descriptor = ["bucketId", "id", "displayName", "name", "window"].compactMap { bucket[$0] as? String }.joined(separator: " ").lowercased()
                let period: String
                let label: String
                if descriptor.contains("week") || descriptor.contains("7d") || descriptor.contains("seven") {
                    period = "weekly"; label = "Weekly"
                } else if descriptor.contains("session") || descriptor.contains("5") || descriptor.contains("hour") {
                    period = "session"; label = "5-hour"
                } else { continue }
                guard addedPeriods.insert(period).inserted,
                      let fraction = remainingFraction(bucket), fraction.isFinite else { continue }
                let reset = ["resetTime", "reset_time", "resetAt", "reset_at"].compactMap { bucket[$0] as? String }.first.flatMap(parseDate)
                windows.append(UsageWindow(label: "\(prefix) \(label)", utilization: (1 - min(1, max(0, fraction))) * 100, resetsAt: reset))
            }
        }
        guard !windows.isEmpty else { throw ProviderFailure.invalidResponse("Antigravity returned no recognized quota windows.") }
        return windows
    }

    private static func isDisabled(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.intValue != 0 }
        return (value as? String)?.lowercased() == "true" || (value as? String) == "1"
    }

    private static func remainingFraction(_ bucket: [String: Any]) -> Double? {
        for key in ["remainingFraction", "remaining_fraction"] {
            if let number = bucket[key] as? NSNumber { return number.doubleValue }
            if let string = bucket[key] as? String, let value = Double(string) { return value }
        }
        if let remaining = bucket["remaining"] as? [String: Any] {
            for key in ["remainingFraction", "remaining_fraction"] {
                if let number = remaining[key] as? NSNumber { return number.doubleValue }
                if let string = remaining[key] as? String, let value = Double(string) { return value }
            }
            if remaining["case"] as? String == "remainingFraction" {
                return (remaining["value"] as? NSNumber)?.doubleValue
            }
        }
        return nil
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
