import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads the signed-in Gemini CLI OAuth session and its Code Assist quota.
struct GeminiProvider: UsageProvider {
    let provider = Provider.gemini
    private let loader: any HTTPDataLoading
    private let homeDirectory: URL

    init(loader: any HTTPDataLoading = URLSessionDataLoader(), homeDirectory: URL? = nil) {
        self.loader = loader
        self.homeDirectory = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func fetch() async throws -> UsageSnapshot {
        try Self.validateAuthType(homeDirectory: homeDirectory)
        var credentials = try Self.loadCredentials(homeDirectory: homeDirectory)
        if credentials.accessToken == nil || credentials.expiryDate.map({ $0 <= .now.addingTimeInterval(60) }) == true {
            guard let refreshToken = credentials.refreshToken else {
                throw ProviderFailure.credentials("Gemini CLI is not signed in. Run `gemini` in Terminal and sign in with Google.")
            }
            credentials = try await refresh(credentials, refreshToken: refreshToken)
        }
        guard let accessToken = credentials.accessToken else {
            throw ProviderFailure.credentials("Gemini CLI is not signed in. Run `gemini` in Terminal and sign in with Google.")
        }

        let identity = Self.jwtClaims(credentials.idToken)
        let codeAssist = try await loadCodeAssist(accessToken: accessToken, hostedDomain: identity.hostedDomain)
        let payload = try await retrieveQuota(accessToken: accessToken, projectID: codeAssist.projectID, tier: codeAssist.tier, hostedDomain: identity.hostedDomain)
        let windows = try GeminiParsing.windows(payload)
        let account = [identity.email, codeAssist.plan].compactMap { $0 }.joined(separator: " · ")
        return UsageSnapshot(provider: .gemini, windows: windows, account: account.isEmpty ? nil : account, lastSuccess: .now)
    }

    private func loadCodeAssist(accessToken: String, hostedDomain: String?) async throws -> (projectID: String?, tier: String?, plan: String?) {
        var request = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}"#.utf8)
        request.timeoutInterval = 20
        let (data, response) = try await perform(request, service: "Gemini")
        guard let http = response as? HTTPURLResponse else { throw ProviderFailure.invalidResponse("Gemini returned no HTTP response.") }
        guard http.statusCode == 200 else { throw ProviderFailure.http(http.statusCode) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFailure.invalidResponse("Gemini returned malformed account information.")
        }
        if Self.isConsumerShutdown(root) {
            throw ProviderFailure.credentials("Google no longer supports Gemini CLI OAuth for individual accounts. Use a supported Workspace or Code Assist account.")
        }
        let projectValue = root["cloudaicompanionProject"]
        let project = projectValue as? String
            ?? (projectValue as? [String: Any]).flatMap { $0["id"] as? String ?? $0["projectId"] as? String }
        let tier = (root["currentTier"] as? [String: Any])?["id"] as? String
        let paidTier = (root["paidTier"] as? [String: Any])?["name"] as? String
        let plan: String?
        if let paidTier, !paidTier.isEmpty { plan = paidTier }
        else {
            switch tier {
            case "standard-tier": plan = "Paid"
            case "free-tier": plan = hostedDomain == nil ? "Free" : "Workspace"
            case "legacy-tier": plan = "Legacy"
            default: plan = nil
            }
        }
        return (project, tier, plan)
    }

