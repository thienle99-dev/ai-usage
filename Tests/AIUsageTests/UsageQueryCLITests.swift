import Foundation
import XCTest
@testable import AIUsage

final class UsageQueryCLITests: XCTestCase {
    func testQuotaPayloadIncludesNormalizedQuotaAndFreshness() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot(
            provider: .codex,
            windows: [
                UsageWindow(label: "5-hour limit", utilization: 25, resetsAt: now.addingTimeInterval(3600)),
                UsageWindow(label: "Invalid", utilization: .infinity, resetsAt: nil)
            ],
            account: "person@example.com",
            lastSuccess: now.addingTimeInterval(-120)
        )

        let payload = UsageQueryCLI.quotaPayload(snapshots: [snapshot], provider: .codex, now: now)
        XCTAssertEqual(payload.source, "local_cache")
        XCTAssertEqual(payload.providers.count, 1)
        XCTAssertEqual(payload.providers[0].status, "connected")
        XCTAssertEqual(payload.providers[0].ageSeconds, 120)
        XCTAssertEqual(payload.providers[0].windows[0].usedPercent, 25)
        XCTAssertEqual(payload.providers[0].windows[0].remainingPercent, 75)
        XCTAssertNil(payload.providers[0].windows[1].usedPercent)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(payload)) as? [String: Any])
        let providers = try XCTUnwrap(object["providers"] as? [[String: Any]])
        let windows = try XCTUnwrap(providers[0]["windows"] as? [[String: Any]])
        XCTAssertEqual(windows[0]["used_percent"] as? Double, 25)
        XCTAssertNotNil(windows[0]["resets_at"] as? String)
        XCTAssertNil(windows[1]["used_percent"])
    }

    func testQuotaPayloadMarksMissingAndStaleProviders() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot(
            provider: .claude,
            windows: [UsageWindow(label: "Weekly", utilization: 40, resetsAt: nil)],
            account: nil,
            lastSuccess: now.addingTimeInterval(-3600)
        )

        let payload = UsageQueryCLI.quotaPayload(snapshots: [snapshot], now: now)
        let claude = payload.providers.first { $0.id == Provider.claude.rawValue }
        let missing = payload.providers.first { $0.id == Provider.cursor.rawValue }
        XCTAssertEqual(claude?.status, "stale")
        XCTAssertTrue(claude?.stale == true)
        XCTAssertEqual(missing?.status, "unavailable")
        XCTAssertTrue(missing?.windows.isEmpty == true)
    }

    func testReportPayloadLeavesUnpricedCostNull() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let record = TokenUsageRecord(
            id: "codex-1",
            provider: .codex,
            timestamp: date,
            sessionID: "session-1234567890",
            project: "Example",
            model: "gpt-5",
            inputTokens: 100,
            outputTokens: 20,
            cacheWriteTokens: 0,
            cacheReadTokens: 10,
            estimatedCostUSD: nil
        )
        let result = TokenUsageReportResult(records: [record], scannedFiles: 1, unreadableFiles: 0, scannedAt: date)
        let payload = UsageQueryCLI.reportPayload(result: result, grouping: .provider, range: .all, now: date)

        XCTAssertEqual(payload.recordCount, 1)
        XCTAssertEqual(payload.rows.first?.totalTokens, 130)
        XCTAssertNil(payload.rows.first?.estimatedCostUSD)
        XCTAssertFalse(payload.rows.first?.costIsEstimate ?? true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(payload)) as? [String: Any])
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        XCTAssertTrue(rows[0]["estimated_cost_usd"] is NSNull)
    }
}
