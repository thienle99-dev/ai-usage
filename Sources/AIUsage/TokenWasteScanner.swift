import CryptoKit
import Foundation

struct TokenWasteResult: Sendable {
    struct RepeatedReads: Sendable {
        let uniqueTargets: Int
        let redundantCalls: Int
        let repeatedOutputBytes: Int
    }

    struct LargeOutputs: Sendable {
        let calls: Int
        let outputBytes: Int
        let thresholdBytes: Int
    }

    struct Limits: Sendable {
        let maxFiles: Int
        let maxCandidateFiles: Int
        let maxDirectoryEntries: Int
        let maxFileBytes: Int
        let maxTotalBytes: Int
        let maxLineBytes: Int
        let largeOutputThresholdBytes: Int

        static let `default` = Limits(
            maxFiles: 100,
            maxCandidateFiles: 500,
            maxDirectoryEntries: 10_000,
            maxFileBytes: 2 * 1_024 * 1_024,
            maxTotalBytes: 64 * 1_024 * 1_024,
            maxLineBytes: 1 * 1_024 * 1_024,
            largeOutputThresholdBytes: 20 * 1_024
        )
    }

    let generatedAt: Date
    let rangeDays: Int
    let candidateScanCapped: Bool
    let scannedFiles: Int
    let skippedFiles: Int
    let truncatedFiles: Int
    let unreadableFiles: Int
    let oversizedLines: Int
    let bytesRead: Int
    let repeatedReads: RepeatedReads
    let largeOutputs: LargeOutputs
}

enum TokenWasteScanner {
    private struct ReadKey: Hashable {
        let session: String
        let target: String
    }

    private struct PendingCall {
        let session: String
        let target: String?
    }

    private struct Analysis {
        var readResults: [ReadKey: [Int]] = [:]
        var largeOutputCalls = 0
        var largeOutputBytes = 0
        var oversizedLines = 0
    }

