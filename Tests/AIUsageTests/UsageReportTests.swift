import XCTest
@testable import AIUsage

final class UsageReportTests: XCTestCase {
    func testParsesClaudeUsageAndDeduplicatesStreamingRows() {
        let first = #"{"type":"assistant","timestamp":"2026-10-12T10:00:00Z","sessionId":"session-1","requestId":"request-1","cwd":"/tmp/sample-project","message":{"id":"message-1","model":"claude-sonnet-4-5","usage":{"input_tokens":10,"output_tokens":4,"cache_creation_input_tokens":2,"cache_read_input_tokens":6}},"costUSD":0.001}"#
        let streamed = #"{"type":"assistant","timestamp":"2026-10-12T10:00:00Z","sessionId":"session-1","requestId":"request-1","cwd":"/tmp/sample-project","message":{"id":"message-1","model":"claude-sonnet-4-5","usage":{"input_tokens":10,"output_tokens":8,"cache_creation_input_tokens":2,"cache_read_input_tokens":6}},"costUSD":0.002}"#

        let records = TokenUsageReportScanner.parseClaude([Data(first.utf8), Data(streamed.utf8)])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].provider, .claude)
        XCTAssertEqual(records[0].project, "sample-project")
        XCTAssertEqual(records[0].totalTokens, 26)
        XCTAssertEqual(records[0].estimatedCostUSD, 0.002)
    }

    func testParsesCodexCumulativeUsageAsDeltasWithoutCost() {
        let lines = [
            #"{"type":"session_meta","payload":{"id":"thread-1","cwd":"/tmp/codex-project","model":"gpt-5.6"}}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-5.6-codex"}}"#,
            #"{"type":"event_msg","timestamp":"2026-10-12T10:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10,"cached_input_tokens":20}}}}"#,
            #"{"type":"event_msg","timestamp":"2026-10-12T10:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"output_tokens":20,"cached_input_tokens":40}}}}"#,
        ].map { Data($0.utf8) }

        let records = TokenUsageReportScanner.parseCodex(lines)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].project, "codex-project")
        XCTAssertEqual(records[0].model, "gpt-5.6-codex")
        XCTAssertEqual(records[0].inputTokens, 80)
        XCTAssertEqual(records[0].cacheReadTokens, 20)
        XCTAssertEqual(records[1].inputTokens, 80)
        XCTAssertEqual(records[1].outputTokens, 10)
        XCTAssertEqual(records[1].cacheReadTokens, 20)
        XCTAssertNil(records[0].estimatedCostUSD)
    }

    func testAggregatesByProjectAndSessionAndHonorsRange() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-12T10:00:00Z")!
        let records = [
            record(id: "one", timestamp: now, session: "s1", project: "Alpha", input: 100, cost: 0.01),
            record(id: "two", timestamp: now, session: "s1", project: "Alpha", input: 50, cost: nil),
            record(id: "old", timestamp: now.addingTimeInterval(-40 * 86_400), session: "s2", project: "Beta", input: 900, cost: nil),
        ]

        let projects = TokenUsageReportAggregation.rows(records: records, grouping: .project, range: .all, now: now)
        XCTAssertEqual(projects.first?.title, "Beta")
        XCTAssertEqual(projects.first?.totalTokens, 900)
        XCTAssertEqual(projects.last?.pricedRecords, 1)
        XCTAssertEqual(projects.last?.recordCount, 2)
        XCTAssertEqual(TokenUsageReportAggregation.rows(records: records, grouping: .session, range: .thirtyDays, now: now).count, 1)
        XCTAssertEqual(TokenUsageReportAggregation.rows(records: records, grouping: .day, range: .sevenDays, now: now).count, 1)
    }

    private func record(id: String, timestamp: Date, session: String, project: String, input: Int, cost: Double?) -> TokenUsageRecord {
        TokenUsageRecord(
            id: id,
            provider: .claude,
            timestamp: timestamp,
            sessionID: session,
            project: project,
            model: "claude-sonnet-4-5",
            inputTokens: input,
            outputTokens: 0,
            cacheWriteTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: cost
        )
    }
}
