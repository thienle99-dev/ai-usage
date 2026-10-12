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

    init(
        loader: any HTTPDataLoading = URLSessionDataLoader(),
        homeDirectory: URL? = nil,
        credentialReader: @escaping @Sendable () -> Data? = { AntigravityCredentials.keychainData() }
    ) {
        self.loader = loader
        self.homeDirectory = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        self.credentialReader = credentialReader
    }

    func fetch() async throws -> UsageSnapshot {
        guard var credential = AntigravityCredentials.decode(credentialReader())
                ?? AntigravityCredentials.decode(try? Data(contentsOf: homeDirectory.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token"))) else {
            throw ProviderFailure.credentials("Sign in to Antigravity first. Its OAuth credential was not found.")
        }
        var accessToken = credential.accessToken
        if credential.expiry.map({ $0 <= .now.addingTimeInterval(60) }) != false,
           let refreshToken = credential.refreshToken {
            credential = try await refresh(refreshToken: refreshToken)
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
        return UsageSnapshot(provider: .antigravity, windows: windows, account: nil, lastSuccess: .now)
    }

    private func refresh(refreshToken: String) async throws -> AntigravityCredentials {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = AntigravityCredentials.formBody([
            "client_id": AntigravityCredentials.clientID,
            "client_secret": AntigravityCredentials.clientSecret,
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
        return AntigravityCredentials(accessToken: token, refreshToken: refreshToken, expiry: .now.addingTimeInterval(seconds.doubleValue))
    }

    private func perform(_ request: URLRequest, service: String) async throws -> (Data, URLResponse) {
        do { return try await loader.data(for: request) }
        catch { throw ProviderFailure.network("Could not reach \(service). Check your network and try again.") }
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

    // Public installed-app OAuth client used by Antigravity CLI.
    static let clientID = ""
    static let clientSecret = ""

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
        return AntigravityCredentials(
            accessToken: token["access_token"] as? String,
            refreshToken: token["refresh_token"] as? String,
            expiry: expiry
        )
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
