import Foundation

/// Reads the latest current-week billing snapshot written by Grok CLI.
/// This provider is local-only and never launches the CLI or makes requests.
struct GrokProvider: UsageProvider {
    let provider = Provider.grok
    private let logURL: URL

    init(homeDirectory: URL? = nil) {
        let home = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        logURL = home.appendingPathComponent(".grok/logs/unified.jsonl")
    }

    func fetch() async throws -> UsageSnapshot {
        guard let result = try GrokParsing.latestQuota(at: logURL, now: .now) else {
            throw ProviderFailure.invalidResponse("No current Grok CLI quota was found. Use Grok CLI and try refreshing again.")
        }
        return UsageSnapshot(
            provider: .grok,
            windows: [UsageWindow(label: "Weekly credits", utilization: result.usedPercent, resetsAt: result.periodEnd)],
            account: result.subscriptionTier,
            lastSuccess: result.fetchedAt
        )
    }
}

struct GrokQuota: Sendable {
    let usedPercent: Double
    let periodEnd: Date
    let fetchedAt: Date
    let subscriptionTier: String?
}

enum GrokParsing {
    static func latestQuota(at url: URL, now: Date) throws -> GrokQuota? {
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().deletingLastPathComponent().path) else { return nil }
        let lines = try tailLines(at: url)
        for line in lines {
            guard let result = quota(from: line) else { continue }
            if result.periodEnd >= now { return result }
            return nil
        }
        return nil
    }

    static func quota(from line: Data) -> GrokQuota? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              root["msg"] as? String == "billing: fetched credits config",
              let fetchedString = root["ts"] as? String,
              let context = root["ctx"] as? [String: Any],
              let config = context["config"] as? [String: Any],
              let period = config["currentPeriod"] as? [String: Any],
              let endString = period["end"] as? String,
              let fetchedAt = date(fetchedString), let periodEnd = date(endString) else { return nil }
        let used: Double
        if let number = config["creditUsagePercent"] as? NSNumber { used = number.doubleValue }
        else if config["creditUsagePercent"] == nil { used = 0 }
        else { return nil }
        guard used.isFinite, (0...100).contains(used) else { return nil }
        return GrokQuota(usedPercent: used, periodEnd: periodEnd, fetchedAt: fetchedAt, subscriptionTier: context["subscriptionTier"] as? String)
    }

    private static func tailLines(at url: URL) throws -> [Data] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let count = min(size, 4 * 1024 * 1024)
        try handle.seek(toOffset: size - count)
        let data = try handle.read(upToCount: Int(count)) ?? Data()
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).suffix(10_000).reversed().map(Data.init)
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