    private func retrieveQuota(accessToken: String, projectID: String?, tier: String?, hostedDomain: String?) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = [:]
        if let projectID { body["project"] = projectID }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20
        let (data, response) = try await perform(request, service: "Gemini")
        guard let http = response as? HTTPURLResponse else { throw ProviderFailure.invalidResponse("Gemini returned no HTTP response.") }
        if http.statusCode == 401 { throw ProviderFailure.credentials("Gemini session expired. Run `gemini` in Terminal to sign in again.") }
        if http.statusCode == 403, tier == "free-tier", hostedDomain == nil {
            throw ProviderFailure.credentials("Google no longer supports Gemini CLI OAuth for individual accounts. Use a supported Workspace or Code Assist account.")
        }
        guard http.statusCode == 200 else { throw ProviderFailure.http(http.statusCode) }
        return data
    }

    private func refresh(_ credentials: GeminiOAuthCredentials, refreshToken: String) async throws -> GeminiOAuthCredentials {
        guard let client = Self.oauthClientCredentials() else {
            throw ProviderFailure.credentials("Could not find Gemini CLI OAuth client credentials. Reinstall Gemini CLI or set GEMINI_OAUTH_CLIENT_ID and GEMINI_OAUTH_CLIENT_SECRET.")
        }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formBody([
            "client_id": client.id,
            "client_secret": client.secret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ])
        request.timeoutInterval = 20
        let (data, response) = try await perform(request, service: "Google OAuth")
        guard let http = response as? HTTPURLResponse else { throw ProviderFailure.invalidResponse("Google OAuth returned no HTTP response.") }
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            if http.statusCode == 400 || http.statusCode == 401 {
                throw ProviderFailure.credentials("Gemini session expired. Run `gemini` in Terminal to sign in again.")
            }
            throw ProviderFailure.http(http.statusCode)
        }
        var refreshed = credentials
        refreshed.accessToken = accessToken
        if let idToken = json["id_token"] as? String { refreshed.idToken = idToken }
        if let seconds = json["expires_in"] as? Double { refreshed.expiryDate = .now.addingTimeInterval(seconds) }
        try Self.saveCredentials(refreshed, homeDirectory: homeDirectory)
        return refreshed
    }

    private func perform(_ request: URLRequest, service: String) async throws -> (Data, URLResponse) {
        do { return try await loader.data(for: request) }
        catch { throw ProviderFailure.network("Could not reach \(service). Check your network and try again.") }
    }

    private static func validateAuthType(homeDirectory: URL) throws {
        let settings = homeDirectory.appendingPathComponent(".gemini/settings.json")
        guard let data = try? Data(contentsOf: settings),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let security = root["security"] as? [String: Any],
              let auth = security["auth"] as? [String: Any],
              let selected = auth["selectedType"] as? String else { return }
        if selected == "api-key" || selected == "vertex-ai" {
            throw ProviderFailure.credentials("Gemini \(selected) authentication is not supported. Sign in to Gemini CLI with a Google account.")
        }
    }

    private static func loadCredentials(homeDirectory: URL) throws -> GeminiOAuthCredentials {
        let url = homeDirectory.appendingPathComponent(".gemini/oauth_creds.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFailure.credentials("Gemini CLI credentials were not found. Run `gemini` in Terminal and sign in with Google.")
        }
        let expiryMilliseconds = (root["expiry_date"] as? NSNumber)?.doubleValue
        return GeminiOAuthCredentials(
            accessToken: root["access_token"] as? String,
            idToken: root["id_token"] as? String,
            refreshToken: root["refresh_token"] as? String,
            expiryDate: expiryMilliseconds.map { Date(timeIntervalSince1970: $0 / 1000) },
            raw: root)
    }

    private static func saveCredentials(_ credentials: GeminiOAuthCredentials, homeDirectory: URL) throws {
        var root = credentials.raw
        if let accessToken = credentials.accessToken { root["access_token"] = accessToken }
        if let idToken = credentials.idToken { root["id_token"] = idToken }
        if let expiryDate = credentials.expiryDate { root["expiry_date"] = expiryDate.timeIntervalSince1970 * 1000 }
        let url = homeDirectory.appendingPathComponent(".gemini/oauth_creds.json")
        do {
            try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw ProviderFailure.credentials("Could not update the Gemini CLI credentials file.")
        }
    }

    private static func oauthClientCredentials() -> (id: String, secret: String)? {
        let environment = ProcessInfo.processInfo.environment
        if let id = environment["GEMINI_OAUTH_CLIENT_ID"], let secret = environment["GEMINI_OAUTH_CLIENT_SECRET"], !id.isEmpty, !secret.isEmpty {
            return (id, secret)
        }
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let path = environment["GEMINI_OAUTH2_JS_PATH"] { candidates.append(URL(fileURLWithPath: path)) }
        let home = fileManager.homeDirectoryForCurrentUser
        candidates += [
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"),
            URL(fileURLWithPath: "/usr/local/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"),
            home.appendingPathComponent(".npm-global/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js")
        ]
        if let binary = findGeminiBinary() {
            let resolved = URL(fileURLWithPath: binary).resolvingSymlinksInPath()
            var directory = resolved.deletingLastPathComponent()
            for _ in 0..<7 {
                candidates.append(directory.appendingPathComponent("node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"))
                candidates.append(directory.appendingPathComponent("node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"))
                directory.deleteLastPathComponent()
            }
        }
        for url in candidates where fileManager.fileExists(atPath: url.path) {
            guard let source = try? String(contentsOf: url, encoding: .utf8),
                  let id = capture(#"OAUTH_CLIENT_ID\s*=\s*["']([^"']+)"#, source),
                  let secret = capture(#"OAUTH_CLIENT_SECRET\s*=\s*["']([^"']+)"#, source) else { continue }
            return (id, secret)
        }
        return nil
    }

    private static func findGeminiBinary() -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return paths.map { URL(fileURLWithPath: $0).appendingPathComponent("gemini").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func capture(_ pattern: String, _ source: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range])
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.keys.sorted().map { key in
            let value = fields[key] ?? ""
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private static func jwtClaims(_ token: String?) -> (email: String?, hostedDomain: String?) {
        guard let payload = token?.split(separator: ".").dropFirst().first else { return (nil, nil) }
        var base64 = String(payload).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        return (claims["email"] as? String, claims["hd"] as? String)
    }

    private static func isConsumerShutdown(_ root: [String: Any]) -> Bool {
        let ineligible = root["ineligibleTiers"] as? [[String: Any]] ?? []
        return ineligible.contains { ($0["reasonCode"] as? String) == "UNSUPPORTED_CLIENT" }
    }
}

private struct GeminiOAuthCredentials {
    var accessToken: String?
    var idToken: String?
    let refreshToken: String?
    var expiryDate: Date?
    let raw: [String: Any]
}

enum GeminiParsing {
    private struct QuotaResponse: Decodable { let buckets: [Bucket]? }
    private struct Bucket: Decodable {
        let remainingFraction: Double?
        let resetTime: String?
        let modelID: String?
        enum CodingKeys: String, CodingKey {
            case remainingFraction
            case resetTime
            case modelID = "modelId"
        }
    }

    static func windows(_ data: Data) throws -> [UsageWindow] {
        guard let response = try? JSONDecoder().decode(QuotaResponse.self, from: data),
              let buckets = response.buckets, !buckets.isEmpty else {
            throw ProviderFailure.invalidResponse("Gemini returned no quota buckets.")
        }
        var byModel: [String: (fraction: Double, reset: String?)] = [:]
        for bucket in buckets {
            guard let model = bucket.modelID, let remaining = bucket.remainingFraction,
                  remaining.isFinite, (0...1).contains(remaining) else { continue }
            if let previous = byModel[model], previous.fraction <= remaining { continue }
            byModel[model] = (remaining, bucket.resetTime)
        }
        let quotas = byModel.map { model, value in
            (model: model.lowercased(), remaining: value.fraction, reset: parseDate(value.reset))
        }
        guard !quotas.isEmpty else { throw ProviderFailure.invalidResponse("Gemini returned no valid quota values.") }
        var windows: [UsageWindow] = []
        for label in ["Pro", "Flash", "Flash Lite"] {
            let matching = quotas.filter { quota in
                switch label {
                case "Pro": quota.model.contains("pro")
                case "Flash": quota.model.contains("flash") && !quota.model.contains("flash-lite")
                default: quota.model.contains("flash-lite")
                }
            }
            if let quota = matching.min(by: { $0.remaining < $1.remaining }) {
                windows.append(UsageWindow(label: label, utilization: 100 - quota.remaining * 100, resetsAt: quota.reset))
            }
        }
        if windows.isEmpty, let quota = quotas.min(by: { $0.remaining < $1.remaining }) {
            windows.append(UsageWindow(label: "Gemini", utilization: 100 - quota.remaining * 100, resetsAt: quota.reset))
        }
        return windows
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)
    }
}
