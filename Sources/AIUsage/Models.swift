import Foundation

enum UsageCardLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case compactBalanced
    case twoColumns
    case minimalRows
    case collapsible

    var id: String { rawValue }
    var title: String {
        switch self {
        case .compactBalanced: "Compact Balanced"
        case .twoColumns: "Two Columns"
        case .minimalRows: "Minimal Rows"
        case .collapsible: "Collapsible"
        }
    }
    var subtitle: String {
        switch self {
        case .compactBalanced: "Full-width progress bars"
        case .twoColumns: "Side-by-side usage metrics"
        case .minimalRows: "Maximum information density"
        case .collapsible: "Expand details on demand"
        }
    }
    static func preference(_ rawValue: String, fallback: Self) -> Self { Self(rawValue: rawValue) ?? fallback }
}

enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex = "Codex"
    case claude = "Claude"
    case cursor = "Cursor"
    case copilot = "Copilot"
    case gemini = "Gemini"
    case antigravity = "Antigravity"
    case grok = "Grok"
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
        case .antigravity: "Google Antigravity"
        case .grok: "Grok CLI"
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
        case .antigravity: "Antigravity"
        case .grok: "Grok"
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
        case .antigravity: "sparkles.rectangle.stack"
        case .grok: "bolt.fill"
        case .windsurf: "wind"
        case .cline: "wrench.and.screwdriver.fill"
        case .roo: "point.3.connected.trianglepath.dotted"
        case .openCode: "chevron.left.forwardslash.chevron.right"
        }
    }
    var isUsageSupported: Bool { [.codex, .claude, .cursor, .copilot, .gemini, .antigravity, .grok, .openCode].contains(self) }
    static let supported: [Provider] = [.codex, .claude, .cursor, .copilot, .gemini, .antigravity, .grok, .openCode]
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
    case singleProvider
    case currentProvider
    case highestUsageProvider
    case frontmostAppProvider

    var id: String { rawValue }
    var title: String {
        switch self {
        case .iconOnly: "Icon only"
        case .combinedUsage: "Combined usage"
        case .providerSpecific: "Provider-specific"
        case .criticalProviderOnly: "Critical provider only"
        case .singleProvider: "Single provider"
        case .currentProvider: "Current provider"
        case .highestUsageProvider: "Highest usage provider"
        case .frontmostAppProvider: "Active app"
        }
    }

    static let quickSwitchSources: [Self] = [.currentProvider, .highestUsageProvider, .frontmostAppProvider]

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
    /// Stable account identity (email preferred, else provider account id).
    /// Used to detect external account swaps (e.g. a different folder moved
    /// into `~/.codex`). Missing keys in old caches decode as nil.
    var accountID: String? = nil
    var lastSuccess: Date
    var error: String?
    var status: ProviderStatus? = .connected

    var isStale: Bool { error != nil }
    var validWindows: [UsageWindow] { windows.filter { $0.validUtilization != nil } }
}

/// A registered Codex home folder (a full `~/.codex`-style directory with its
/// own `auth.json`). The live home is always `~/.codex` (or `$CODEX_HOME`);
/// switching moves folders between the live location and these stash slots.
/// Credential contents are never read or written — only folders move.
struct CodexHome: Codable, Identifiable, Sendable, Equatable {
    /// Normalized absolute path of the stash slot. Stable id for ForEach.
    var id: String { path }
    var path: String
    var lastSeenAccountID: String?
    var lastSeenEmail: String?
    var lastSeenAt: Date?

    var displayName: String {
        if let email = lastSeenEmail?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            return email
        }
        return (path as NSString).lastPathComponent
    }
}

enum CodexHomeError: LocalizedError, Sendable, Equatable {
    case notDirectory
    case missingAuthFile
    case duplicate
    case isLiveHome
    case crossVolume
    case unknownLiveHome
    case busy
    case occupiedSlot(String)
    case leftoverSwapFolder(String)
    case moveFailed(String)
    case identityMismatch(expected: String, found: String)

