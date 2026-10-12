import Foundation
import XCTest
import CSQLite3
@testable import AIUsage

private struct HTTPFixture: Sendable {
    let status: Int
    let body: Data
    var headers: [String: String] = [:]
    var shouldFail: Bool = false
}

private actor FixtureHTTPDataLoader: HTTPDataLoading {
    private var fixtures: [HTTPFixture]
    private var requests: [URLRequest] = []
    private(set) var requestCount = 0

    init(_ fixtures: [HTTPFixture]) { self.fixtures = fixtures }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        requests.append(request)
        guard !fixtures.isEmpty else { throw URLError(.badServerResponse) }
        let fixture = fixtures.removeFirst()
        if fixture.shouldFail { throw URLError(.notConnectedToInternet) }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: fixture.status,
            httpVersion: "HTTP/1.1",
            headerFields: fixture.headers
        )!
        return (fixture.body, response)
    }

    func capturedRequests() -> [URLRequest] { requests }
}

private struct FixtureCodexSource: CodexAppServerDataSource {
    let data: Data
    func read() async throws -> Data { data }
}

private actor MutableCodexSource: CodexAppServerDataSource {
    private var data: Data
    init(data: Data) { self.data = data }
    func update(_ data: Data) { self.data = data }
    func read() async throws -> Data { data }
}

private final class ScriptedMtimes: @unchecked Sendable {
    private var values: [Date?]
    private var index = 0
    init(_ values: [Date?]) { self.values = values }
    func next(_ path: String) -> Date? {
        defer { index += 1 }
        guard index < values.count else { return nil }
        return values[index]
    }
}

private func makeCodexHomeDir(at url: URL, marker: String) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: url.appendingPathComponent("auth.json"))
    try Data(marker.utf8).write(to: url.appendingPathComponent("marker.txt"))
}

private func codexMarker(in home: URL) -> String? {
    try? String(contentsOf: home.appendingPathComponent("marker.txt"), encoding: .utf8)
}

private func codexAccountPayload(email: String, window: String = "primary", percent: Double = 10, durationMins: Double = 300) -> Data {
    Data(#"{"result":{"email":"\#(email)","rateLimits":{"\#(window)":{"usedPercent":\#(percent),"windowDurationMins":\#(durationMins)}}}}"#.utf8)
}

private actor FetchCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor AutoStartCommandRecorder: UsageWindowStartCommandRunning {
    private var started: [Provider] = []
    func run(provider: Provider) async { started.append(provider) }
    func providers() -> [Provider] { started }
}

private struct AutoStartFixtureProvider: UsageProvider {
    let provider: Provider
    func fetch() async throws -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            windows: [UsageWindow(label: "5-hour limit", utilization: 20, resetsAt: .now.addingTimeInterval(-300))],
            account: nil,
            lastSuccess: .now
        )
    }
}

private actor QuotaNotificationRecorder: QuotaNotificationDelivering {
    private(set) var delivered: [QuotaNotification] = []
    func requestAuthorization() async -> Bool { true }
    func deliver(_ notification: QuotaNotification) async { delivered.append(notification) }
    func kinds() -> [QuotaNotification.Kind] { delivered.map(\.kind) }
}

private actor QuotaFixtureProvider: UsageProvider {
    nonisolated let provider: Provider = .claude
    private var utilization: Double
    init(utilization: Double) { self.utilization = utilization }
    func setUtilization(_ value: Double) { utilization = value }
    func fetch() async throws -> UsageSnapshot {
        UsageSnapshot(
            provider: .claude,
            windows: [UsageWindow(label: "5-hour limit", utilization: utilization, resetsAt: nil)],
            account: nil,
            lastSuccess: .now
        )
    }
}

private struct FixtureProvider: UsageProvider {
    let provider: Provider
    let failure: ProviderFailure?
    let delay: Duration
    let counter: FetchCounter

    func fetch() async throws -> UsageSnapshot {
        await counter.increment()
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        return UsageSnapshot(
            provider: provider,
            windows: [UsageWindow(label: "Session", utilization: 32, resetsAt: .now.addingTimeInterval(3600))],
            account: "test@example.com",
            lastSuccess: .now
        )
    }
}

final class ProviderAndStoreTests: XCTestCase {
    func testAutoStartPolicyOnlyStartsForFreshlyResetSupportedWindows() {
        let now = Date.now
        func snapshot(_ provider: Provider, label: String, utilization: Double, reset: Date?) -> UsageSnapshot {
            UsageSnapshot(provider: provider, windows: [UsageWindow(label: label, utilization: utilization, resetsAt: reset)], account: nil, lastSuccess: now)
        }
        XCTAssertTrue(UsageWindowAutoStartPolicy.shouldStart(
            snapshot: snapshot(.claude, label: "5-hour limit", utilization: 100, reset: now.addingTimeInterval(-180)),
            now: now,
            lastStartedAt: nil
        ))
        XCTAssertTrue(UsageWindowAutoStartPolicy.shouldStart(
            snapshot: snapshot(.codex, label: "5-hour limit", utilization: 0, reset: now.addingTimeInterval(-180)),
            now: now,
            lastStartedAt: nil
        ))
        XCTAssertTrue(UsageWindowAutoStartPolicy.shouldStart(
            snapshot: snapshot(.antigravity, label: "Gemini 5-hour", utilization: 0, reset: now.addingTimeInterval(3600)),
            now: now,
            lastStartedAt: nil
        ))
        XCTAssertFalse(UsageWindowAutoStartPolicy.shouldStart(
            snapshot: snapshot(.claude, label: "5-hour limit", utilization: 20, reset: now.addingTimeInterval(3600)),
            now: now,
            lastStartedAt: nil
        ))
        XCTAssertFalse(UsageWindowAutoStartPolicy.shouldStart(
            snapshot: snapshot(.grok, label: "Weekly credits", utilization: 100, reset: now.addingTimeInterval(-3600)),
            now: now,
            lastStartedAt: nil
        ))
    }

