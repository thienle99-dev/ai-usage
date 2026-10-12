import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"
    var id: String { rawValue }
}

struct UsageWindow: Codable, Identifiable {
    var id: String { label }
    let label: String
    let utilization: Double
    let resetsAt: Date?
}

struct UsageSnapshot: Codable, Identifiable {
    var id: String { provider.rawValue }
    let provider: Provider
    var windows: [UsageWindow]
    var account: String?
    var lastSuccess: Date
    var error: String?
    var isStale: Bool { error != nil }
}

enum ProviderFailure: LocalizedError {
    case credentials(String), http(Int), invalidResponse(String), process(String)
    var errorDescription: String? {
        switch self {
        case .credentials(let s), .invalidResponse(let s), .process(let s): s
        case .http(401), .http(403): "Authentication expired or access was denied."
        case .http(429): "Rate limited. Try again later."
        case .http(let code): "Service returned HTTP \(code)."
        }
    }
}

enum UsageParsing {
    static func claude(_ data: Data, now: Date = .now) throws -> [UsageWindow] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFailure.invalidResponse("Claude returned malformed usage data.")
        }
        let source = (root["utilization"] as? [String: Any])
            ?? (root["rate_limits"] as? [String: Any])
            ?? (root["rateLimits"] as? [String: Any])
            ?? root
        var result: [UsageWindow] = []
        for (key, label) in [("five_hour", "Session"), ("seven_day", "Weekly"), ("seven_day_sonnet", "Sonnet weekly"), ("seven_day_opus", "Opus weekly")] {
            guard let item = source[key] as? [String: Any],
                  let amount = number(item["utilization"] ?? item["used_percentage"] ?? item["usedPercentage"]) else { continue }
            result.append(UsageWindow(label: label, utilization: min(100, max(0, amount)), resetsAt: date(item["resets_at"] ?? item["resetsAt"])))
        }
        guard !result.isEmpty else {
            let keys = root.keys.sorted().joined(separator: ", ")
            let nestedKeys = ["utilization", "rate_limits", "rateLimits"].compactMap { root[$0] as? [String: Any] }
                .flatMap { $0.keys }.sorted().joined(separator: ", ")
            let details = nestedKeys.isEmpty ? keys : "\(keys) (nested: \(nestedKeys))"
            throw ProviderFailure.invalidResponse("Claude returned no recognized usage windows. Response fields: \(details.isEmpty ? "none" : details).")
        }
        return result
    }

    static func codex(_ data: Data) throws -> (windows: [UsageWindow], account: String?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFailure.invalidResponse("Codex returned malformed usage data.")
        }
        // app-server account/rateLimits replies have evolved; accept either a direct object or a JSON-RPC result.
        let value = (root["result"] as? [String: Any]) ?? root
        let account = (value["email"] as? String) ?? (value["account"] as? [String: Any])?["email"] as? String
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
            for (key, fallbackLabel) in [("primary", "5 hour"), ("secondary", "Weekly")] {
                guard let item = limits[key] as? [String: Any], let amount = number(item["usedPercent"] ?? item["used_percent"]) else { continue }
                var duration = number(item["windowDurationMins"] ?? item["window_duration_mins"])
                if duration == nil, let seconds = number(item["windowDurationSeconds"] ?? item["window_duration_seconds"]) { duration = (seconds + 59) / 60 }
                let resolvedLabel = duration.map { $0 >= 8_640 ? "Weekly" : ($0 >= 180 ? "Session" : fallbackLabel) } ?? fallbackLabel
                windows.append(UsageWindow(label: resolvedLabel, utilization: min(100, max(0, amount)), resetsAt: date(item["resetsAt"] ?? item["resets_at"])))
            }
        }
        guard !windows.isEmpty else { throw ProviderFailure.invalidResponse("Codex returned no recognized rate limits.") }
        return (windows, account)
    }

    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
    private static func date(_ value: Any?) -> Date? {
        if let seconds = value as? NSNumber { return Date(timeIntervalSince1970: seconds.doubleValue) }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string) ?? formatter.date(from: string + "Z")
    }
}
