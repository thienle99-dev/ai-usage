import SwiftUI

struct UsageReportView: View {
    @State private var result: TokenUsageReportResult?
    @State private var grouping: TokenUsageReportGrouping = .day
    @State private var range: TokenUsageReportRange = .thirtyDays
    @State private var scanning = false

    private var rows: [TokenUsageReportRow] {
        guard let result else { return [] }
        return TokenUsageReportAggregation.rows(records: result.records, grouping: grouping, range: range)
    }

    private var filteredRecords: [TokenUsageRecord] {
        guard let result else { return [] }
        return result.records.filter { range.includes($0.timestamp) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            disclosure
            if let result {
                summary(result)
                controls
                if rows.isEmpty {
                    ContentUnavailableView("No token usage found", systemImage: "chart.bar", description: Text("No supported Claude Code or Codex usage was found for this period."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    reportTable
                }
                footer(result)
            } else {
                Spacer(minLength: 0)
                ContentUnavailableView("Scan local usage logs", systemImage: "doc.text.magnifyingglass", description: Text("Choose Scan to read token counts and session metadata from Claude Code and Codex logs on this Mac."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Spacer(minLength: 0)
            }
        }
        .padding(22)
        .frame(minWidth: 760, idealWidth: 880, minHeight: 560, idealHeight: 680)
        .background(UsageTheme.background)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(UsageTheme.codex)
                .frame(width: 38, height: 38)
                .background(UsageTheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Token & Cost Report")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(UsageTheme.primaryText)
                Text("Local usage history · no quota or model requests")
                    .font(.system(size: 11))
                    .foregroundStyle(UsageTheme.secondaryText)
            }
            Spacer()
            Button {
                scan()
            } label: {
                if scanning {
                    ProgressView().controlSize(.small)
                } else {
                    Label(result == nil ? "Scan local logs" : "Rescan", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(UsageTheme.codex)
            .disabled(scanning)
        }
    }

    private var disclosure: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(UsageTheme.secondaryText)
            Text("Scans Claude Code and Codex JSONL logs only after you press Scan. It reads token counts, model, date, project folder and session ID; message text is not shown or saved by this report. Other providers do not expose per-request token usage here.")
                .font(.system(size: 11))
                .foregroundStyle(UsageTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UsageTheme.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func summary(_ scan: TokenUsageReportResult) -> some View {
        let records = filteredRecords
        let tokens = records.reduce(0) { $0 + $1.totalTokens }
        let sessions = Set(records.map { "\($0.provider.rawValue)|\($0.sessionID)" }).count
        let estimatedCost = records.compactMap(\.estimatedCostUSD).reduce(0, +)
        let priced = records.filter { $0.estimatedCostUSD != nil }.count
        return HStack(spacing: 10) {
            summaryMetric("Tokens", value: tokens.formatted())
            summaryMetric("Sessions", value: sessions.formatted())
            summaryMetric("Estimated cost", value: priced > 0 ? String(format: "$%.4f", estimatedCost) : "—")
        }
        .overlay(alignment: .bottomLeading) {
            Text(priced > 0 ? "Claude Code local estimate · (priced) of (records.count) events priced · not billing data" : "No local cost estimate is available for these records.")
                .font(.system(size: 9.5))
                .foregroundStyle(UsageTheme.mutedText)
                .offset(y: 14)
        }
        .padding(.bottom, 15)
    }

    private func summaryMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.45).foregroundStyle(UsageTheme.mutedText)
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(UsageTheme.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(UsageTheme.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var controls: some View {
        HStack {
            Picker("Group by", selection: $grouping) {
                ForEach(TokenUsageReportGrouping.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 400)
            Spacer()
            Picker("Date range", selection: $range) {
                ForEach(TokenUsageReportRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(width: 125)
        }
    }

    private var reportTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(grouping.rawValue).frame(maxWidth: .infinity, alignment: .leading)
                Text("Input").frame(width: 80, alignment: .trailing)
                Text("Output").frame(width: 80, alignment: .trailing)
                Text("Cache").frame(width: 80, alignment: .trailing)
                Text("Cost est.").frame(width: 92, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(UsageTheme.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(rows) { row in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.title).font(.system(size: 12, weight: .medium)).foregroundStyle(UsageTheme.primaryText).lineLimit(1)
                                Text(row.detail).font(.system(size: 10)).foregroundStyle(UsageTheme.secondaryText).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            reportNumber(row.inputTokens, width: 80)
                            reportNumber(row.outputTokens, width: 80)
                            reportNumber(row.cacheTokens, width: 80)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(row.pricedRecords > 0 ? String(format: "$%.4f", row.estimatedCostUSD) : "—")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(UsageTheme.primaryText)
                                if row.pricedRecords > 0 && row.pricedRecords < row.recordCount {
                                    Text("partial").font(.system(size: 8)).foregroundStyle(UsageTheme.mutedText)
                                }
                            }
                            .frame(width: 92, alignment: .trailing)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(UsageTheme.card.opacity(0.55))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func reportNumber(_ number: Int, width: CGFloat) -> some View {
        Text(number.formatted())
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(UsageTheme.primaryText)
            .frame(width: width, alignment: .trailing)
    }

    private func footer(_ result: TokenUsageReportResult) -> some View {
        HStack {
            Text("Scanned \(result.scannedFiles) files · \(result.records.count) usage events · \(result.scannedAt.formatted(date: .omitted, time: .shortened))")
            Spacer()
            if result.unreadableFiles > 0 {
                Text("\(result.unreadableFiles) files could not be read")
                    .foregroundStyle(UsageTheme.warning)
            }
        }
        .font(.system(size: 9.5))
        .foregroundStyle(UsageTheme.mutedText)
    }

    private func scan() {
        scanning = true
        Task.detached(priority: .utility) {
            let scanned = TokenUsageReportScanner.scan()
            await MainActor.run {
                result = scanned
                scanning = false
            }
        }
    }
}
