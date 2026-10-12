import Foundation
import XCTest
@testable import AIUsage

final class TokenWasteScannerTests: XCTestCase {
    func testFindsRepeatedReadsAndLargeOutputsWithoutReturningSensitiveIdentifiers() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-12T10:00:00Z")!
        let lines = [
            assistant(session: "private-session", id: "read-1", path: "/Users/private/Secrets/config.json", timestamp: "2026-10-12T09:00:00Z"),
            result(session: "private-session", id: "read-1", bytes: 50),
            assistant(session: "private-session", id: "read-2", path: "/Users/private/Secrets/config.json", timestamp: "2026-10-12T09:01:00Z"),
            result(session: "private-session", id: "read-2", bytes: 120),
            assistant(session: "private-session", id: "read-3", path: "/Users/private/Secrets/config.json", timestamp: "2026-10-12T09:02:00Z"),
            result(session: "private-session", id: "read-3", bytes: 80),
            assistant(session: "private-session", id: "grep-1", path: nil, tool: "Grep", timestamp: "2026-10-12T09:03:00Z"),
            result(session: "private-session", id: "grep-1", bytes: 150),
        ].map { Data($0.utf8) }

        let result = TokenWasteScanner.analyzeClaude(
            lines: lines,
            cutoff: now.addingTimeInterval(-86_400),
            end: now,
            largeOutputThresholdBytes: 100
        )

        XCTAssertEqual(result.repeatedReads.uniqueTargets, 1)
        XCTAssertEqual(result.repeatedReads.redundantCalls, 2)
        XCTAssertEqual(result.repeatedReads.repeatedOutputBytes, 200)
        XCTAssertEqual(result.largeOutputs.calls, 2)
        XCTAssertEqual(result.largeOutputs.outputBytes, 270)

        let payload = UsageQueryCLI.tokenWastePayload(result: result)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(payload), as: UTF8.self)
        XCTAssertFalse(json.contains("private-session"))
        XCTAssertFalse(json.contains("config.json"))
        XCTAssertFalse(json.contains("Secrets"))
    }

    func testScannerEnforcesFileAndByteBudgets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<3 {
            try Data(String(repeating: "x", count: 200).utf8)
                .write(to: root.appendingPathComponent("session-\(index).jsonl"))
        }
        let limits = TokenWasteResult.Limits(
            maxFiles: 1,
            maxCandidateFiles: 2,
            maxDirectoryEntries: 100,
            maxFileBytes: 24,
            maxTotalBytes: 24,
            maxLineBytes: 16,
            largeOutputThresholdBytes: 10
        )

        let result = TokenWasteScanner.scan(roots: [root], rangeDays: 30, limits: limits)

        XCTAssertLessThanOrEqual(result.scannedFiles, 1)
        XCTAssertGreaterThanOrEqual(result.skippedFiles, 1)
        XCTAssertLessThanOrEqual(result.bytesRead, 24)
        XCTAssertEqual(result.truncatedFiles, 1)
        XCTAssertTrue(result.candidateScanCapped)
        XCTAssertEqual(result.oversizedLines, 0)
    }

    private func assistant(session: String, id: String, path: String?, tool: String = "Read", timestamp: String) -> String {
        let input = path.map { #""file_path":"\#($0)""# } ?? ""
        return #"{"type":"assistant","timestamp":"\#(timestamp)","sessionId":"\#(session)","message":{"content":[{"type":"tool_use","id":"\#(id)","name":"\#(tool)","input":{\#(input)}}]}}"#
    }

    private func result(session: String, id: String, bytes: Int) -> String {
        let content = String(repeating: "x", count: bytes)
        let encoded = try! JSONSerialization.data(withJSONObject: content, options: [.fragmentsAllowed])
        let escaped = String(decoding: encoded, as: UTF8.self)
        return #"{"type":"user","sessionId":"\#(session)","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","content":\#(escaped)}]}}"#
    }
}
