import Foundation

struct TokenUsageRecord: Identifiable, Hashable, Sendable {
    let id: String
    let provider: Provider
    let timestamp: Date
    let sessionID: String
    let project: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheWriteTokens: Int
    let cacheReadTokens: Int
    /// Local model-equivalent estimate supplied by Claude Code, not a bill.
    let estimatedCostUSD: Double?

    var totalTokens: Int { inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens }
}

struct TokenUsageReportResult: Sendable {
    let records: [TokenUsageRecord]
    let scannedFiles: Int
    let unreadableFiles: Int
    let scannedAt: Date
}

enum TokenUsageReportScanner {
    private struct ClaudeKey: Hashable {
        let sessionID: String
        let messageID: String
        let requestID: String
        let lineFallback: String
    }

    static func scan(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> TokenUsageReportResult {
        var records: [TokenUsageRecord] = []
        var scannedFiles = 0
        var unreadableFiles = 0
        let environment = ProcessInfo.processInfo.environment
        let claudeConfig = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        let roots: [(Provider, URL)] = [
            (.claude, (claudeConfig ?? homeDirectory.appendingPathComponent(".claude", isDirectory: true)).appendingPathComponent("projects", isDirectory: true)),
            (.claude, homeDirectory.appendingPathComponent(".config/claude/projects", isDirectory: true)),
            (.codex, (codexHome ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)).appendingPathComponent("sessions", isDirectory: true)),
        ]
        var providersByPath: [URL: Provider] = [:]
        for (provider, root) in roots {
            for path in jsonlFiles(at: root).map(\.standardizedFileURL) where providersByPath[path] == nil {
                providersByPath[path] = provider
            }
        }
        let uniquePaths = providersByPath.keys.sorted { $0.path < $1.path }

        for path in uniquePaths {
            scannedFiles += 1
            do {
                let lines = try readJSONLines(at: path)
                if providersByPath[path] == .codex {
                    records.append(contentsOf: parseCodex(lines))
                } else {
                    records.append(contentsOf: parseClaude(lines, fallbackSessionID: path.deletingPathExtension().lastPathComponent))
                }
            } catch {
                unreadableFiles += 1
            }
        }
        return TokenUsageReportResult(records: records.sorted { $0.timestamp < $1.timestamp }, scannedFiles: scannedFiles, unreadableFiles: unreadableFiles, scannedAt: .now)
    }

    static func parseClaude(_ lines: [Data], fallbackSessionID: String = "unknown") -> [TokenUsageRecord] {
        var recordsByKey: [ClaudeKey: TokenUsageRecord] = [:]
        for (lineIndex, line) in lines.enumerated() {
            guard let row = jsonObject(line), row["type"] as? String == "assistant",
                  let message = row["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let timestamp = parseDate(row["timestamp"] as? String) else { continue }
            let input = integer(usage["input_tokens"])
            let output = integer(usage["output_tokens"])
            let cacheWrite = integer(usage["cache_creation_input_tokens"])
            let cacheRead = integer(usage["cache_read_input_tokens"])
            guard input + output + cacheWrite + cacheRead > 0 else { continue }

            let sessionID = nonEmpty(row["sessionId"] as? String) ?? fallbackSessionID
            let messageID = message["id"] as? String ?? ""
            let requestID = row["requestId"] as? String ?? ""
            let key = ClaudeKey(
                sessionID: sessionID,
                messageID: messageID,
                requestID: requestID,
                lineFallback: messageID.isEmpty && requestID.isEmpty ? String(lineIndex) : ""
            )
            let cwd = nonEmpty(row["cwd"] as? String)
            let model = nonEmpty(message["model"] as? String) ?? "Unknown model"
            let record = TokenUsageRecord(
                id: "claude|\(sessionID)|\(messageID)|\(requestID)|\(key.lineFallback)",
                provider: .claude,
                timestamp: timestamp,
                sessionID: sessionID,
                project: cwd.map(projectName(from:)) ?? "Unknown project",
                model: model,
                inputTokens: input,
                outputTokens: output,
                cacheWriteTokens: cacheWrite,
                cacheReadTokens: cacheRead,
                estimatedCostUSD: finiteDouble(row["costUSD"])
            )
            if let existing = recordsByKey[key] {
                recordsByKey[key] = TokenUsageRecord(
                    id: record.id,
                    provider: .claude,
                    timestamp: min(existing.timestamp, record.timestamp),
                    sessionID: sessionID,
                    project: existing.project == "Unknown project" ? record.project : existing.project,
                    model: record.model,
                    inputTokens: max(existing.inputTokens, input),
                    outputTokens: max(existing.outputTokens, output),
                    cacheWriteTokens: max(existing.cacheWriteTokens, cacheWrite),
                    cacheReadTokens: max(existing.cacheReadTokens, cacheRead),
                    estimatedCostUSD: maxOptional(existing.estimatedCostUSD, record.estimatedCostUSD)
                )
            } else {
                recordsByKey[key] = record
            }
        }
        return Array(recordsByKey.values)
    }

    static func parseCodex(_ lines: [Data]) -> [TokenUsageRecord] {
        var sessionID = "unknown"
        var project = "Unknown project"
        var model = "Unknown model"
        var previousInput = 0
        var previousOutput = 0
        var previousCached = 0
        var index = 0
        var records: [TokenUsageRecord] = []

        for line in lines {
            guard let row = jsonObject(line) else { continue }
            switch row["type"] as? String {
            case "session_meta":
                let payload = row["payload"] as? [String: Any] ?? [:]
                sessionID = nonEmpty(payload["id"] as? String) ?? sessionID
                project = (payload["cwd"] as? String).map(projectName(from:)) ?? project
                model = nonEmpty(payload["model"] as? String) ?? model
            case "turn_context":
                let payload = row["payload"] as? [String: Any] ?? [:]
                model = nonEmpty(payload["model"] as? String) ?? model
            case "event_msg":
                let payload = row["payload"] as? [String: Any] ?? [:]
                guard payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let usage = info["total_token_usage"] as? [String: Any],
                      let timestamp = parseDate(row["timestamp"] as? String) else { continue }
                let totalInput = integer(usage["input_tokens"])
                let totalOutput = integer(usage["output_tokens"])
                let totalCached = integer(usage["cached_input_tokens"])
                let inputDelta = max(0, totalInput - totalCached - previousInput)
                let outputDelta = max(0, totalOutput - previousOutput)
                let cachedDelta = max(0, totalCached - previousCached)
                previousInput = max(0, totalInput - totalCached)
                previousOutput = totalOutput
                previousCached = totalCached
                guard inputDelta + outputDelta + cachedDelta > 0 else { continue }
                index += 1
                records.append(TokenUsageRecord(
                    id: "codex|\(sessionID)|\(index)",
                    provider: .codex,
                    timestamp: timestamp,
                    sessionID: sessionID,
                    project: project,
                    model: model,
                    inputTokens: inputDelta,
                    outputTokens: outputDelta,
                    cacheWriteTokens: 0,
                    cacheReadTokens: cachedDelta,
                    estimatedCostUSD: nil
                ))
            default:
                continue
            }
        }
        return records
    }

    private static func jsonlFiles(at root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "jsonl",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return url
        }
    }

