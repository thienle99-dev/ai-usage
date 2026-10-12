import Foundation
import WidgetKit

struct QuotaWidgetPayload: Codable {
    let generatedAt: Date
    let providers: [QuotaWidgetProvider]
}

struct QuotaWidgetProvider: Codable, Identifiable {
    let provider: String
    let metric: String
    let utilization: Double
    let resetsAt: Date?
    let stale: Bool

    var id: String { provider }
}

@MainActor enum WidgetSnapshotSharing {
    static let appGroupIdentifier = "group.com.local.aiusage"
    static let widgetKind = "AIUsageQuotaWidget"

    static func write(snapshots: [Provider: UsageSnapshot], order: [Provider], visible: Set<Provider>) {
        guard let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return }

        let providers = order.compactMap { provider -> QuotaWidgetProvider? in
            guard visible.contains(provider),
                  let snapshot = snapshots[provider],
                  let window = snapshot.validWindows.first,
                  let utilization = window.validUtilization else { return nil }
            return QuotaWidgetProvider(
                provider: provider.displayName,
                metric: window.label,
                utilization: utilization,
                resetsAt: window.resetsAt,
                stale: snapshot.isStale
            )
        }
        let payload = QuotaWidgetPayload(generatedAt: .now, providers: providers)
        let url = directory.appendingPathComponent("widget-quota.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        } catch {
            // Widget updates are best-effort and must never interrupt quota refreshes.
        }
    }
}