    static func scan(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        rangeDays: Int = 30,
        now: Date = .now,
        limits: TokenWasteResult.Limits = .default
    ) -> TokenWasteResult {
        let safeDays = min(30, max(1, rangeDays))
        let environment = ProcessInfo.processInfo.environment
        let claudeConfig = environment["CLAUDE_CONFIG_DIR"].map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        }
        let roots = [
            (claudeConfig ?? homeDirectory.appendingPathComponent(".claude", isDirectory: true))
                .appendingPathComponent("projects", isDirectory: true),
            homeDirectory.appendingPathComponent(".config/claude/projects", isDirectory: true),
        ]
        return scan(roots: roots, rangeDays: safeDays, now: now, limits: limits)
    }

    static func scan(
        roots: [URL],
        rangeDays: Int,
        now: Date = .now,
        limits: TokenWasteResult.Limits = .default
    ) -> TokenWasteResult {
        let safeDays = min(30, max(1, rangeDays))
        var candidatesByPath: [String: (url: URL, modifiedAt: Date)] = [:]
        var candidateLimitReached = false
        let candidateLimit = max(1, limits.maxCandidateFiles)
        var visitedEntries = 0
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            while let item = enumerator.nextObject() {
                visitedEntries += 1
                if visitedEntries > max(1, limits.maxDirectoryEntries) {
                    candidateLimitReached = true
                    break
                }
                guard let url = item as? URL else { continue }
                if url.pathExtension == "jsonl",
                   (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    let path = url.standardizedFileURL.path
                    guard candidatesByPath[path] == nil else { continue }
                    if candidatesByPath.count >= candidateLimit {
                        candidateLimitReached = true
                        break
                    }
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    candidatesByPath[path] = (url, values?.contentModificationDate ?? .distantPast)
                }
            }
            if candidateLimitReached { break }
        }

        let candidates = candidatesByPath.values.sorted {
            if $0.modifiedAt == $1.modifiedAt { return $0.url.path < $1.url.path }
            return $0.modifiedAt > $1.modifiedAt
        }
        let fileLimit = max(1, limits.maxFiles)
        let selected = Array(candidates.prefix(fileLimit))
        var skippedFiles = max(0, candidates.count - selected.count)
        var analysis = Analysis()
        var scannedFiles = 0
        var visitedFiles = 0
        var truncatedFiles = 0
        var unreadableFiles = 0
        var bytesRead = 0
        var remainingBytes = max(0, limits.maxTotalBytes)
        let cutoff = now.addingTimeInterval(-Double(safeDays) * 24 * 60 * 60)

        for candidate in selected {
            guard remainingBytes > 0 else {
                skippedFiles += selected.count - visitedFiles
                break
            }
            visitedFiles += 1
            let fileSize = (try? candidate.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let readLimit = min(max(0, limits.maxFileBytes), remainingBytes)
            guard readLimit > 0 else {
                skippedFiles += selected.count - visitedFiles + 1
                break
            }
            do {
                let read = try readTailLines(at: candidate.url, fileSize: fileSize, limit: readLimit, lineLimit: limits.maxLineBytes)
                scannedFiles += 1
                bytesRead += read.bytesRead
                remainingBytes -= read.bytesRead
                if fileSize > readLimit { truncatedFiles += 1 }
                analysis.oversizedLines += read.oversizedLines
                analyzeClaude(lines: read.lines, fallbackSession: digest(candidate.url.deletingPathExtension().lastPathComponent), cutoff: cutoff, end: now, into: &analysis)
            } catch {
                unreadableFiles += 1
            }
        }

        let repeated = repeatedReads(from: analysis.readResults)
        return TokenWasteResult(
            generatedAt: now,
            rangeDays: safeDays,
            candidateScanCapped: candidateLimitReached,
            scannedFiles: scannedFiles,
            skippedFiles: skippedFiles,
            truncatedFiles: truncatedFiles,
            unreadableFiles: unreadableFiles,
            oversizedLines: analysis.oversizedLines,
            bytesRead: bytesRead,
            repeatedReads: repeated,
            largeOutputs: .init(
                calls: analysis.largeOutputCalls,
                outputBytes: analysis.largeOutputBytes,
                thresholdBytes: max(1, limits.largeOutputThresholdBytes)
            )
        )
    }

    static func analyzeClaude(
        lines: [Data],
        fallbackSession: String = "unknown",
        cutoff: Date,
        end: Date,
        largeOutputThresholdBytes: Int = TokenWasteResult.Limits.default.largeOutputThresholdBytes
    ) -> TokenWasteResult {
        var analysis = Analysis()
        analyzeClaude(lines: lines, fallbackSession: digest(fallbackSession), cutoff: cutoff, end: end, into: &analysis, threshold: largeOutputThresholdBytes)
        return TokenWasteResult(
            generatedAt: end,
            rangeDays: max(1, Int(end.timeIntervalSince(cutoff) / 86_400)),
            candidateScanCapped: false,
            scannedFiles: 0,
            skippedFiles: 0,
            truncatedFiles: 0,
            unreadableFiles: 0,
            oversizedLines: analysis.oversizedLines,
            bytesRead: lines.reduce(0) { $0 + $1.count },
            repeatedReads: repeatedReads(from: analysis.readResults),
            largeOutputs: .init(calls: analysis.largeOutputCalls, outputBytes: analysis.largeOutputBytes, thresholdBytes: max(1, largeOutputThresholdBytes))
        )
    }

    private static func analyzeClaude(
        lines: [Data],
        fallbackSession: String,
        cutoff: Date,
        end: Date,
        into analysis: inout Analysis,
        threshold: Int = TokenWasteResult.Limits.default.largeOutputThresholdBytes
    ) {
        var pending: [String: PendingCall] = [:]
        for line in lines where line.count <= TokenWasteResult.Limits.default.maxLineBytes {
            guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch row["type"] as? String {
            case "assistant":
                guard let date = parseDate(row["timestamp"] as? String), (cutoff...end).contains(date),
                      let message = row["message"] as? [String: Any],
                      let blocks = message["content"] as? [[String: Any]] else { continue }
                let session = digest(nonEmpty(row["sessionId"] as? String) ?? fallbackSession)
                for block in blocks where block["type"] as? String == "tool_use" {
                    guard let toolID = nonEmpty(block["id"] as? String),
                          let tool = block["name"] as? String,
                          ["Read", "Grep", "Glob", "LS", "Bash"].contains(tool) else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]
                    let targetPath = tool == "Read" ? nonEmpty(input["file_path"] as? String) : nil
                    let target = targetPath.map { digest(URL(fileURLWithPath: $0).standardizedFileURL.path) }
                    pending[session + ":" + toolID] = PendingCall(session: session, target: target)
                }
            case "user":
                guard let message = row["message"] as? [String: Any],
                      let blocks = message["content"] as? [[String: Any]] else { continue }
                let session = digest(nonEmpty(row["sessionId"] as? String) ?? fallbackSession)
                for block in blocks where block["type"] as? String == "tool_result" {
                    guard let toolID = nonEmpty(block["tool_use_id"] as? String),
                          let call = pending.removeValue(forKey: session + ":" + toolID) else { continue }
                    let resultBytes = contentByteCount(block["content"])
                    if let target = call.target {
                        let key = ReadKey(session: call.session, target: target)
                        analysis.readResults[key, default: []].append(resultBytes)
                    }
                    if resultBytes > threshold {
                        analysis.largeOutputCalls += 1
                        analysis.largeOutputBytes += resultBytes
                    }
                }
            default:
                continue
            }
        }
    }

    private static func repeatedReads(from reads: [ReadKey: [Int]]) -> TokenWasteResult.RepeatedReads {
        let repeated = reads.values.filter { $0.count > 1 }
        return .init(
            uniqueTargets: repeated.count,
            redundantCalls: repeated.reduce(0) { $0 + $1.count - 1 },
            repeatedOutputBytes: repeated.reduce(0) { total, sizes in
                total + sizes.dropFirst().reduce(0, +)
            }
        )
    }

    private static func readTailLines(at url: URL, fileSize: Int, limit: Int, lineLimit: Int) throws -> (lines: [Data], bytesRead: Int, oversizedLines: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let offset = fileSize > limit ? fileSize - limit : 0
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: limit) ?? Data()
        var chunks = data.split(separator: 0x0A, omittingEmptySubsequences: true).map(Data.init)
        if offset > 0, !chunks.isEmpty { chunks.removeFirst() }
        var oversized = 0
        let bounded = chunks.filter { line in
            if line.count > lineLimit {
                oversized += 1
                return false
            }
            return true
        }
        return (bounded, data.count, oversized)
    }

    private static func contentByteCount(_ value: Any?) -> Int {
        if let text = value as? String { return text.utf8.count }
        guard let blocks = value as? [Any] else { return 0 }
        return blocks.reduce(0) { total, block in
            if let text = block as? String { return total + text.utf8.count }
            if let item = block as? [String: Any], let text = item["text"] as? String { return total + text.utf8.count }
            return total
        }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
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

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