    var errorDescription: String? {
        switch self {
        case .notDirectory:
            "Choose a folder. That path is not a directory."
        case .missingAuthFile:
            "That folder has no auth.json. Choose a complete Codex home folder."
        case .duplicate:
            "That folder is already registered."
        case .isLiveHome:
            "That is the live Codex home. Register the folder's original location instead."
        case .crossVolume:
            "That folder is on a different disk. Keep all homes on the same disk so switches stay atomic."
        case .unknownLiveHome:
            "The live folder doesn't match any registered home. Refresh to identify it, or move a registered home into place manually first."
        case .busy:
            "Codex is busy. Try again in a moment."
        case .occupiedSlot(let path):
            "That location is occupied. Pick a name that doesn't exist yet, or move it aside first."
        case .leftoverSwapFolder(let path):
            "A leftover swap folder blocks switching: \(path). Inspect it, then move it aside."
        case .moveFailed(let detail):
            "Could not move folders: \(detail)"
        case .identityMismatch(let expected, let found):
            "Switched folders, but the live account (\(found)) isn't the expected one (\(expected)). Everything was moved back."
        }
    }
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

/// Pure menu-bar content for a display mode. Kept free of SwiftUI so the
/// selection and fallback rules are unit-testable; MenuBarStatusView renders it.
enum MenuBarContent {
    static func sourceProvider(
        mode: MenuBarDisplayMode,
        currentProvider: Provider?,
        frontmostAppProvider: Provider?,
        snapshots: [Provider: UsageSnapshot],
        enabled: Set<Provider>
    ) -> Provider? {
        switch mode {
        case .currentProvider:
            return usable(currentProvider, enabled: enabled) ?? highestUsageProvider(in: snapshots, enabled: enabled)
        case .highestUsageProvider:
            return highestUsageProvider(in: snapshots, enabled: enabled)
        case .frontmostAppProvider:
            return usable(frontmostAppProvider, enabled: enabled)
                ?? usable(currentProvider, enabled: enabled)
                ?? highestUsageProvider(in: snapshots, enabled: enabled)
        default:
            return nil
        }
    }

    static func text(
        mode: MenuBarDisplayMode,
        selectedProvider: Provider,
        snapshots: [Provider: UsageSnapshot],
        enabled: Set<Provider>,
        criticalThreshold: Double,
        currentProvider: Provider? = nil,
        frontmostAppProvider: Provider? = nil
    ) -> String {
        switch mode {
        case .iconOnly:
            return ""
        case .combinedUsage:
            return UsageAggregation.maximum(in: snapshots, enabled: enabled).map { "\(Int($0.rounded()))%" } ?? ""
        case .providerSpecific:
            return Provider.allCases.compactMap { provider in
                UsageAggregation.maximum(for: provider, in: snapshots, enabled: enabled)
                    .map { "\(provider.menuBarAbbreviation) \(Int($0.rounded()))%" }
            }.joined(separator: " · ")
        case .criticalProviderOnly:
            return criticalProviders(in: snapshots, enabled: enabled, threshold: criticalThreshold)
                .map(\.menuBarAbbreviation).joined(separator: " · ")
        case .singleProvider:
            if !enabled.contains(selectedProvider) {
                // The chosen provider is hidden: fall back like combined usage.
                return text(mode: .combinedUsage, selectedProvider: selectedProvider, snapshots: snapshots, enabled: enabled, criticalThreshold: criticalThreshold)
            } else if let usage = UsageAggregation.maximum(for: selectedProvider, in: snapshots, enabled: enabled) {
                return "\(selectedProvider.menuBarAbbreviation) \(Int(usage.rounded()))%"
            } else {
                return selectedProvider.menuBarAbbreviation
            }
        case .currentProvider, .highestUsageProvider, .frontmostAppProvider:
            guard let provider = sourceProvider(
                mode: mode,
                currentProvider: currentProvider,
                frontmostAppProvider: frontmostAppProvider,
                snapshots: snapshots,
                enabled: enabled
            ) else { return "" }
            if let usage = UsageAggregation.maximum(for: provider, in: snapshots, enabled: enabled) {
                return "\(provider.menuBarAbbreviation) \(Int(usage.rounded()))%"
            } else {
                return provider.menuBarAbbreviation
            }
        }
    }