    private static func readJSONLines(at url: URL) throws -> [Data] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        var lines: [Data] = []
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newline]
                if !line.isEmpty { lines.append(Data(line)) }
                pending.removeSubrange(...newline)
            }
            // Ignore a malformed oversized line instead of allowing one log row to consume unbounded memory.
            if pending.count > 4 * 1024 * 1024 { pending.removeAll(keepingCapacity: false) }
        }
        if !pending.isEmpty { lines.append(pending) }
        return lines
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        return regular.date(from: value)
    }

    private static func integer(_ value: Any?) -> Int {
        guard let value, !(value is Bool), let number = value as? NSNumber else { return 0 }
        let double = number.doubleValue
        guard double.isFinite, double > 0, double < Double(Int.max) else { return 0 }
        return Int(double)
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        guard let value, !(value is Bool), let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite && result >= 0 ? result : nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func projectName(from path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? "Unknown project" : name
    }

    private static func maxOptional(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case let (left?, right?): max(left, right)
        case let (left?, nil): left
        case let (nil, right?): right
        case (nil, nil): nil
        }
    }
}

enum TokenUsageReportGrouping: String, CaseIterable, Identifiable, Sendable, Equatable {
    case day = "Day"
    case provider = "Provider"
    case model = "Model"
    case project = "Project"
    case session = "Session"

    var id: String { rawValue }
}

enum TokenUsageReportRange: String, CaseIterable, Identifiable, Sendable, Equatable {
    case sevenDays = "7 days"
    case thirtyDays = "30 days"
    case all = "All time"

    var id: String { rawValue }
    func includes(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Bool {
        switch self {
        case .all: true
        case .sevenDays: date >= calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now))!
        case .thirtyDays: date >= calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: now))!
        }
    }
}

struct TokenUsageReportRow: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheTokens: Int
    let estimatedCostUSD: Double
    let pricedRecords: Int
    let recordCount: Int

    var totalTokens: Int { inputTokens + outputTokens + cacheTokens }
}

enum TokenUsageReportAggregation {
    static func rows(
        records: [TokenUsageRecord],
        grouping: TokenUsageReportGrouping,
        range: TokenUsageReportRange,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [TokenUsageReportRow] {
        let filtered = records.filter { range.includes($0.timestamp, now: now, calendar: calendar) }
        let groups = Dictionary(grouping: filtered) { record -> String in
            switch grouping {
            case .day: dayKey(record.timestamp, calendar: calendar)
            case .provider: record.provider.displayName
            case .model: "\(record.provider.displayName)|\(record.model)"
            case .project: record.project
            case .session: "\(record.provider.rawValue)|\(record.sessionID)"
            }
        }
        return groups.map { key, items in
            let first = items[0]
            let title: String
            let detail: String
            switch grouping {
            case .day:
                title = first.timestamp.formatted(date: .abbreviated, time: .omitted)
                detail = "\(items.count) usage events"
            case .provider:
                title = first.provider.displayName
                detail = "\(items.count) usage events"
            case .model:
                title = first.model
                detail = first.provider.displayName
            case .project:
                title = first.project
                detail = "\(Set(items.map(\.sessionID)).count) sessions"
            case .session:
                title = String(first.sessionID.prefix(12))
                detail = "\(first.project) · \(first.provider.displayName) · \(Set(items.map(\.model)).sorted().joined(separator: ", "))"
            }
            return TokenUsageReportRow(
                id: key,
                title: title,
                detail: detail,
                inputTokens: items.reduce(0) { $0 + $1.inputTokens },
                outputTokens: items.reduce(0) { $0 + $1.outputTokens },
                cacheTokens: items.reduce(0) { $0 + $1.cacheWriteTokens + $1.cacheReadTokens },
                estimatedCostUSD: items.compactMap(\.estimatedCostUSD).reduce(0, +),
                pricedRecords: items.filter { $0.estimatedCostUSD != nil }.count,
                recordCount: items.count
            )
        }.sorted { left, right in
            if grouping == .day { return left.id > right.id }
            return left.totalTokens == right.totalTokens ? left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending : left.totalTokens > right.totalTokens
        }
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