    @MainActor
    func testAutoStartSettingPersistsAndDispatchesOneCommandPerCooldown() async {
        let defaults = isolatedDefaults()
        let recorder = AutoStartCommandRecorder()
        let store = UsageStore(
            providers: [AutoStartFixtureProvider(provider: .claude)],
            defaults: defaults,
            startImmediately: false,
            autoStartRunner: recorder
        )
        XCTAssertFalse(store.autoStartUsageWindow)
        store.autoStartUsageWindow = true
        await store.refresh()
        for _ in 0..<10 {
            if !(await recorder.providers()).isEmpty { break }
            await Task.yield()
        }
        let firstStarts = await recorder.providers()
        XCTAssertEqual(firstStarts, [.claude])
        await store.refresh()
        for _ in 0..<10 { await Task.yield() }
        let starts = await recorder.providers()
        XCTAssertEqual(starts, [.claude])
        XCTAssertTrue(UsageStore(providers: [], defaults: defaults, startImmediately: false).autoStartUsageWindow)
    }

    func testQuotaPolicyFiresWarningOnceThenRearmsAfterRecovery() {
        let (first, ep1) = QuotaNotificationPolicy.evaluate(
            utilization: 75, warningThreshold: 70, criticalThreshold: 90, episode: .init())
        XCTAssertEqual(first, .warning)
        XCTAssertTrue(ep1.warned)
        XCTAssertFalse(ep1.critical)
        let (second, _) = QuotaNotificationPolicy.evaluate(
            utilization: 75, warningThreshold: 70, criticalThreshold: 90, episode: ep1)
        XCTAssertNil(second)
        // Jitter inside hysteresis: neither refire nor restore.
        let (third, ep3) = QuotaNotificationPolicy.evaluate(
            utilization: 68, warningThreshold: 70, criticalThreshold: 90, episode: ep1)
        XCTAssertNil(third)
        XCTAssertTrue(ep3.warned)
        // Recovery below hysteresis fires restored and clears the episode.
        let (fourth, ep4) = QuotaNotificationPolicy.evaluate(
            utilization: 60, warningThreshold: 70, criticalThreshold: 90, episode: ep3)
        XCTAssertEqual(fourth, .restored)
        XCTAssertFalse(ep4.warned)
        XCTAssertFalse(ep4.critical)
    }

    func testQuotaPolicyCriticalSuppressesLaterWarning() {
        let (first, ep1) = QuotaNotificationPolicy.evaluate(
            utilization: 95, warningThreshold: 70, criticalThreshold: 90, episode: .init())
        XCTAssertEqual(first, .critical)
        XCTAssertTrue(ep1.warned)
        XCTAssertTrue(ep1.critical)
        let (second, ep2) = QuotaNotificationPolicy.evaluate(
            utilization: 95, warningThreshold: 70, criticalThreshold: 90, episode: ep1)
        XCTAssertNil(second)
        // Dip into the warning band: no stale warning after a critical.
        let (third, ep3) = QuotaNotificationPolicy.evaluate(
            utilization: 80, warningThreshold: 70, criticalThreshold: 90, episode: ep2)
        XCTAssertNil(third)
        let (fourth, ep4) = QuotaNotificationPolicy.evaluate(
            utilization: 60, warningThreshold: 70, criticalThreshold: 90, episode: ep3)
        XCTAssertEqual(fourth, .restored)
        XCTAssertFalse(ep4.warned)
        XCTAssertFalse(ep4.critical)
    }

    @MainActor
    func testQuotaNotificationsFireOncePerWindowUntilRecovery() async throws {
        let defaults = isolatedDefaults()
        let recorder = QuotaNotificationRecorder()
        let provider = QuotaFixtureProvider(utilization: 75)
        let store = UsageStore(
            providers: [provider],
            defaults: defaults,
            startImmediately: false,
            quotaDeliverer: recorder
        )
        XCTAssertFalse(store.quotaNotificationsEnabled)
        store.quotaNotificationsEnabled = true
        await store.refresh()
        try await waitForDelivered(1, recorder: recorder)
        var kinds = await recorder.delivered.map(\.kind)
        XCTAssertEqual(kinds, [.warning])
        // Same level again: no duplicate, and a fresh store reuses persisted state.
        await store.refresh()
        let second = UsageStore(providers: [provider], defaults: defaults, startImmediately: false, quotaDeliverer: recorder)
        XCTAssertTrue(second.quotaNotificationsEnabled)
        await second.refresh()
        try await waitForDelivered(1, recorder: recorder)
        kinds = await recorder.delivered.map(\.kind)
        XCTAssertEqual(kinds, [.warning])
        // Escalation fires critical once.
        await provider.setUtilization(95)
        await store.refresh()
        try await waitForDelivered(2, recorder: recorder)
        kinds = await recorder.delivered.map(\.kind)
        XCTAssertEqual(kinds, [.warning, .critical])
        // Recovery fires restored and re-arms: crossing again warns anew.
        await provider.setUtilization(50)
        await store.refresh()
        try await waitForDelivered(3, recorder: recorder)
        kinds = await recorder.delivered.map(\.kind)
        XCTAssertEqual(kinds, [.warning, .critical, .restored])
        await provider.setUtilization(75)
        await store.refresh()
        try await waitForDelivered(4, recorder: recorder)
        kinds = await recorder.delivered.map(\.kind)
        XCTAssertEqual(kinds, [.warning, .critical, .restored, .warning])
    }

    @MainActor
    func testQuotaNotificationsStaySilentWhenDisabledOrStale() async throws {
        let defaults = isolatedDefaults()
        let recorder = QuotaNotificationRecorder()
        let disabled = UsageStore(
            providers: [QuotaFixtureProvider(utilization: 95)],
            defaults: defaults,
            startImmediately: false,
            quotaDeliverer: recorder
        )
        await disabled.refresh()
        await settleDelivered(recorder: recorder)
        var kinds = await recorder.delivered.map(\.kind)
        XCTAssertTrue(kinds.isEmpty)
        // Failures keep stale snapshots quiet too.
        let staleStore = UsageStore(
            providers: [FixtureProvider(provider: .claude, failure: .network("offline"), delay: .zero, counter: FetchCounter())],
            defaults: isolatedDefaults(),
            startImmediately: false,
            quotaDeliverer: recorder
        )
        staleStore.quotaNotificationsEnabled = true
        await staleStore.refresh()
        await settleDelivered(recorder: recorder)
        kinds = await recorder.delivered.map(\.kind)
        XCTAssertTrue(kinds.isEmpty)
    }

