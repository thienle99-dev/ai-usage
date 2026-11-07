import Foundation

struct CommandCodeProvider: UsageProvider {
    let provider = Provider.commandCode
    private let loader: any HTTPDataLoading
    private let homeDirectory: URL

    init(loader: any HTTPDataLoading = URLSessionDataLoader(), homeDirectory: URL? = nil) {
        self.loader = loader
        self.homeDirectory = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func fetch() async throws -> UsageSnapshot {
        let apiKey = try Self.loadAPIKey(homeDirectory: homeDirectory)

        let whoamiData = try await request(path: "/alpha/whoami?limits=1", apiKey: apiKey)
        guard let whoamiRoot = (try? JSONSerialization.jsonObject(with: whoamiData)) as? [String: Any] else {
            throw ProviderFailure.invalidResponse("Command Code returned malformed usage data.")
        }
        let org = whoamiRoot["org"] as? [String: Any]
        let orgID = Self.stringValue(org?["id"])

        let creditsPath = orgID.map { "/alpha/billing/credits?orgId=\($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0)" }
            ?? "/alpha/billing/credits"
        let creditsData = try await request(path: creditsPath, apiKey: apiKey)

        let subscriptionsPath = orgID.map { "/alpha/billing/subscriptions?orgId=\($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0)" }
            ?? "/alpha/billing/subscriptions"
        let subscriptionsData = try await request(path: subscriptionsPath, apiKey: apiKey)

        guard let creditsRoot = (try? JSONSerialization.jsonObject(with: creditsData)) as? [String: Any] else {
            throw ProviderFailure.invalidResponse("Command Code returned malformed usage data.")
        }
        let subscriptionsRoot = (try? JSONSerialization.jsonObject(with: subscriptionsData)) as? [String: Any]
        let subscriptionData = subscriptionsRoot?["data"] as? [String: Any]
        let planId = subscriptionData?["planId"] as? String
        let planName = Self.planDisplayName(planId)

        let creditsObject = creditsRoot["credits"] as? [String: Any]
        let windowLimits = creditsRoot["windowLimits"] as? [String: Any]

        let periodEnd = Self.date(fromISO: subscriptionData?["currentPeriodEnd"])
        let requestCount = await fetchRequestCount(
            orgID: orgID,
            since: subscriptionData?["currentPeriodStart"] as? String,
            apiKey: apiKey
        )

        var windows: [UsageWindow] = []
        if let credits = Self.creditsWindow(
            credits: creditsObject,
            planId: planId,
            subscription: subscriptionData,
            periodEnd: periodEnd,
            requestCount: requestCount
        ) {
            windows.append(credits)
        }
        if let windowLimits {
            if let fiveHour = Self.limitWindow(windowLimits["fiveHour"], label: "5-hour") { windows.append(fiveHour) }
            if let weekly = Self.limitWindow(windowLimits["weekly"], label: "Weekly limit") { windows.append(weekly) }
        }

        if windows.isEmpty {
            throw ProviderFailure.invalidResponse("Command Code returned no recognized usage windows.")
        }

        let user = whoamiRoot["user"] as? [String: Any]
        let identity = [user?["email"], user?["userName"], user?["name"]]
            .lazy.compactMap { Self.stringValue($0) }.first
        let account = [identity, planName].compactMap { $0 }.joined(separator: " · ")

        return UsageSnapshot(
            provider: .commandCode,
            windows: windows,
            account: account.isEmpty ? nil : account,
            lastSuccess: .now
        )
    }

    /// Best-effort: the request count is informational, so any failure just omits it.
    private func fetchRequestCount(orgID: String?, since: String?, apiKey: String) async -> Double? {
        var components = URLComponents()
        components.path = "/alpha/usage/summary"
        components.queryItems = [
            orgID.map { URLQueryItem(name: "orgId", value: $0) },
            since.map { URLQueryItem(name: "since", value: $0) }
        ].compactMap { $0 }
        guard let path = components.string,
              let data = try? await request(path: path, apiKey: apiKey),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return Self.number(root["totalCount"])
    }

    private static func limitWindow(_ value: Any?, label: String) -> UsageWindow? {
        guard let limit = value as? [String: Any],
              let used = number(limit["used"]),
              let cap = number(limit["cap"]), cap > 0 else { return nil }
        return UsageWindow(label: label, utilization: min(used / cap * 100, 100), resetsAt: resetDate(limit["resetAt"]))
    }

    private static func creditsWindow(
        credits: [String: Any]?,
        planId: String?,
        subscription: [String: Any]?,
        periodEnd: Date?,
        requestCount: Double?
    ) -> UsageWindow? {
        guard let credits else { return nil }
        let monthly = number(credits["monthlyCredits"]) ?? 0
        let purchased = number(credits["purchasedCredits"]) ?? 0
        let free = number(credits["freeCredits"]) ?? 0
        let remaining = monthly + purchased + free
        let isActive = (subscription?["status"] as? String)?.lowercased() == "active"
        let pool: Double
        if isActive, let planMonthly = planMonthlyCredits(planId, subscription: subscription), planMonthly > 0 {
            pool = max(planMonthly, monthly) + purchased + free
        } else {
            pool = remaining
        }
        let utilization = pool > 0 ? min(max((pool - remaining) / pool * 100, 0), 100) : 0
        let detail = requestCount.map {
            "\(Int($0.rounded()).formatted(.number.locale(Locale(identifier: "en_US")))) requests this month"
        }
        return UsageWindow(label: "Credits", utilization: utilization, resetsAt: periodEnd, detail: detail)
    }

    private static func date(fromISO value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private func request(path: String, apiKey: String) async throws -> Data {
        guard let url = URL(string: "https://api.commandcode.ai\(path)") else {
            throw ProviderFailure.invalidResponse("Command Code returned malformed usage data.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let data: Data
        let response: URLResponse
        do { (data, response) = try await loader.data(for: request) }
        catch { throw ProviderFailure.network("Could not reach Command Code. Check your network and try again.") }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderFailure.invalidResponse("No HTTP response from Command Code.")
        }
        guard http.statusCode == 200 else { throw ProviderFailure.http(http.statusCode) }
        return data
    }

    private static func loadAPIKey(homeDirectory: URL) throws -> String {
        let url = homeDirectory.appendingPathComponent(".commandcode/auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apiKey = (root["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            throw ProviderFailure.credentials("Sign in to Command Code with `cmd login`.")
        }
        return apiKey
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func resetDate(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        let milliseconds = number.doubleValue
        guard milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func planDisplayName(_ planId: String?) -> String? {
        guard let planId else { return nil }
        let normalized = planId.lowercased()
        if normalized.hasPrefix("individual-go") { return "Go" }
        if normalized.hasPrefix("individual-pro") { return "Pro" }
        if normalized == "individual-max" { return "Max" }
        if normalized.hasPrefix("individual-max") { return "Max" }
        if normalized == "individual-ultra" { return "Ultra" }
        if normalized.hasPrefix("individual-ultra") { return "Ultra" }
        if normalized == "teams-pro" { return "Teams Pro" }
        if normalized.hasPrefix("teams-pro") { return "Teams Pro" }
        if normalized == "individual-goat" { return "GOAT" }
        if normalized == "individual-provider" { return "Provider" }
        return planId
    }

    private static func planMonthlyCredits(_ planId: String?, subscription: [String: Any]?) -> Double? {
        let mapping: [String: Double] = [
            "individual-go": 10, "individual-go-v1": 10, "individual-goat": 70,
            "individual-pro": 30, "individual-pro-v1": 80, "individual-provider": 15,
            "individual-max": 150, "individual-ultra": 300, "teams-pro": 40
        ]
        guard let planId else { return nil }
        let normalized = planId.lowercased()
        if let value = mapping[normalized] { return value }
        // prefix match
        for (key, value) in mapping where normalized.hasPrefix(key) { return value }
        return nil
    }
}
