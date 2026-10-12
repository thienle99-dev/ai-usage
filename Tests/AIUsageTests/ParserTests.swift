import XCTest
@testable import AIUsage

final class ParserTests: XCTestCase {
    func testClaudeWindowsAndBounds() throws {
        let data = Data(#"{"five_hour":{"utilization":120,"resets_at":"2026-10-12T12:00:00Z"},"seven_day":{"utilization":-4}}"#.utf8)
        let windows = try UsageParsing.claude(data)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].utilization, 100)
        XCTAssertEqual(windows[1].utilization, 0)
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
        XCTAssertEqual(windows.map(\.label), ["Session", "Weekly", "Fable weekly"])
        XCTAssertEqual(windows.map(\.utilization), [5, 14, 16])
        XCTAssertNotNil(windows[1].resetsAt)
    }

    func testClaudeExtraUsageCreditsPayload() throws {
        let data = Data(#"{"five_hour":null,"seven_day":null,"extra_usage":{"is_enabled":true,"monthly_limit":60,"used_credits":0.4,"utilization":null,"currency":"USD"}}"#.utf8)
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
        XCTAssertEqual(result.windows.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(result.account, "a@example.com")
    }

    func testCodexNestedRateLimitsResponse() throws {
        let data = Data(#"{"id":3,"result":{"rateLimits":{"rateLimits":{"primary":{"usedPercent":19,"windowDurationMins":300,"resetsAt":1791806400},"secondary":{"usedPercent":48,"windowDurationMins":10080,"resetsAt":1792152000}},"rateLimitsByLimitId":{}}}}"#.utf8)
        let result = try UsageParsing.codex(data)
        XCTAssertEqual(result.windows.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(result.windows.map(\.utilization), [19, 48])
        XCTAssertNotNil(result.windows[1].resetsAt)
    }

    func testMalformedAndMissingUsageFailClearly() {
        XCTAssertThrowsError(try UsageParsing.claude(Data("bad".utf8)))
        XCTAssertThrowsError(try UsageParsing.claude(Data("{}".utf8)))
        XCTAssertThrowsError(try UsageParsing.codex(Data("{}".utf8)))
    }

    func testHTTPFailureDescriptions() {
        XCTAssertEqual(ProviderFailure.http(429).errorDescription, "Rate limited. Try again later.")
        XCTAssertEqual(ProviderFailure.http(401).errorDescription, "Authentication expired or access was denied.")
        XCTAssertEqual(ProviderFailure.http(503).errorDescription, "Service returned HTTP 503.")
    }
}
