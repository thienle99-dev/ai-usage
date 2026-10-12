import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex = "Codex"
    case claude = "Claude"
    case cursor = "Cursor"
    case copilot = "Copilot"
    case gemini = "Gemini"
    case windsurf = "Windsurf"
    case cline = "Cline"
    case roo = "Roo"
    case openCode = "OpenCode"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .codex: "OpenAI Codex"
        case .claude: "Claude Code"
        case .cursor: "Cursor"
        case .copilot: "GitHub Copilot"
        case .gemini: "Gemini CLI"
        case .windsurf: "Windsurf"
        case .cline: "Cline"
        case .roo: "Roo Code"
        case .openCode: "OpenCode"
        }
    }
    var shortName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .copilot: "Copilot"
        case .gemini: "Gemini"
        case .windsurf: "Windsurf"
        case .cline: "Cline"
        case .roo: "Roo"
        case .openCode: "OpenCode"
        }
    }
    var menuBarAbbreviation: String {
        switch self {
        case .codex: "C"
        case .claude: "A"
        default: shortName
        }
    }
    var systemImage: String {
        switch self {
        case .codex: "terminal.fill"
        case .claude: "sparkles"
        case .cursor: "cursorarrow"
        case .copilot: "chevron.left.forwardslash.chevron.right"
        case .gemini: "diamond.fill"
        case .windsurf: "wind"
        case .cline: "wrench.and.screwdriver.fill"
        case .roo: "point.3.connected.trianglepath.dotted"
        case .openCode: "chevron.left.forwardslash.chevron.right"
        }
    }
    var isUsageSupported: Bool { self == .codex || self == .claude }
    static let supported: [Provider] = [.codex, .claude]
}

enum ProviderStatus: String, Codable, Sendable {
    case connected
    case authenticationRequired
    case rateLimited
    case unavailable
    case error

    var title: String {
        switch self {
        case .connected: "Connected"
        case .authenticationRequired: "Authentication required"
        case .rateLimited: "Rate limited"
        case .unavailable: "Data unavailable"
        case .error: "Error"
        }
    }
}

enum RefreshPolicy: String, CaseIterable, Identifiable, Codable, Sendable {
    case oneMinute
    case fiveMinutes
    case tenMinutes
    case fifteenMinutes
    case manual

    var id: String { rawValue }
    var title: String {
        switch self {
        case .oneMinute: "1 minute"
        case .fiveMinutes: "5 minutes"
        case .tenMinutes: "10 minutes"
        case .fifteenMinutes: "15 minutes"
        case .manual: "Manual only"
        }
    }
    var interval: Duration? {
        switch self {
        case .oneMinute: .seconds(60)
        case .fiveMinutes: .seconds(300)
        case .tenMinutes: .seconds(600)
        case .fifteenMinutes: .seconds(900)
        case .manual: nil
        }
    }

    init(legacyInterval: Int) {
        switch legacyInterval {
        case 0: self = .manual
        case 0..<180: self = .oneMinute
        case 180..<450: self = .fiveMinutes
        case 450..<750: self = .tenMinutes
        default: self = .fifteenMinutes
        }
    }
}

enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case iconOnly
    case combinedUsage
    case providerSpecific
    case criticalProviderOnly

    var id: String { rawValue }
    var title: String {
        switch self {
        case .iconOnly: "Icon only"
        case .combinedUsage: "Combined usage"
        case .providerSpecific: "Provider-specific"
        case .criticalProviderOnly: "Critical provider only"
        }
    }

    init(legacyValue: String) {
        switch legacyValue {
        case "App name": self = .iconOnly
        default: self = .combinedUsage
        }
    }
}

struct UsageWindow: Codable, Identifiable, Sendable {
    let label: String
    /// Provider-reported consumed percentage. Invalid source values are kept
    /// for diagnostics but excluded from presentation and aggregation.
    let utilization: Double
    let resetsAt: Date?
    var detail: String? = nil

    var id: String { label }
    var validUtilization: Double? {
        utilization.isFinite && (0...100).contains(utilization) ? utilization : nil
    }
}

struct UsageSnapshot: Codable, Identifiable, Sendable {
    var id: String { provider.rawValue }
    let provider: Provider
    var windows: [UsageWindow]
    var account: String?
    var lastSuccess: Date
    var error: String?
    var status: ProviderStatus? = .connected

    var isStale: Bool { error != nil }
    var validWindows: [UsageWindow] { windows.filter { $0.validUtilization != nil } }
}

