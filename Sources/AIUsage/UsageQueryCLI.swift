import Foundation

enum UsageQueryCLI {
    enum OutputFormat: String {
        case text
        case json
    }

    struct QuotaPayload: Encodable {
        let generatedAt: Date
        let source: String
        let providers: [QuotaProviderPayload]

        enum CodingKeys: String, CodingKey {
            case generatedAt = "generated_at"
            case source
            case providers
        }
    }

    struct QuotaProviderPayload: Encodable {
        let id: String
        let name: String
        let status: String
        let stale: Bool
        let account: String?
        let lastSuccess: Date?
        let ageSeconds: Int?
        let windows: [QuotaWindowPayload]

        enum CodingKeys: String, CodingKey {
            case id, name, status, stale, account, windows
            case lastSuccess = "last_success"
            case ageSeconds = "age_seconds"
        }
    }

    struct QuotaWindowPayload: Encodable {
        let label: String
        let usedPercent: Double?
        let remainingPercent: Double?
        let resetsAt: Date?
        let detail: String?

        enum CodingKeys: String, CodingKey {
            case label, detail
            case usedPercent = "used_percent"
            case remainingPercent = "remaining_percent"
            case resetsAt = "resets_at"
        }
    }

    struct ReportPayload: Encodable {
        struct Row: Encodable {
            let title: String
            let detail: String
            let inputTokens: Int
            let outputTokens: Int
            let cacheTokens: Int
            let totalTokens: Int
            let estimatedCostUSD: Double?
            let costIsEstimate: Bool
            let pricedRecords: Int
            let recordCount: Int

            enum CodingKeys: String, CodingKey {
                case title, detail
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheTokens = "cache_tokens"
                case totalTokens = "total_tokens"
                case estimatedCostUSD = "estimated_cost_usd"
                case costIsEstimate = "cost_is_estimate"
                case pricedRecords = "priced_records"
                case recordCount = "record_count"
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(title, forKey: .title)
                try container.encode(detail, forKey: .detail)
                try container.encode(inputTokens, forKey: .inputTokens)
                try container.encode(outputTokens, forKey: .outputTokens)
                try container.encode(cacheTokens, forKey: .cacheTokens)
                try container.encode(totalTokens, forKey: .totalTokens)
                try container.encode(estimatedCostUSD, forKey: .estimatedCostUSD)
                try container.encode(costIsEstimate, forKey: .costIsEstimate)
                try container.encode(pricedRecords, forKey: .pricedRecords)
                try container.encode(recordCount, forKey: .recordCount)
            }
        }

        let generatedAt: Date
        let source: String
        let range: String
        let group: String
        let scannedFiles: Int
        let unreadableFiles: Int
        let recordCount: Int
        let rows: [Row]

        enum CodingKeys: String, CodingKey {
            case source, range, group, rows
            case generatedAt = "generated_at"
            case scannedFiles = "scanned_files"
            case unreadableFiles = "unreadable_files"
            case recordCount = "record_count"
        }
    }

    struct TokenWastePayload: Encodable {
        struct Coverage: Encodable {
            let scannedFiles: Int
            let skippedFiles: Int
            let candidateScanCapped: Bool
            let truncatedFiles: Int
            let unreadableFiles: Int
            let oversizedLines: Int
            let bytesRead: Int

            enum CodingKeys: String, CodingKey {
                case scannedFiles = "scanned_files"
                case skippedFiles = "skipped_files"
                case candidateScanCapped = "candidate_scan_capped"
                case truncatedFiles = "truncated_files"
                case unreadableFiles = "unreadable_files"
                case oversizedLines = "oversized_lines"
                case bytesRead = "bytes_read"
            }
        }

        struct Findings: Encodable {
            struct RepeatedReads: Encodable {
                let repeatedTargets: Int
                let redundantCalls: Int
                let repeatedOutputBytes: Int

                enum CodingKeys: String, CodingKey {
                    case repeatedTargets = "repeated_targets"
                    case redundantCalls = "redundant_calls"
                    case repeatedOutputBytes = "repeated_output_bytes"
                }
            }

            struct LargeOutputs: Encodable {
                let calls: Int
                let outputBytes: Int
                let thresholdBytes: Int