    static func symbolName(
        mode: MenuBarDisplayMode,
        selectedProvider: Provider,
        snapshots: [Provider: UsageSnapshot],
        enabled: Set<Provider>,
        criticalThreshold: Double,
        currentProvider: Provider? = nil,
        frontmostAppProvider: Provider? = nil
    ) -> String {
        switch mode {
        case .singleProvider:
            selectedProvider.systemImage
        case .currentProvider, .highestUsageProvider, .frontmostAppProvider:
            sourceProvider(
                mode: mode,
                currentProvider: currentProvider,
                frontmostAppProvider: frontmostAppProvider,
                snapshots: snapshots,
                enabled: enabled
            )?.systemImage ?? "chart.bar.fill"
        case .criticalProviderOnly
            where !criticalProviders(in: snapshots, enabled: enabled, threshold: criticalThreshold).isEmpty:
            "exclamationmark.triangle.fill"
        default:
            "chart.bar.fill"
        }
    }

    private static func criticalProviders(
        in snapshots: [Provider: UsageSnapshot],
        enabled: Set<Provider>,
        threshold: Double
    ) -> [Provider] {
        Provider.allCases.compactMap { provider in
            guard let usage = UsageAggregation.maximum(for: provider, in: snapshots, enabled: enabled),
                  usage >= threshold else { return nil }
            return provider
        }
    }

    private static func usable(_ provider: Provider?, enabled: Set<Provider>) -> Provider? {
        guard let provider, enabled.contains(provider) else { return nil }
        return provider
    }

    private static func highestUsageProvider(
        in snapshots: [Provider: UsageSnapshot],
        enabled: Set<Provider>
    ) -> Provider? {
        var highest: (provider: Provider, utilization: Double)?
        for provider in Provider.supported where enabled.contains(provider) {
            guard let utilization = UsageAggregation.maximum(for: provider, in: snapshots, enabled: enabled) else { continue }
            if let current = highest, utilization <= current.utilization { continue }
            highest = (provider, utilization)
        }
        return highest?.provider
    }
}

enum FrontmostApplicationProvider {
    static func provider(bundleIdentifier: String?, localizedName: String?, processName: String? = nil) -> Provider? {
        let identity = [bundleIdentifier, localizedName, processName]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if identity.contains("antigravity") { return .antigravity }
        if identity.contains("cursor") { return .cursor }
        if identity.contains("claude") { return .claude }
        if identity.contains("codex") { return .codex }
        if identity.contains("gemini") { return .gemini }
        if identity.contains("copilot") { return .copilot }
        if identity.contains("grok") { return .grok }
        if identity.contains("opencode") { return .openCode }
        return nil
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
    static func cursor(_ data: Data) throws -> [UsageWindow] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderFailure.invalidResponse("Cursor returned malformed usage data.")
        }
        guard let individual = root["individualUsage"] as? [String: Any] else {
            throw ProviderFailure.invalidResponse("Cursor returned an unrecognized usage response.")
        }
        let plan = individual["plan"] as? [String: Any]
        let reset = date(root["billingCycleEnd"])
        let used = number(plan?["used"])
        let limit = number(plan?["limit"])
        let planDetail: String? = if let used, let limit, used >= 0, limit > 0 {
            "\(currency(used / 100)) / \(currency(limit / 100)) included this cycle"
        } else { nil }

        var windows: [UsageWindow] = []
        if let total = number(plan?["totalPercentUsed"]) {
            windows.append(UsageWindow(label: "Plan usage", utilization: total, resetsAt: reset, detail: planDetail))
        } else {
            if let auto = number(plan?["autoPercentUsed"]) {
                windows.append(UsageWindow(label: "Auto + Composer", utilization: auto, resetsAt: reset))
            }
            if let api = number(plan?["apiPercentUsed"]) {
                windows.append(UsageWindow(label: "API models", utilization: api, resetsAt: reset))
            }
        }
        if let auto = number(plan?["autoPercentUsed"]), number(plan?["totalPercentUsed"]) != nil {
            windows.append(UsageWindow(label: "Auto + Composer", utilization: auto, resetsAt: reset))
        }
        if let api = number(plan?["apiPercentUsed"]), number(plan?["totalPercentUsed"]) != nil {
            windows.append(UsageWindow(label: "API models", utilization: api, resetsAt: reset))
        }

