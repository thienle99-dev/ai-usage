import XCTest
@testable import AIUsage

final class ParserTests: XCTestCase {
    func testClaudeWindowsAndBounds() throws {
        let data = Data(#"{"five_hour":{"utilization":120,"resets_at":"2026-10-12T12:00:00Z"},"seven_day":{"utilization":-4}}"#.utf8)
        let windows = try UsageParsing.claude(data)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].utilization, 120)
        XCTAssertEqual(windows[1].utilization, -4)
        XCTAssertNil(windows[0].validUtilization)
        XCTAssertNil(windows[1].validUtilization)
        XCTAssertNotNil(windows[0].resetsAt)
    }

    func testClaudeWrappedAndStatusLinePayloads() throws {
        let wrapped = Data(#"{"utilization":{"five_hour":{"utilization":35,"resets_at":"2026-10-12T12:00:00Z"},"seven_day":{"utilization":61}}}"#.utf8)
        XCTAssertEqual(try UsageParsing.claude(wrapped).map(\.utilization), [35, 61])
        let statusLine = Data(#"{"rate_limits":{"five_hour":{"used_percentage":27,"resets_at":1791806400}}}"#.utf8)
        let window = try XCTUnwrap(UsageParsing.claude(statusLine).first)
        XCTAssertEqual(window.utilization, 27)
        XCTAssertNotNil(window.resetsAt)
    }

    func testClaudeLimitsArrayPayload() throws {
        let data = Data(#"{"limits":[{"kind":"session","group":"session","percent":5,"is_active":true},{"kind":"weekly_all","group":"weekly","percent":14,"resets_at":"2026-10-19T10:00:00Z","is_active":false},{"kind":"weekly_scoped","group":"weekly","percent":16,"scope":{"model":{"display_name":"Fable"}}}]}"#.utf8)
        let windows = try UsageParsing.claude(data)
        XCTAssertEqual(windows.map(\.label), ["5-hour limit", "Weekly limit", "Fable weekly"])
        XCTAssertEqual(windows.map(\.utilization), [5, 14, 16])
        XCTAssertNotNil(windows[1].resetsAt)
    }

    func testClaudeExtraUsageCreditsPayload() throws {
        let data = Data(#"{"five_hour":null,"seven_day":null,"extra_usage":{"is_enabled":true,"monthly_limit":6000,"used_credits":40,"utilization":null,"currency":"USD"}}"#.utf8)
        let window = try XCTUnwrap(UsageParsing.claude(data).first)
        XCTAssertEqual(window.label, "Usage credits")
        XCTAssertEqual(window.utilization, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(window.detail, "$0.40 / $60.00")
    }

    func testClaudeAccountProfileShowsEmailAndPlan() throws {
        let data = Data(#"{"account":{"email":"person@example.com","display_name":"Person"},"organization":{"rate_limit_tier":"default_claude_max_20x"}}"#.utf8)
        XCTAssertEqual(UsageParsing.claudeAccount(data), "person@example.com · Max 20x")
    }

    func testClaudeAccountProfileFallsBackToDisplayName() throws {
        let data = Data(#"{"account":{"full_name":"Claude User"}}"#.utf8)
        XCTAssertEqual(UsageParsing.claudeAccount(data), "Claude User")
        XCTAssertNil(UsageParsing.claudeAccount(Data("{}".utf8)))
    }

    func testClaudeRecognizesEmptyQuotaSchema() throws {
        let data = Data(#"{"five_hour":null,"seven_day":null,"extra_usage":{"is_enabled":false}}"#.utf8)
        XCTAssertTrue(try UsageParsing.claude(data).isEmpty)
    }

    func testCodexDurationSelection() throws {
        let data = Data(#"{"result":{"email":"a@example.com","rateLimits":{"primary":{"usedPercent":42,"windowDurationMins":300},"secondary":{"usedPercent":60,"windowDurationMins":10080}}}}"#.utf8)
        let result = try UsageParsing.codex(data)
        XCTAssertEqual(result.windows.map(\.label), ["5-hour limit", "Weekly limit"])
        XCTAssertEqual(result.account, "a@example.com")
    }

    func testCodexNestedRateLimitsResponse() throws {
        let data = Data(#"{"id":3,"result":{"rateLimits":{"rateLimits":{"primary":{"usedPercent":19,"windowDurationMins":300,"resetsAt":1791806400},"secondary":{"usedPercent":48,"windowDurationMins":10080,"resetsAt":1792152000}},"rateLimitsByLimitId":{}}}}"#.utf8)
        let result = try UsageParsing.codex(data)
        XCTAssertEqual(result.windows.map(\.label), ["5-hour limit", "Weekly limit"])
        XCTAssertEqual(result.windows.map(\.utilization), [19, 48])
        XCTAssertNotNil(result.windows[1].resetsAt)
    }

    func testMalformedAndMissingUsageFailClearly() {
        XCTAssertThrowsError(try UsageParsing.claude(Data("bad".utf8)))
        XCTAssertThrowsError(try UsageParsing.claude(Data("{}".utf8)))
        XCTAssertThrowsError(try UsageParsing.codex(Data("{}".utf8)))
    }

    func testInvalidSourcePercentIsPreservedButUnavailableForDisplay() throws {
        let data = Data(#"{"five_hour":{"utilization":143}}"#.utf8)
        let window = try XCTUnwrap(UsageParsing.claude(data).first)
        XCTAssertEqual(window.utilization, 143)
        XCTAssertNil(window.validUtilization)
    }

    func testUsageAggregationUsesMaximumValidEnabledWindow() {
        let codex = UsageSnapshot(provider: .codex, windows: [
            UsageWindow(label: "Session", utilization: 35, resetsAt: nil),
            UsageWindow(label: "Weekly", utilization: 61, resetsAt: nil),
            UsageWindow(label: "Invalid", utilization: 120, resetsAt: nil)
        ], account: nil, lastSuccess: .now)
        let claude = UsageSnapshot(provider: .claude, windows: [
            UsageWindow(label: "Session", utilization: 42, resetsAt: nil)
        ], account: nil, lastSuccess: .now)
        let snapshots: [Provider: UsageSnapshot] = [.codex: codex, .claude: claude]
        XCTAssertEqual(UsageAggregation.maximum(in: snapshots, enabled: [.codex, .claude]), 61)
        XCTAssertEqual(UsageAggregation.maximum(for: .claude, in: snapshots, enabled: [.claude]), 42)
        XCTAssertNil(UsageAggregation.maximum(for: .claude, in: snapshots, enabled: [.codex]))
    }

    func testCursorUsageSummaryMapsPlanBreakdownsAndReset() throws {
        let data = Data(#"{"billingCycleStart":"2026-10-01T00:00:00Z","billingCycleEnd":"2026-11-01T00:00:00Z","membershipType":"pro","individualUsage":{"plan":{"used":2450,"limit":10000,"autoPercentUsed":6,"apiPercentUsed":3,"totalPercentUsed":5},"onDemand":{"enabled":true,"used":40,"limit":1000}}}"#.utf8)
        let windows = try UsageParsing.cursor(data)
        XCTAssertEqual(windows.map(\.label), ["Plan usage", "Auto + Composer", "API models", "On-demand usage"])
        XCTAssertEqual(windows.map(\.validUtilization), [5, 6, 3, 4])
        XCTAssertEqual(windows[0].detail, "$24.50 / $100.00 included this cycle")
        XCTAssertEqual(windows[3].detail, "$0.40 / $10.00")
        XCTAssertEqual(windows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
    }

    func testCursorUsageWithoutPercentDoesNotInventOne() throws {
        let data = Data(#"{"individualUsage":{"plan":{"used":0,"limit":0},"onDemand":{"enabled":false}},"teamUsage":{"onDemand":{"used":1200}}}"#.utf8)
        let windows = try UsageParsing.cursor(data)
        let onDemand = try XCTUnwrap(windows.first)
        XCTAssertNil(onDemand.validUtilization)
        XCTAssertEqual(onDemand.detail, "$12.00 spent this cycle")
        XCTAssertNil(onDemand.resetsAt)
    }

    func testCursorUsageRejectsMalformedAndUnknownResponse() {
        XCTAssertThrowsError(try UsageParsing.cursor(Data("{}".utf8)))
        XCTAssertThrowsError(try UsageParsing.cursor(Data("not json".utf8)))
    }

    func testHTTPFailureDescriptions() {
        XCTAssertEqual(ProviderFailure.http(429).errorDescription, "Rate limited. Try again later.")
        XCTAssertEqual(ProviderFailure.http(401).errorDescription, "Authentication expired or access was denied.")
        XCTAssertEqual(ProviderFailure.http(503).errorDescription, "Service returned HTTP 503.")
    }
}