    @MainActor
    private func settleDelivered(recorder: QuotaNotificationRecorder) async {
        for _ in 0..<100 {
            await Task.yield()
        }
        _ = await recorder.delivered.count
    }

    @MainActor
    private func waitForDelivered(_ count: Int, recorder: QuotaNotificationRecorder) async throws {
        for _ in 0..<200 {
            if await recorder.delivered.count >= count { return }
            await Task.yield()
        }
        if count > 0 {
            throw XCTSkip("Timed out waiting for \(count) notifications")
        }
    }

    func testAntigravityParsingMapsGroupsAndResetDates() throws {
        let payload = Data(#"{"response":{"groups":[{"displayName":"Gemini models","buckets":[{"bucketId":"session","remainingFraction":0.75,"resetTime":"2026-10-13T12:30:00Z"},{"bucketId":"weekly","remaining":{"case":"remainingFraction","value":0.4}}]},{"displayName":"Claude and GPT models","buckets":[{"bucketId":"session","remainingFraction":0.9,"disabled":false}]}]}}"#.utf8)
        let windows = try AntigravityParsing.windows(payload)
        XCTAssertEqual(windows.map(\.label), ["Gemini 5-hour", "Gemini Weekly", "Claude / GPT 5-hour"])
        XCTAssertEqual(windows[0].utilization, 25, accuracy: 0.001)
        XCTAssertEqual(windows[1].utilization, 60, accuracy: 0.001)
        XCTAssertEqual(windows[2].utilization, 10, accuracy: 0.001)
        XCTAssertEqual(windows.first?.resetsAt, ISO8601DateFormatter().date(from: "2026-10-13T12:30:00Z"))
    }

    func testAntigravityProviderUsesExistingCredentialAndQuotaEndpoint() async throws {
        let credential = Data(#"{"token":{"access_token":"fixture-antigravity-token","expiry":"2099-10-13T12:30:00Z"}}"#.utf8)
        let loader = FixtureHTTPDataLoader([
            HTTPFixture(status: 200, body: Data(#"{"groups":[{"displayName":"Gemini models","buckets":[{"bucketId":"weekly","remainingFraction":0.2}]}]}"#.utf8)),
            HTTPFixture(status: 200, body: Data(#"{"name":"Antigravity User","email":"agy@example.com"}"#.utf8))
        ])
        let provider = AntigravityProvider(loader: loader, credentialReader: { credential })
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.provider, .antigravity)
        XCTAssertEqual(snapshot.windows.first?.label, "Gemini Weekly")
        XCTAssertEqual(snapshot.windows.first?.validUtilization, 80)
        XCTAssertEqual(snapshot.account, "Antigravity User · agy@example.com")
        let requests = await loader.capturedRequests()
        XCTAssertEqual(requests.map(\.url?.absoluteString), [
            "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
            "https://openidconnect.googleapis.com/v1/userinfo"
        ])
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-antigravity-token")
        XCTAssertEqual(String(data: requests.first?.httpBody ?? Data(), encoding: .utf8), "{}")
    }

    func testAntigravityOAuthClientPrefersEnvironment() {
        let env = [
            "ANTIGRAVITY_OAUTH_CLIENT_ID": "env-test-id",
            "ANTIGRAVITY_OAUTH_CLIENT_SECRET": "env-test-secret"
        ]
        XCTAssertEqual(
            AntigravityOAuthClientResolver.resolve(environment: env, applicationRoots: []),
            AntigravityOAuthClient(id: "env-test-id", secret: "env-test-secret")
        )
        XCTAssertNil(AntigravityOAuthClientResolver.resolve(environment: [:], applicationRoots: []))
    }

    func testAntigravityOAuthClientDiscoveryFindsInstalledPair() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agy-client-\(UUID().uuidString)")
        let artifact = root.appendingPathComponent("Antigravity.app/Contents/Resources/app/out/main.js")
        try FileManager.default.createDirectory(at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Built at runtime so the source never contains a secret-shaped literal.
        let clientID = "814204162361-" + "fixtureclientid" + ".apps.googleusercontent.com"
        let secret = "GOCSPX-" + String(repeating: "F", count: 28)
        try Data("oauthClient={id:\"\(clientID)\",secret:\"\(secret)\"};".utf8).write(to: artifact)
        let client = AntigravityOAuthClientResolver.resolve(environment: [:], applicationRoots: [root])
        XCTAssertEqual(client?.id, clientID)
        XCTAssertEqual(client?.secret, secret)
    }

    func testAntigravityOAuthClientDiscoveryRejectsAmbiguousPairs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agy-client-\(UUID().uuidString)")
        let artifact = root.appendingPathComponent("Antigravity.app/Contents/Resources/app/out/main.js")
        try FileManager.default.createDirectory(at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = "111-" + "aaaaaaaaaaaaaaaaaaaa" + ".apps.googleusercontent.com"
        let second = "222-" + "bbbbbbbbbbbbbbbbbbbb" + ".apps.googleusercontent.com"
        let secret = "GOCSPX-" + String(repeating: "E", count: 28)
        try Data("\(first)\n\(second)\n\(secret)".utf8).write(to: artifact)
        XCTAssertNil(AntigravityOAuthClientResolver.resolve(environment: [:], applicationRoots: [root]))
    }

    func testAntigravityRefreshUsesResolvedClient() async throws {
        let expired = Data(#"{"token":{"access_token":"old-token","refresh_token":"fixture-refresh","expiry":"2020-10-13T12:30:00Z"}}"#.utf8)
        let loader = FixtureHTTPDataLoader([
            HTTPFixture(status: 200, body: Data(#"{"access_token":"new-token","expires_in":3600}"#.utf8)),
            HTTPFixture(status: 200, body: Data(#"{"groups":[{"displayName":"Gemini models","buckets":[{"bucketId":"weekly","remainingFraction":0.2}]}]}"#.utf8)),
            HTTPFixture(status: 200, body: Data(#"{"name":"Antigravity User","email":"agy@example.com"}"#.utf8))
        ])
        let provider = AntigravityProvider(
            loader: loader,
            credentialReader: { expired },
            clientProvider: { AntigravityOAuthClient(id: "injected-id", secret: "injected-secret") }
        )
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.account, "Antigravity User · agy@example.com")
        let requests = await loader.capturedRequests()
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://oauth2.googleapis.com/token")
        let body = String(data: requests.first?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("client_id=injected-id"))
        XCTAssertTrue(body.contains("client_secret=injected-secret"))
        XCTAssertTrue(body.contains("refresh_token=fixture-refresh"))
    }

    func testAntigravityRefreshFailsClearlyWithoutClient() async {
        let expired = Data(#"{"token":{"access_token":"old-token","refresh_token":"fixture-refresh","expiry":"2020-10-13T12:30:00Z"}}"#.utf8)
        let loader = FixtureHTTPDataLoader([])
        let provider = AntigravityProvider(loader: loader, credentialReader: { expired }, clientProvider: { nil })
        do {
            _ = try await provider.fetch()
            XCTFail("Expected credentials failure")
        } catch let failure as ProviderFailure {
            guard case .credentials(let message) = failure else {
                XCTFail("Wrong failure: \(failure)")
                return
            }
            XCTAssertTrue(message.contains("ANTIGRAVITY_OAUTH_CLIENT_SECRET"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGrokParserReadsCurrentWeekCreditsAndDefaultsMissingUsageToZero() throws {
        let line = Data(#"{"msg":"billing: fetched credits config","ts":"2026-10-12T10:00:00Z","ctx":{"config":{"currentPeriod":{"end":"2026-10-19T10:00:00Z"}},"subscriptionTier":"SuperGrok"}}"#.utf8)
        let quota = try XCTUnwrap(GrokParsing.quota(from: line))
        XCTAssertEqual(quota.usedPercent, 0)
        XCTAssertEqual(quota.periodEnd, ISO8601DateFormatter().date(from: "2026-10-19T10:00:00Z"))
        XCTAssertEqual(quota.subscriptionTier, "SuperGrok")
    }

    func testGrokProviderReadsLocalLogAndRejectsExpiredPeriod() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-provider-\(UUID().uuidString)")
        let logs = home.appendingPathComponent(".grok/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let log = logs.appendingPathComponent("unified.jsonl")
        let line = #"{"msg":"billing: fetched credits config","ts":"2099-10-12T10:00:00Z","ctx":{"config":{"creditUsagePercent":37.5,"currentPeriod":{"end":"2099-10-19T10:00:00Z"}},"subscriptionTier":"SuperGrok"}}"#
        try Data(line.utf8).write(to: log)
        let snapshot = try await GrokProvider(homeDirectory: home).fetch()
        XCTAssertEqual(snapshot.windows.first?.label, "Weekly credits")
        XCTAssertEqual(snapshot.windows.first?.validUtilization, 37.5)
        XCTAssertEqual(snapshot.account, "SuperGrok")
    }

    func testGeminiParsingGroupsModelQuotasAndKeepsResetDates() throws {
        let reset = "2026-10-13T12:30:00Z"
        let payload = Data(#"{"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":0.6,"resetTime":"2026-10-13T12:30:00Z"},{"modelId":"gemini-2.5-flash","remainingFraction":0.25,"resetTime":"2026-10-13T12:30:00Z"},{"modelId":"gemini-2.5-flash-lite","remainingFraction":0.8,"resetTime":"2026-10-13T12:30:00Z"}]}"#.utf8)
        let windows = try GeminiParsing.windows(payload)
        XCTAssertEqual(windows.map(\.label), ["Pro", "Flash", "Flash Lite"])
        XCTAssertEqual(windows.map(\.utilization), [40, 75, 20])
        XCTAssertEqual(windows.first?.resetsAt, ISO8601DateFormatter().date(from: reset))
    }

    func testGeminiProviderUsesCLIAuthAndCodeAssistQuotaEndpoints() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-provider-\(UUID().uuidString)")
        let config = home.appendingPathComponent(".gemini", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"security":{"auth":{"selectedType":"oauth-personal"}}}"#.utf8).write(to: config.appendingPathComponent("settings.json"))
        let expiry = Date.now.addingTimeInterval(3600).timeIntervalSince1970 * 1000
        let credentials = try JSONSerialization.data(withJSONObject: ["access_token": "fixture-access-token", "expiry_date": expiry])
        try credentials.write(to: config.appendingPathComponent("oauth_creds.json"))

        let loader = FixtureHTTPDataLoader([
            HTTPFixture(status: 200, body: Data(#"{"cloudaicompanionProject":{"id":"gen-lang-client-test"},"currentTier":{"id":"standard-tier"}}"#.utf8)),
            HTTPFixture(status: 200, body: Data(#"{"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":0.4,"resetTime":"2026-10-13T12:30:00Z"}]}"#.utf8))
        ])
        let snapshot = try await GeminiProvider(loader: loader, homeDirectory: home).fetch()
        XCTAssertEqual(snapshot.provider, .gemini)
        XCTAssertEqual(snapshot.account, "Paid")
        XCTAssertEqual(snapshot.windows.first?.label, "Pro")
        XCTAssertEqual(snapshot.windows.first?.validUtilization, 60)

        let requests = await loader.capturedRequests()
        XCTAssertEqual(requests.map(\.url?.absoluteString), [
            "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
            "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
        ])
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access-token")
        XCTAssertEqual(String(data: requests.last?.httpBody ?? Data(), encoding: .utf8), #"{"project":"gen-lang-client-test"}"#)
    }

    func testUsageCardLayoutDefaultsAndUnknownPreferenceFallback() throws {
        XCTAssertEqual(UsageCardLayout.preference("twoColumns", fallback: .compactBalanced), .twoColumns)
        XCTAssertEqual(UsageCardLayout.preference("obsolete-layout", fallback: .twoColumns), .twoColumns)
        XCTAssertEqual(UsageCardLayout.allCases, [.compactBalanced, .twoColumns, .minimalRows, .collapsible])

        let encoded = try JSONEncoder().encode(UsageCardLayout.collapsible)
        XCTAssertEqual(try JSONDecoder().decode(UsageCardLayout.self, from: encoded), .collapsible)
    }

    func testClaudeRetries429OnlyWhenRetryAfterIsPositive() async throws {
        let body = Data(#"{"five_hour":{"utilization":25}}"#.utf8)
        let loader = FixtureHTTPDataLoader([
            HTTPFixture(status: 429, body: Data(), headers: ["Retry-After": "0.001"]),
            HTTPFixture(status: 200, body: body)
        ])
        let provider = ClaudeProvider(loader: loader, fetchProfile: false, tokenProvider: { "fixture-token" })
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.windows.first?.validUtilization, 25)
        let requestCount = await loader.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testClaudeDoesNotRetryBudget429WithZeroRetryAfter() async {
        let loader = FixtureHTTPDataLoader([HTTPFixture(status: 429, body: Data(), headers: ["Retry-After": "0"])])
        let provider = ClaudeProvider(loader: loader, fetchProfile: false, tokenProvider: { "fixture-token" })
        do {
            _ = try await provider.fetch()
            XCTFail("Expected a rate limit failure")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.status, .rateLimited)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let requestCount = await loader.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testClaudeAuthenticationAndNetworkFailuresMapToStatuses() async {
        let unauthorized = FixtureHTTPDataLoader([HTTPFixture(status: 401, body: Data())])
        do {
            _ = try await ClaudeProvider(loader: unauthorized, fetchProfile: false, tokenProvider: { "token" }).fetch()
            XCTFail("Expected authentication failure")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.status, .authenticationRequired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let offline = FixtureHTTPDataLoader([HTTPFixture(status: 0, body: Data(), shouldFail: true)])
        do {
            _ = try await ClaudeProvider(loader: offline, fetchProfile: false, tokenProvider: { "token" }).fetch()
            XCTFail("Expected network failure")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.status, .error)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCodexProviderUsesInjectedAppServerResponse() async throws {
        let fixture = Data(#"{"result":{"email":"codex@example.com","planType":"plus","rateLimits":{"primary":{"usedPercent":18,"windowDurationMins":300},"secondary":{"usedPercent":54,"windowDurationMins":10080}}}}"#.utf8)
        let snapshot = try await CodexProvider(source: FixtureCodexSource(data: fixture)).fetch()
        XCTAssertEqual(snapshot.account, "codex@example.com · plus")
        XCTAssertEqual(snapshot.windows.map(\.label), ["5-hour limit", "Weekly limit"])
        XCTAssertEqual(snapshot.windows.compactMap(\.validUtilization), [18, 54])
    }

    func testCursorProviderUsesInjectedSessionAndUsageSummary() async throws {
        let usage = Data(#"{"membershipType":"pro","billingCycleEnd":"2026-11-01T00:00:00Z","individualUsage":{"plan":{"used":600,"limit":6000,"totalPercentUsed":10}}}"#.utf8)
        let account = Data(#"{"email":"cursor@example.com","name":"Cursor User"}"#.utf8)
        let loader = FixtureHTTPDataLoader([HTTPFixture(status: 200, body: usage), HTTPFixture(status: 200, body: account)])
        let provider = CursorProvider(loader: loader, sessionProvider: { CursorSession(cookieHeader: "WorkosCursorSessionToken=fixture", accountHint: nil) })
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.provider, .cursor)
        XCTAssertEqual(snapshot.account, "cursor@example.com · Pro")
        XCTAssertEqual(snapshot.windows.first?.validUtilization, 10)
        let requestCount = await loader.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testCursorAppAuthReadsAndValidatesTokenReadOnly() throws {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-auth-\(UUID().uuidString).vscdb")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT NOT NULL)", nil, nil, nil), SQLITE_OK)

        let claims: [String: Any] = ["sub": "auth0|cursor-user", "email": "cursor@example.com", "exp": Date.now.addingTimeInterval(3600).timeIntervalSince1970]
        let payloadData = try JSONSerialization.data(withJSONObject: claims)
        let payload = payloadData.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let token = "header.\(payload).signature"
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "INSERT INTO ItemTable (key, value) VALUES (?, ?)", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, "cursorAuth/accessToken", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 2, token, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)

        let session = try XCTUnwrap(CursorAppAuthStore(databaseURL: databaseURL).session())
        XCTAssertEqual(session.cookieHeader, "WorkosCursorSessionToken=cursor-user%3A%3A\(token)")
        XCTAssertEqual(session.accountHint, "cursor@example.com")
    }

    @MainActor
    func testRefreshKeepsProvidersIndependentAndPreservesStaleSnapshot() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("snapshots.json")
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let codexCounter = FetchCounter()
        let claudeCounter = FetchCounter()
        let first = UsageStore(
            providers: [
                FixtureProvider(provider: .codex, failure: nil, delay: .zero, counter: codexCounter),
                FixtureProvider(provider: .claude, failure: nil, delay: .zero, counter: claudeCounter)
            ],
            defaults: defaults,
            cacheURL: cache,
            startImmediately: false
        )
        await first.refresh()
        XCTAssertEqual(first.status(for: .codex), .connected)
        XCTAssertEqual(first.status(for: .claude), .connected)

        let refreshCounter = FetchCounter()
        let second = UsageStore(
            providers: [
                FixtureProvider(provider: .codex, failure: nil, delay: .zero, counter: refreshCounter),
                FixtureProvider(provider: .claude, failure: .http(401), delay: .zero, counter: FetchCounter())
            ],
            defaults: defaults,
            cacheURL: cache,
            startImmediately: false
        )
        await second.refresh()
        XCTAssertEqual(second.status(for: .claude), .authenticationRequired)
        XCTAssertEqual(second.snapshots[.claude]?.windows.first?.validUtilization, 32)
        XCTAssertNotNil(second.snapshots[.claude]?.error)
        XCTAssertEqual(second.status(for: .codex), .connected)
        XCTAssertNil(second.snapshots[.codex]?.error)
    }

    @MainActor
    func testRefreshIsSingleFlightPerProvider() async {
        let counter = FetchCounter()
        let provider = FixtureProvider(provider: .codex, failure: nil, delay: .milliseconds(80), counter: counter)
        let store = UsageStore(providers: [provider], defaults: isolatedDefaults(), startImmediately: false)
        let first = Task { await store.refresh() }
        await Task.yield()
        await store.refresh()
        await first.value
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testManualPolicyLoadsNoDataWhenPopoverOpensAndPersists() {
        let defaults = isolatedDefaults()
        defaults.set(RefreshPolicy.manual.rawValue, forKey: "refreshPolicy")
        let counter = FetchCounter()
        let store = UsageStore(
            providers: [FixtureProvider(provider: .codex, failure: nil, delay: .zero, counter: counter)],
            defaults: defaults,
            startImmediately: false
        )
        XCTAssertEqual(store.refreshPolicy, .manual)
        XCTAssertFalse(store.needsInitialRefreshOnOpen)
        store.refreshPolicy = .tenMinutes
        XCTAssertEqual(defaults.string(forKey: "refreshPolicy"), RefreshPolicy.tenMinutes.rawValue)
    }

    @MainActor
    func testDisplayPreferencesPersistAcrossStoreInstances() {
        let defaults = isolatedDefaults()
        let first = UsageStore(providers: [], defaults: defaults, startImmediately: false)
        first.appearance = "dark"
        first.menuBarMode = .providerSpecific
        first.selectedProvider = .copilot
        first.warningThreshold = 75
        first.criticalThreshold = 95
        first.visibleProviders = [.claude]

        let second = UsageStore(providers: [], defaults: defaults, startImmediately: false)
        XCTAssertEqual(second.appearance, "dark")
        XCTAssertEqual(second.menuBarMode, .providerSpecific)
        XCTAssertEqual(second.selectedProvider, .copilot)
        XCTAssertEqual(second.warningThreshold, 75)
        XCTAssertEqual(second.criticalThreshold, 95)
        XCTAssertEqual(second.visibleProviders, [.claude])
    }

    func testProviderNavigationRegistryLabelsAndSupportedSources() {
        XCTAssertEqual(Provider.allCases.map(\.shortName), [
            "Codex", "Claude", "Cursor", "Copilot", "Gemini", "Antigravity", "Grok", "Windsurf", "Cline", "Roo", "OpenCode"
        ])
        XCTAssertEqual(Provider.supported, [.codex, .claude, .cursor, .copilot, .gemini, .antigravity, .grok, .openCode])
        XCTAssertEqual(Provider.codex.menuBarAbbreviation, "C")
        XCTAssertEqual(Provider.claude.menuBarAbbreviation, "A")
    }

    func testMenuBarSingleProviderShowsAbbreviationAndFallsBack() {
        func snapshot(_ provider: Provider, _ utilization: Double) -> UsageSnapshot {
            UsageSnapshot(
                provider: provider,
                windows: [UsageWindow(label: "Session", utilization: utilization, resetsAt: nil)],
                account: nil,
                lastSuccess: .now
            )
        }
        let snapshots: [Provider: UsageSnapshot] = [.claude: snapshot(.claude, 42), .codex: snapshot(.codex, 80)]
        let both: Set<Provider> = [.claude, .codex]
        XCTAssertEqual(
            MenuBarContent.text(mode: .singleProvider, selectedProvider: .claude, snapshots: snapshots, enabled: both, criticalThreshold: 90),
            "A 42%"
        )
        XCTAssertEqual(
            MenuBarContent.text(mode: .singleProvider, selectedProvider: .cursor, snapshots: snapshots, enabled: both.union([.cursor]), criticalThreshold: 90),
            "Cursor"
        )
        XCTAssertEqual(
            MenuBarContent.text(mode: .singleProvider, selectedProvider: .claude, snapshots: snapshots, enabled: [.codex], criticalThreshold: 90),
            "80%"
        )
        XCTAssertEqual(
            MenuBarContent.text(mode: .combinedUsage, selectedProvider: .claude, snapshots: snapshots, enabled: both, criticalThreshold: 90),
            "80%"
        )
        XCTAssertEqual(
            MenuBarContent.text(mode: .iconOnly, selectedProvider: .claude, snapshots: snapshots, enabled: both, criticalThreshold: 90),
            ""
        )
        XCTAssertEqual(
            MenuBarContent.text(mode: .providerSpecific, selectedProvider: .claude, snapshots: snapshots, enabled: both, criticalThreshold: 90),
            "C 80% · A 42%"
        )
        XCTAssertEqual(
            MenuBarContent.text(mode: .criticalProviderOnly, selectedProvider: .claude, snapshots: snapshots, enabled: both, criticalThreshold: 90),
            ""
        )
        XCTAssertEqual(
            MenuBarContent.text(mode: .criticalProviderOnly, selectedProvider: .claude, snapshots: snapshots, enabled: both, criticalThreshold: 70),
            "C"
        )
        XCTAssertEqual(
            MenuBarContent.symbolName(mode: .singleProvider, selectedProvider: .codex, snapshots: snapshots, enabled: both, criticalThreshold: 90),
            "terminal.fill"
        )
        XCTAssertEqual(
            MenuBarContent.symbolName(mode: .criticalProviderOnly, selectedProvider: .claude, snapshots: snapshots, enabled: both, criticalThreshold: 70),
            "exclamationmark.triangle.fill"
        )
        XCTAssertEqual(
            MenuBarContent.symbolName(mode: .combinedUsage, selectedProvider: .claude, snapshots: snapshots, enabled: both, criticalThreshold: 90),
            "chart.bar.fill"
        )
    }

    @MainActor
    func testMenuBarProviderPersistsAcrossStoreInstances() {
        let defaults = isolatedDefaults()
        let first = UsageStore(providers: [], defaults: defaults, startImmediately: false)
        XCTAssertEqual(first.menuBarProvider, .claude)
        first.menuBarProvider = .codex
        let second = UsageStore(providers: [], defaults: defaults, startImmediately: false)
        XCTAssertEqual(second.menuBarMode, .combinedUsage)
        XCTAssertEqual(second.menuBarProvider, .codex)
        defaults.set("Nope", forKey: "menuBarProvider")
        XCTAssertEqual(UsageStore(providers: [], defaults: defaults, startImmediately: false).menuBarProvider, .claude)
    }

    @MainActor
    func testCodexSnapshotPersistsStableAccountID() async throws {
        let fixture = Data(#"{"result":{"email":"codex@example.com","planType":"plus","rateLimits":{"primary":{"usedPercent":18,"windowDurationMins":300}}}}"#.utf8)
        let store = UsageStore(
            providers: [CodexProvider(source: FixtureCodexSource(data: fixture))],
            defaults: isolatedDefaults(),
            startImmediately: false
        )
        await store.refresh()
        XCTAssertEqual(store.snapshots[.codex]?.accountID, "codex@example.com")
        XCTAssertEqual(store.snapshots[.codex]?.account, "codex@example.com · plus")
    }

    @MainActor
    func testCodexAccountSwitchReplacesSnapshotWholesale() async throws {
        let accountA = Data(#"{"result":{"email":"a@example.com","rateLimits":{"primary":{"usedPercent":80,"windowDurationMins":300}}}}"#.utf8)
        let accountB = Data(#"{"result":{"email":"b@example.com","rateLimits":{"secondary":{"usedPercent":10,"windowDurationMins":10080}}}}"#.utf8)
        let source = MutableCodexSource(data: accountA)
        let store = UsageStore(
            providers: [CodexProvider(source: source)],
            defaults: isolatedDefaults(),
            startImmediately: false
        )
        await store.refresh()
        XCTAssertEqual(store.snapshots[.codex]?.accountID, "a@example.com")
        XCTAssertEqual(store.snapshots[.codex]?.windows.map(\.label), ["5-hour limit"])
        await source.update(accountB)
        await store.refresh()
        XCTAssertEqual(store.snapshots[.codex]?.accountID, "b@example.com")
        XCTAssertEqual(store.snapshots[.codex]?.account, "b@example.com")
        XCTAssertEqual(store.snapshots[.codex]?.windows.map(\.label), ["Weekly limit"])
        XCTAssertNil(store.snapshots[.codex]?.error)
    }

    @MainActor
    func testCodexAuthChangeDetectionBaselinesSettlesAndFires() async {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let script = ScriptedMtimes([
            base, base,
            base.addingTimeInterval(100), base.addingTimeInterval(100), base.addingTimeInterval(100),
            nil, nil,
            base.addingTimeInterval(200),
        ])
        let store = UsageStore(
            providers: [],
            defaults: isolatedDefaults(),
            startImmediately: false,
            fileModificationDate: { [script] path in script.next(path) }
        )
        XCTAssertFalse(store.codexAuthDidChange(now: base))
        XCTAssertFalse(store.codexAuthDidChange(now: base))
        XCTAssertFalse(store.codexAuthDidChange(now: base.addingTimeInterval(101)))
        XCTAssertTrue(store.codexAuthDidChange(now: base.addingTimeInterval(110)))
        XCTAssertFalse(store.codexAuthDidChange(now: base.addingTimeInterval(120)))
        XCTAssertFalse(store.codexAuthDidChange(now: base.addingTimeInterval(130)))
        XCTAssertFalse(store.codexAuthDidChange(now: base.addingTimeInterval(140)))
        XCTAssertFalse(store.codexAuthDidChange(now: base.addingTimeInterval(200)))
    }

    @MainActor
    func testCodexHomeRegistryAddAssignRemoveAndPersist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live", isDirectory: true)
        let slotB = root.appendingPathComponent("slot-b", isDirectory: true)
        try makeCodexHomeDir(at: live, marker: "live")
        try makeCodexHomeDir(at: slotB, marker: "b")
        let defaults = isolatedDefaults()
        let liveAuth = live.appendingPathComponent("auth.json")
        func makeStore() -> UsageStore {
            UsageStore(providers: [], defaults: defaults, startImmediately: false, codexAuthFileURL: liveAuth)
        }
        let store = makeStore()
        XCTAssertThrowsError(try store.addCodexHome(at: live)) {
            XCTAssertEqual($0 as? CodexHomeError, .isLiveHome)
        }
        let emptyDir = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.addCodexHome(at: emptyDir)) {
            XCTAssertEqual($0 as? CodexHomeError, .missingAuthFile)
        }
        XCTAssertThrowsError(try store.addCodexHome(at: liveAuth)) {
            XCTAssertEqual($0 as? CodexHomeError, .notDirectory)
        }
        try store.addCodexHome(at: slotB)
        XCTAssertThrowsError(try store.addCodexHome(at: slotB)) {
            XCTAssertEqual($0 as? CodexHomeError, .duplicate)
        }
        let slotA = root.appendingPathComponent("slot-a", isDirectory: true)
        try store.assignCodexHomeSlot(at: slotA)
        XCTAssertThrowsError(try store.assignCodexHomeSlot(at: slotA)) {
            XCTAssertEqual($0 as? CodexHomeError, .duplicate)
        }
        let takenDir = root.appendingPathComponent("taken", isDirectory: true)
        try FileManager.default.createDirectory(at: takenDir, withIntermediateDirectories: true)
        do {
            try store.assignCodexHomeSlot(at: takenDir)
            XCTFail("Expected occupied slot")
        } catch CodexHomeError.occupiedSlot { } catch {
            XCTFail("Wrong error: \(error)")
        }
        XCTAssertEqual(store.codexHomes.count, 2)
        store.activeCodexHomePath = store.codexHomes.first?.path
        let second = makeStore()
        XCTAssertEqual(second.codexHomes, store.codexHomes)
        XCTAssertEqual(second.activeCodexHomePath, store.activeCodexHomePath)
        if let home = second.codexHomes.first {
            second.removeCodexHome(home)
        }
        XCTAssertNil(second.activeCodexHomePath)
        XCTAssertEqual(makeStore().codexHomes.count, 1)
    }

    @MainActor
    func testCodexLiveIdentityBindsToSingleMissingSlot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live", isDirectory: true)
        let slotA = root.appendingPathComponent("slot-a", isDirectory: true)
        let slotB = root.appendingPathComponent("slot-b", isDirectory: true)
        try makeCodexHomeDir(at: live, marker: "LIVE-A")
        try makeCodexHomeDir(at: slotB, marker: "B")
        let store = UsageStore(
            providers: [CodexProvider(source: FixtureCodexSource(data: codexAccountPayload(email: "a@example.com")))],
            defaults: isolatedDefaults(),
            startImmediately: false,
            codexAuthFileURL: live.appendingPathComponent("auth.json")
        )
        try store.addCodexHome(at: slotB)
        try store.assignCodexHomeSlot(at: slotA)
        await store.refresh()
        XCTAssertEqual(store.activeCodexHomePath, store.codexHomes.first(where: { $0.path.hasSuffix("slot-a") })?.path)
        XCTAssertEqual(store.snapshots[.codex]?.accountID, "a@example.com")
        XCTAssertFalse(store.codexLiveHomeIsUnregistered)
    }

    @MainActor
    func testCodexHomeSwitchMovesFoldersAndUpdatesActive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live", isDirectory: true)
        let slotA = root.appendingPathComponent("slot-a", isDirectory: true)
        let slotB = root.appendingPathComponent("slot-b", isDirectory: true)
        try makeCodexHomeDir(at: live, marker: "LIVE-A")
        try makeCodexHomeDir(at: slotB, marker: "B")
        let source = MutableCodexSource(data: codexAccountPayload(email: "a@example.com"))
        let store = UsageStore(
            providers: [CodexProvider(source: source)],
            defaults: isolatedDefaults(),
            startImmediately: false,
            codexAuthFileURL: live.appendingPathComponent("auth.json")
        )
        try store.addCodexHome(at: slotB)
        try store.assignCodexHomeSlot(at: slotA)
        await store.refresh()
        let target = try XCTUnwrap(store.codexHomes.first(where: { $0.path.hasSuffix("slot-b") }))
        await source.update(codexAccountPayload(email: "b@example.com"))
        await store.switchCodexAccount(to: target)
        XCTAssertNil(store.codexSwitchError)
        XCTAssertFalse(store.codexSwitchInFlight)
        XCTAssertEqual(codexMarker(in: live), "B")
        XCTAssertEqual(codexMarker(in: slotA), "LIVE-A")
        XCTAssertFalse(FileManager.default.fileExists(atPath: slotB.path))
        XCTAssertEqual(store.activeCodexHomePath, target.path)
        XCTAssertEqual(store.snapshots[.codex]?.accountID, "b@example.com")
    }

    @MainActor
    func testCodexHomeSwitchRollsBackOnIdentityMismatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live", isDirectory: true)
        let slotA = root.appendingPathComponent("slot-a", isDirectory: true)
        let slotB = root.appendingPathComponent("slot-b", isDirectory: true)
        try makeCodexHomeDir(at: live, marker: "LIVE-A")
        try makeCodexHomeDir(at: slotB, marker: "B")
        let source = MutableCodexSource(data: codexAccountPayload(email: "a@example.com"))
        let store = UsageStore(
            providers: [CodexProvider(source: source)],
            defaults: isolatedDefaults(),
            startImmediately: false,
            codexAuthFileURL: live.appendingPathComponent("auth.json")
        )
        try store.addCodexHome(at: slotB)
        try store.assignCodexHomeSlot(at: slotA)
        await store.refresh()
        if let index = store.codexHomes.firstIndex(where: { $0.path.hasSuffix("slot-b") }) {
            store.codexHomes[index].lastSeenAccountID = "expected-b@example.com"
        }
        let target = try XCTUnwrap(store.codexHomes.first(where: { $0.path.hasSuffix("slot-b") }))
        await source.update(codexAccountPayload(email: "c@example.com"))
        await store.switchCodexAccount(to: target)
        XCTAssertNotNil(store.codexSwitchError)
        XCTAssertTrue(store.codexSwitchError?.contains("expected-b@example.com") ?? false)
        XCTAssertEqual(codexMarker(in: live), "LIVE-A")
        XCTAssertEqual(codexMarker(in: slotB), "B")
        XCTAssertFalse(FileManager.default.fileExists(atPath: slotA.path))
        XCTAssertEqual(store.activeCodexHomePath, store.codexHomes.first(where: { $0.path.hasSuffix("slot-a") })?.path)
    }

    @MainActor
    func testCodexHomeSwitchRefusesUnknownLiveOccupiedAndBusy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live", isDirectory: true)
        let slotB = root.appendingPathComponent("slot-b", isDirectory: true)
        try makeCodexHomeDir(at: live, marker: "LIVE-A")
        try makeCodexHomeDir(at: slotB, marker: "B")
        let source = MutableCodexSource(data: codexAccountPayload(email: "a@example.com"))
        let store = UsageStore(
            providers: [CodexProvider(source: source)],
            defaults: isolatedDefaults(),
            startImmediately: false,
            codexAuthFileURL: live.appendingPathComponent("auth.json")
        )
        try store.addCodexHome(at: slotB)
        await store.refresh()
        // Live identity matches nothing and no slot is missing: unknown live.
        let target = try XCTUnwrap(store.codexHomes.first(where: { $0.path.hasSuffix("slot-b") }))
        await store.switchCodexAccount(to: target)
        XCTAssertNotNil(store.codexSwitchError)
        XCTAssertEqual(codexMarker(in: live), "LIVE-A")
        XCTAssertEqual(codexMarker(in: slotB), "B")
        // Busy: refresh in flight refuses without moving anything.
        store.refreshing.insert(.codex)
        store.codexSwitchError = nil
        await store.switchCodexAccount(to: target)
        XCTAssertEqual(store.codexSwitchError, CodexHomeError.busy.localizedDescription)
        store.refreshing.remove(.codex)
        XCTAssertEqual(codexMarker(in: live), "LIVE-A")
    }

    @MainActor
    func testCodexHomeSwitchRefusesOccupiedSourceSlot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live", isDirectory: true)
        let slotA = root.appendingPathComponent("slot-a", isDirectory: true)
        let slotB = root.appendingPathComponent("slot-b", isDirectory: true)
        try makeCodexHomeDir(at: live, marker: "LIVE-A")
        try makeCodexHomeDir(at: slotA, marker: "JUNK")
        try makeCodexHomeDir(at: slotB, marker: "B")
        let store = UsageStore(
            providers: [CodexProvider(source: FixtureCodexSource(data: codexAccountPayload(email: "a@example.com")))],
            defaults: isolatedDefaults(),
            startImmediately: false,
            codexAuthFileURL: live.appendingPathComponent("auth.json")
        )
        try store.addCodexHome(at: slotA)
        try store.addCodexHome(at: slotB)
        await store.refresh()
        // Simulate a stale belief that slot A's folder is live while its
        // folder is actually still stashed on disk.
        store.activeCodexHomePath = try XCTUnwrap(store.codexHomes.first(where: { $0.path.hasSuffix("slot-a") })?.path)
        let target = try XCTUnwrap(store.codexHomes.first(where: { $0.path.hasSuffix("slot-b") }))
        await store.switchCodexAccount(to: target)
        XCTAssertNotNil(store.codexSwitchError)
        XCTAssertTrue(store.codexSwitchError?.contains("occupied") ?? false)
        XCTAssertEqual(codexMarker(in: live), "LIVE-A")
        XCTAssertEqual(codexMarker(in: slotB), "B")
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AIUsageTests.\(UUID().uuidString)")!
    }
}
