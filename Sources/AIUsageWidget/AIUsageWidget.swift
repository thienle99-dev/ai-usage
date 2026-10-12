import SwiftUI
import WidgetKit

@main
struct AIUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuotaSummaryWidget()
    }
}

private struct QuotaTimelineEntry: TimelineEntry {
    let date: Date
    let payload: QuotaWidgetPayload
}

private struct QuotaTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuotaTimelineEntry {
        QuotaTimelineEntry(date: .now, payload: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuotaTimelineEntry) -> Void) {
        completion(QuotaTimelineEntry(date: .now, payload: WidgetSnapshotReader.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaTimelineEntry>) -> Void) {
        let entry = QuotaTimelineEntry(date: .now, payload: WidgetSnapshotReader.read())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

private struct QuotaSummaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshotReader.widgetKind, provider: QuotaTimelineProvider()) { entry in
            QuotaWidgetView(payload: entry.payload)
        }
        .configurationDisplayName("AI Usage Quota")
        .description("A summary of cached provider quota usage.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct QuotaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let payload: QuotaWidgetPayload

    var body: some View {
        Group {
            if payload.providers.isEmpty {
                emptyState
            } else if family == .systemSmall {
                smallSummary(payload.providers[0])
            } else {
                mediumSummary
            }
        }
        .containerBackground(.background, for: .widget)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
            Text("No quota data")
                .font(.system(size: 13, weight: .semibold))
            Text("Open AI Usage Monitor to refresh providers.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(12)
    }

    private func smallSummary(_ provider: QuotaWidgetProvider) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Circle().fill(providerAccent(provider.provider)).frame(width: 6, height: 6)
                Text(provider.provider)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(provider.utilization.rounded()))%")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("used").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            ProgressView(value: provider.utilization, total: 100)
                .tint(providerAccent(provider.provider))
            metricFooter(provider)
            if provider.stale { Text("Cached data may be stale").font(.system(size: 9)).foregroundStyle(.orange) }
        }
        .padding(12)
    }

    private var mediumSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("AI Usage")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(payload.providers.prefix(3))) { provider in
                HStack(spacing: 8) {
                    Circle().fill(providerAccent(provider.provider)).frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(provider.provider).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(Int(provider.utilization.rounded()))%")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                        ProgressView(value: provider.utilization, total: 100)
                            .tint(providerAccent(provider.provider))
                    }
                    metricFooter(provider)
                        .frame(width: 74, alignment: .trailing)
                }
            }
            if payload.providers.count > 3 {
                Text("+\(payload.providers.count - 3) more providers")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func metricFooter(_ provider: QuotaWidgetProvider) -> some View {
        HStack(spacing: 3) {
            Text(provider.metric).lineLimit(1)
            if provider.stale {
                Text("· Stale")
            } else if let reset = provider.resetsAt {
                Text("·")
                Text(reset, style: .relative).lineLimit(1)
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
    }

    private func providerAccent(_ provider: String) -> Color {
        switch provider {
        case "OpenAI Codex": Color.teal
        case "Claude Code": Color.orange
        case "GitHub Copilot": Color.blue
        case "Google Antigravity": Color.indigo
        case "Gemini CLI": Color.purple
        default: Color.accentColor
        }
    }
}

private extension QuotaWidgetPayload {
    static var empty: Self { Self(generatedAt: .now, providers: []) }
}

private enum WidgetSnapshotReader {
    static let widgetKind = "AIUsageQuotaWidget"
    static func read() -> QuotaWidgetPayload {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.local.aiusage")?
            .appendingPathComponent("widget-quota.json"),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(QuotaWidgetPayload.self, from: data) else {
            return .empty
        }
        return payload
    }
}

private struct QuotaWidgetPayload: Decodable {
    let generatedAt: Date
    let providers: [QuotaWidgetProvider]
}

private struct QuotaWidgetProvider: Decodable, Identifiable {
    let provider: String
    let metric: String
    let utilization: Double
    let resetsAt: Date?
    let stale: Bool
    var id: String { provider }
}