                enum CodingKeys: String, CodingKey {
                    case calls
                    case outputBytes = "output_bytes"
                    case thresholdBytes = "threshold_bytes"
                }
            }

            let repeatedReads: RepeatedReads
            let largeOutputs: LargeOutputs

            enum CodingKeys: String, CodingKey {
                case repeatedReads = "repeated_reads"
                case largeOutputs = "large_outputs"
            }
        }

        struct Limits: Encodable {
            let maxFiles: Int
            let maxCandidateFiles: Int
            let maxDirectoryEntries: Int
            let maxFileBytes: Int
            let maxTotalBytes: Int
            let maxLineBytes: Int
            let largeOutputThresholdBytes: Int

            enum CodingKeys: String, CodingKey {
                case maxFiles = "max_files"
                case maxCandidateFiles = "max_candidate_files"
                case maxDirectoryEntries = "max_directory_entries"
                case maxFileBytes = "max_file_bytes"
                case maxTotalBytes = "max_total_bytes"
                case maxLineBytes = "max_line_bytes"
                case largeOutputThresholdBytes = "large_output_threshold_bytes"
            }
        }

        let generatedAt: Date
        let source: String
        let rangeDays: Int
        let coverage: Coverage
        let limits: Limits
        let findings: Findings

        enum CodingKeys: String, CodingKey {
            case source, coverage, limits, findings
            case generatedAt = "generated_at"
            case rangeDays = "range_days"
        }
    }

    private enum CommandError: LocalizedError {
        case usage
        case invalidValue(String, String)

        var errorDescription: String? {
            switch self {
            case .usage:
                "Usage: ai-usage quota [--provider <name>] [--format text|json]\n       ai-usage report [--group day|provider|model|project|session] [--range 7d|30d|all] [--format text|json]\n       ai-usage waste [--range 7d|30d] [--format text|json]"
            case .invalidValue(let option, let value): "Invalid value for \(option): \(value)."
            }
        }
    }

    private static let maximumSnapshotAge: TimeInterval = 15 * 60

    static func run(arguments: [String]) -> Int32 {
        guard let command = arguments.first else { return fail(CommandError.usage) }
        do {
            let options = try parse(Array(arguments.dropFirst()), command: command)
            switch command {
            case "quota":
                let snapshots = readSnapshots()
                let payload = quotaPayload(snapshots: snapshots, provider: options.provider)
                write(payload, format: options.format)
                let cacheAvailable = options.provider.map { provider in
                    snapshots.contains { $0.provider == provider }
                } ?? !snapshots.isEmpty
                return cacheAvailable ? 0 : 3
            case "report":
                let result = TokenUsageReportScanner.scan()
                let payload = reportPayload(result: result, grouping: options.grouping, range: options.range)
                write(payload, format: options.format)
                return 0
            case "waste":
                let result = TokenWasteScanner.scan(rangeDays: options.wasteRangeDays)
                write(tokenWastePayload(result: result), format: options.format)
                return 0
            default:
                throw CommandError.usage
            }
        } catch {
            return fail(error)
        }
    }