        let onDemand = (individual["onDemand"] as? [String: Any])
        let teamOnDemand = ((root["teamUsage"] as? [String: Any])?["onDemand"] as? [String: Any])
        let onDemandUsed = ((onDemand?["enabled"] as? Bool) == true ? number(onDemand?["used"]) : nil)
            ?? number(teamOnDemand?["used"])
        let onDemandLimit = ((onDemand?["enabled"] as? Bool) == true ? number(onDemand?["limit"]) : nil)
            ?? number(teamOnDemand?["limit"])
        if let onDemandUsed, onDemandUsed >= 0 {
            let percent = onDemandLimit.flatMap { $0 > 0 ? onDemandUsed / $0 * 100 : nil } ?? -1
            let detail = onDemandLimit.map { "\(currency(onDemandUsed / 100)) / \(currency($0 / 100))" }
                ?? "\(currency(onDemandUsed / 100)) spent this cycle"
            windows.append(UsageWindow(label: "On-demand usage", utilization: percent, resetsAt: reset, detail: detail))
        }

        if windows.isEmpty {
            let overall = individual["overall"] as? [String: Any]
            let pooled = ((root["teamUsage"] as? [String: Any])?["pooled"] as? [String: Any])
            let budget = overall ?? pooled
            if let budget, let amount = number(budget["used"]), amount >= 0 {
                let cap = number(budget["limit"])
                let percent = cap.flatMap { $0 > 0 ? amount / $0 * 100 : nil } ?? -1
                let detail = cap.map { "\(currency(amount / 100)) / \(currency($0 / 100)) this cycle" }
                    ?? "\(currency(amount / 100)) spent this cycle"
                windows.append(UsageWindow(label: overall == nil ? "Team pool" : "Account usage", utilization: percent, resetsAt: reset, detail: detail))
            }
        }

        if windows.isEmpty, root["individualUsage"] == nil, root["teamUsage"] == nil {
            throw ProviderFailure.invalidResponse("Cursor returned no recognized usage windows.")
        }
        return windows
    }

    static func cursorAccount(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let value = (root["user"] as? [String: Any]) ?? root
        let email = (value["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (value["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = [email, name].compactMap { $0 }.first(where: { !$0.isEmpty })
        return identity
    }

    static func cursorPlan(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let plan = (root["membershipType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !plan.isEmpty else { return nil }
        return plan.capitalized
    }

    private static func currency(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "$%.2f", amount)
    }

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

    static func codex(_ data: Data) throws -> (windows: [UsageWindow], account: String?, accountID: String?) {
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
        return (Array(unique.values).sorted { $0.label < $1.label }, account.isEmpty ? nil : account, codexAccountID(value: value, account: accountObject))
    }

    /// Stable Codex account identity for swap detection: email preferred,
    /// otherwise an explicit provider account/user id. Only string values are
    /// accepted so numeric JSON-RPC ids can never become an identity. Missing
    /// identity stays nil so callers keep the previously bound account.
    private static func codexAccountID(value: [String: Any], account: [String: Any]?) -> String? {
        let candidates: [Any?] = [
            value["email"], account?["email"],
            value["account_id"], account?["account_id"],
            value["accountId"], account?["accountId"],
            value["user_id"], account?["user_id"],
            value["userId"], account?["userId"],
        ]
        for candidate in candidates {
            if let id = candidate as? String {
                let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
    private static func date(_ value: Any?) -> Date? {
        if let seconds = value as? NSNumber { return Date(timeIntervalSince1970: seconds.doubleValue) }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string) ?? formatter.date(from: string + "Z")
    }
}