enum UsageAggregation {
    static func maximum(in snapshots: [Provider: UsageSnapshot], enabled: Set<Provider>) -> Double? {
        snapshots.values
            .filter { enabled.contains($0.provider) }
            .flatMap(\.validWindows)
            .compactMap(\.validUtilization)
            .max()
    }

    static func maximum(for provider: Provider, in snapshots: [Provider: UsageSnapshot], enabled: Set<Provider>) -> Double? {
        guard enabled.contains(provider), let snapshot = snapshots[provider] else { return nil }
        return snapshot.validWindows.compactMap(\.validUtilization).max()
    }
}

enum ProviderFailure: LocalizedError, Sendable {
    case credentials(String), http(Int), invalidResponse(String), process(String), network(String)

    var status: ProviderStatus {
        switch self {
        case .credentials, .http(401), .http(403): .authenticationRequired
        case .http(429): .rateLimited
        case .invalidResponse: .unavailable
        case .http, .process, .network: .error
        }
    }

    var errorDescription: String? {
        switch self {
        case .credentials(let message), .invalidResponse(let message), .process(let message), .network(let message): message
        case .http(401), .http(403): "Authentication expired or access was denied."
        case .http(429): "Rate limited. Try again later."
        case .http(let code): "Service returned HTTP \(code)."
        }
    }
}

enum UsageParsing {
    static func claudeAccount(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let account = root["account"] as? [String: Any]
        let organization = root["organization"] as? [String: Any]
        let email = (account?["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (account?["display_name"] as? String) ?? (account?["full_name"] as? String)
        let plan = (organization?["rate_limit_tier"] as? String) ?? (account?["subscription_type"] as? String)
        let identity = [email, displayName].compactMap { $0 }.first(where: { !$0.isEmpty })
        guard let identity else { return nil }
        guard let plan, !plan.isEmpty else { return identity }
        return "\(identity) · \(friendlyPlan(plan))"
    }

    private static func friendlyPlan(_ value: String) -> String {
        let normalized = value.lowercased()
        if normalized.contains("max_20x") { return "Max 20x" }
        if normalized.contains("max_5x") { return "Max 5x" }
        if normalized.contains("max") { return "Max" }
        if normalized.contains("pro") { return "Pro" }
        if normalized.contains("team") { return "Team" }
        if normalized.contains("enterprise") { return "Enterprise" }
        return value
    }

    static func claude(_ data: Data, now: Date = .now) throws -> [UsageWindow] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFailure.invalidResponse("Claude returned malformed usage data.")
        }
        let source = (root["utilization"] as? [String: Any])
            ?? (root["rate_limits"] as? [String: Any])
            ?? (root["rateLimits"] as? [String: Any])
            ?? root
        var result: [UsageWindow] = []
        for (key, label) in [("five_hour", "5-hour limit"), ("seven_day", "Weekly limit"), ("seven_day_sonnet", "Sonnet weekly"), ("seven_day_opus", "Opus weekly")] {
            guard let item = source[key] as? [String: Any],
                  let amount = number(item["utilization"] ?? item["used_percentage"] ?? item["usedPercentage"]) else { continue }
            result.append(UsageWindow(label: label, utilization: amount, resetsAt: date(item["resets_at"] ?? item["resetsAt"])))
        }
        if let limits = limitItems(root["limits"]) {
            for (limit, keyedKind) in limits {
                guard let amount = number(limit["percent"] ?? limit["utilization"]) else { continue }
                let kind = (limit["kind"] as? String) ?? (limit["group"] as? String) ?? keyedKind ?? ""
                let label: String
                switch kind {
                case "session": label = "5-hour limit"
                case "weekly_all", "weekly": label = "Weekly limit"
                case "weekly_scoped":
                    let scope = limit["scope"] as? [String: Any]
                    let model = scope?["model"] as? [String: Any]
                    let name = (model?["display_name"] as? String) ?? (model?["name"] as? String)
                    label = name.map { "\($0) weekly" } ?? "Model weekly"
                default: continue
                }
                if result.contains(where: { $0.label == label }) { continue }
                result.append(UsageWindow(label: label, utilization: amount, resetsAt: date(limit["resets_at"] ?? limit["resetsAt"])))
            }
        }
        if let extraUsage = root["extra_usage"] as? [String: Any],
           (extraUsage["is_enabled"] as? Bool) == true,
           let used = number(extraUsage["used_credits"]),
           let limit = number(extraUsage["monthly_limit"]), limit > 0 {
            let percent = number(extraUsage["utilization"]) ?? (used / limit * 100)
            let currency = (extraUsage["currency"] as? String) ?? "USD"
            // OAuth extra_usage amounts are minor units (cents for USD).
            let detail = "\(money(used / 100, currency: currency)) / \(money(limit / 100, currency: currency))"
            if !result.contains(where: { $0.label == "Usage credits" }) {
                result.append(UsageWindow(label: "Usage credits", utilization: percent, resetsAt: nil, detail: detail))
            }
        }
        let hasUsageSchema = ["five_hour", "seven_day", "limits", "extra_usage"].contains { root[$0] != nil }
        guard !result.isEmpty || hasUsageSchema else {
            let keys = root.keys.sorted().joined(separator: ", ")
            let nestedKeys = ["utilization", "rate_limits", "rateLimits"].compactMap { root[$0] as? [String: Any] }
                .flatMap { $0.keys }.sorted().joined(separator: ", ")
            let details = nestedKeys.isEmpty ? keys : "\(keys) (nested: \(nestedKeys))"
            throw ProviderFailure.invalidResponse("Claude returned an unrecognized usage response. Response fields: \(details.isEmpty ? "none" : details).")
        }
        return result
    }