    static func quotaPayload(
        snapshots: [UsageSnapshot],
        provider selectedProvider: Provider? = nil,
        now: Date = .now
    ) -> QuotaPayload {
        let byProvider = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.provider, $0) })
        let providers = (selectedProvider.map { [$0] } ?? Provider.supported).map { provider in
            guard let snapshot = byProvider[provider] else {
                return QuotaProviderPayload(
                    id: provider.rawValue,
                    name: provider.displayName,
                    status: "unavailable",
                    stale: true,
                    account: nil,
                    lastSuccess: nil,
                    ageSeconds: nil,
                    windows: []
                )
            }
            let age = snapshot.lastSuccess == .distantPast ? nil : max(0, Int(now.timeIntervalSince(snapshot.lastSuccess)))
            let stale = snapshot.isStale || age.map { Double($0) > maximumSnapshotAge } ?? true
            let status: String
            if snapshot.status == .authenticationRequired { status = "authentication_required" }
            else if snapshot.status == .rateLimited { status = "rate_limited" }
            else if snapshot.status == .error { status = "error" }
            else if snapshot.validWindows.isEmpty { status = "unavailable" }
            else if stale { status = "stale" }
            else { status = "connected" }
            return QuotaProviderPayload(
                id: provider.rawValue,
                name: provider.displayName,
                status: status,
                stale: stale,
                account: snapshot.account,
                lastSuccess: snapshot.lastSuccess == .distantPast ? nil : snapshot.lastSuccess,
                ageSeconds: age,
                windows: snapshot.windows.map { window in
                    let utilization = window.validUtilization
                    return QuotaWindowPayload(
                        label: window.label,
                        usedPercent: utilization,
                        remainingPercent: utilization.map { 100 - $0 },
                        resetsAt: window.resetsAt,
                        detail: window.detail
                    )
                }
            )
        }
        return QuotaPayload(generatedAt: now, source: "local_cache", providers: providers)
    }

    static func reportPayload(
        result: TokenUsageReportResult,
        grouping: TokenUsageReportGrouping,
        range: TokenUsageReportRange,
        now: Date = .now
    ) -> ReportPayload {
        let rows = TokenUsageReportAggregation.rows(records: result.records, grouping: grouping, range: range, now: now).map { row in
            ReportPayload.Row(
                title: row.title,
                detail: row.detail,
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                cacheTokens: row.cacheTokens,
                totalTokens: row.totalTokens,
                estimatedCostUSD: row.pricedRecords > 0 ? row.estimatedCostUSD : nil,
                costIsEstimate: row.pricedRecords > 0,
                pricedRecords: row.pricedRecords,
                recordCount: row.recordCount
            )
        }
        return ReportPayload(
            generatedAt: result.scannedAt,
            source: "local_cli_logs",
            range: range.id,
            group: grouping.id,
            scannedFiles: result.scannedFiles,
            unreadableFiles: result.unreadableFiles,
            recordCount: rows.reduce(0) { $0 + $1.recordCount },
            rows: rows
        )
    }

    static func tokenWastePayload(result: TokenWasteResult) -> TokenWastePayload {
        let configured = TokenWasteResult.Limits.default
        return TokenWastePayload(
            generatedAt: result.generatedAt,
            source: "claude_code_local_logs",
            rangeDays: result.rangeDays,
            coverage: .init(
                scannedFiles: result.scannedFiles,
                skippedFiles: result.skippedFiles,
                candidateScanCapped: result.candidateScanCapped,
                truncatedFiles: result.truncatedFiles,
                unreadableFiles: result.unreadableFiles,
                oversizedLines: result.oversizedLines,
                bytesRead: result.bytesRead
            ),
            limits: .init(
                maxFiles: configured.maxFiles,
                maxCandidateFiles: configured.maxCandidateFiles,
                maxDirectoryEntries: configured.maxDirectoryEntries,
                maxFileBytes: configured.maxFileBytes,
                maxTotalBytes: configured.maxTotalBytes,
                maxLineBytes: configured.maxLineBytes,
                largeOutputThresholdBytes: result.largeOutputs.thresholdBytes
            ),
            findings: .init(
                repeatedReads: .init(
                    repeatedTargets: result.repeatedReads.uniqueTargets,
                    redundantCalls: result.repeatedReads.redundantCalls,
                    repeatedOutputBytes: result.repeatedReads.repeatedOutputBytes
                ),
                largeOutputs: .init(
                    calls: result.largeOutputs.calls,
                    outputBytes: result.largeOutputs.outputBytes,
                    thresholdBytes: result.largeOutputs.thresholdBytes
                )
            )
        )
    }

    private struct Options {
        var provider: Provider?
        var format: OutputFormat = .text
        var grouping: TokenUsageReportGrouping = .provider
        var range: TokenUsageReportRange = .sevenDays
        var wasteRangeDays = 30
    }

    private static func parse(_ arguments: [String], command: String) throws -> Options {
        guard command == "quota" || command == "report" || command == "waste" else { throw CommandError.usage }
        var options = Options()
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw CommandError.usage }
            let key = arguments[index]
            let value = arguments[index + 1]
            switch key {
            case "--provider" where command == "quota":
                guard let provider = Provider.supported.first(where: {
                    $0.rawValue.localizedCaseInsensitiveCompare(value) == .orderedSame
                        || $0.shortName.localizedCaseInsensitiveCompare(value) == .orderedSame
                        || $0.displayName.localizedCaseInsensitiveCompare(value) == .orderedSame
                }) else { throw CommandError.invalidValue(key, value) }
                options.provider = provider
            case "--format":
                guard let format = OutputFormat(rawValue: value.lowercased()) else { throw CommandError.invalidValue(key, value) }
                options.format = format
            case "--group" where command == "report":
                guard let grouping = TokenUsageReportGrouping.allCases.first(where: { $0.rawValue.lowercased() == value.lowercased() }) else {
                    throw CommandError.invalidValue(key, value)
                }
                options.grouping = grouping
            case "--range" where command == "report":
                switch value.lowercased() {
                case "7d", "7days", "7 days": options.range = .sevenDays
                case "30d", "30days", "30 days": options.range = .thirtyDays
                case "all", "all-time", "all time": options.range = .all
                default: throw CommandError.invalidValue(key, value)
                }
            case "--range" where command == "waste":
                switch value.lowercased() {
                case "7d", "7days", "7 days": options.wasteRangeDays = 7
                case "30d", "30days", "30 days": options.wasteRangeDays = 30
                default: throw CommandError.invalidValue(key, value)
                }
            default:
                throw CommandError.invalidValue(key, value)
            }
            index += 2
        }
        return options
    }

    private static func readSnapshots() -> [UsageSnapshot] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIUsage/snapshots.json")
        guard let data = try? Data(contentsOf: url),
              let snapshots = try? JSONDecoder().decode([UsageSnapshot].self, from: data) else { return [] }
        return snapshots
    }

    private static func write<T: Encodable>(_ payload: T, format: OutputFormat) {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(payload) else { return }
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        case .text:
            if let payload = payload as? QuotaPayload { printQuota(payload) }
            else if let payload = payload as? ReportPayload { printReport(payload) }
            else if let payload = payload as? TokenWastePayload { printTokenWaste(payload) }
        }
    }

    private static func printQuota(_ payload: QuotaPayload) {
        for provider in payload.providers {
            guard !provider.windows.isEmpty else {
                print("\(provider.name): \(provider.status)")
                continue
            }
            let account = provider.account.map { " · \($0)" } ?? ""
            let stale = provider.stale ? " · stale" : ""
            let windows = provider.windows.map { window in
                guard let used = window.usedPercent else { return "\(window.label): unavailable" }
                let reset = window.resetsAt.map { " · resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
                return "\(window.label) \(Int(used.rounded()))% used\(reset)"
            }.joined(separator: "; ")
            print("\(provider.name)\(account): \(windows)\(stale)")
        }
    }

    private static func printReport(_ payload: ReportPayload) {
        print("Token report · \(payload.range) · grouped by \(payload.group.lowercased()) · \(payload.recordCount) events")
        for row in payload.rows {
            let cost = row.estimatedCostUSD.map { String(format: " · est. $%.4f", $0) } ?? ""
            print("\(row.title) · \(row.totalTokens) tokens (in \(row.inputTokens), out \(row.outputTokens), cache \(row.cacheTokens))\(cost)")
        }
    }

    private static func printTokenWaste(_ payload: TokenWastePayload) {
        let repeated = payload.findings.repeatedReads
        let large = payload.findings.largeOutputs
        print("Potential token-waste signals · Claude Code · last \(payload.rangeDays) days")
        print("Repeated reads: \(repeated.redundantCalls) extra calls across \(repeated.repeatedTargets) targets · \(repeated.repeatedOutputBytes.formatted()) repeated output bytes")
        print("Large tool outputs: \(large.calls) results over \(large.thresholdBytes.formatted()) bytes · \(large.outputBytes.formatted()) bytes total")
        print("Scan: \(payload.coverage.scannedFiles) files · \(payload.coverage.bytesRead.formatted()) bytes read · \(payload.coverage.truncatedFiles) truncated · \(payload.coverage.skippedFiles) skipped")
        if payload.coverage.candidateScanCapped { print("File discovery stopped at the configured candidate limit.") }
        print("These are review signals, not token or cost estimates. File paths, commands, session IDs, and log contents are not emitted.")
    }

    private static func fail(_ error: Error) -> Int32 {
        FileHandle.standardError.write(Data("ai-usage: \(error.localizedDescription)\n".utf8))
        return 64
    }
}
