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
    private(set) var requestCount = 0

    init(_ fixtures: [HTTPFixture]) { self.fixtures = fixtures }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
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
}

private struct FixtureCodexSource: CodexAppServerDataSource {
    let data: Data
    func read() async throws -> Data { data }
}

private actor FetchCounter {
    private(set) var value = 0
    func increment() { value += 1 }
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
            "Codex", "Claude", "Cursor", "Copilot", "Gemini", "Windsurf", "Cline", "Roo", "OpenCode"
        ])
        XCTAssertEqual(Provider.supported, [.codex, .claude, .cursor])
        XCTAssertEqual(Provider.codex.menuBarAbbreviation, "C")
        XCTAssertEqual(Provider.claude.menuBarAbbreviation, "A")
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AIUsageTests.\(UUID().uuidString)")!
    }
}