    private static func limitItems(_ value: Any?) -> [([String: Any], String?)]? {
        if let array = value as? [[String: Any]] { return array.map { ($0, nil) } }
        guard let object = value as? [String: Any] else { return nil }
        if object["kind"] != nil || object["group"] != nil { return [(object, nil)] }
        return object.compactMap { key, value in
            guard let item = value as? [String: Any] else { return nil }
            return (item, key)
        }
    }

    private static func money(_ value: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? "\(currency) \(value)"
    }

    static func codex(_ data: Data) throws -> (windows: [UsageWindow], account: String?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFailure.invalidResponse("Codex returned malformed usage data.")
        }
        let value = (root["result"] as? [String: Any]) ?? root
        let accountObject = value["account"] as? [String: Any]
        let email = (value["email"] as? String) ?? (accountObject?["email"] as? String)
        let plan = (value["planType"] as? String) ?? (accountObject?["planType"] as? String)
        let account = [email, plan.map(friendlyPlan)].compactMap { $0 }.joined(separator: " · ")
        let response = (value["rateLimits"] as? [String: Any])
            ?? (value["rate_limits"] as? [String: Any])
            ?? value
        var limitSets: [[String: Any]] = []
        if let nested = response["rateLimits"] as? [String: Any] { limitSets.append(nested) }
        if let byID = response["rateLimitsByLimitId"] as? [String: Any] {
            limitSets += byID.values.compactMap { $0 as? [String: Any] }
        }
        if response["primary"] != nil || response["secondary"] != nil { limitSets.append(response) }
        if limitSets.isEmpty { limitSets.append(response) }
        var windows: [UsageWindow] = []
        for limits in limitSets {
            for (key, fallbackLabel) in [("primary", "5-hour limit"), ("secondary", "Weekly limit")] {
                guard let item = limits[key] as? [String: Any], let amount = number(item["usedPercent"] ?? item["used_percent"]) else { continue }
                var duration = number(item["windowDurationMins"] ?? item["window_duration_mins"])
                if duration == nil, let seconds = number(item["windowDurationSeconds"] ?? item["window_duration_seconds"]) { duration = (seconds + 59) / 60 }
                let label = duration.map { $0 >= 8_640 ? "Weekly limit" : ($0 >= 180 ? "5-hour limit" : fallbackLabel) } ?? fallbackLabel
                windows.append(UsageWindow(label: label, utilization: amount, resetsAt: date(item["resetsAt"] ?? item["resets_at"])))
            }
        }
        guard !windows.isEmpty else { throw ProviderFailure.invalidResponse("Codex returned no recognized rate limits.") }
        // Keep one row per semantic window when rateLimits and the by-ID
        // compatibility view both contain the same pool.
        var unique: [String: UsageWindow] = [:]
        for window in windows { unique[window.label] = window }
        return (Array(unique.values).sorted { $0.label < $1.label }, account.isEmpty ? nil : account)
    }

    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
    private static func date(_ value: Any?) -> Date? {
        if let seconds = value as? NSNumber { return Date(timeIntervalSince1970: seconds.doubleValue) }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string) ?? formatter.date(from: string + "Z")
    }
}
