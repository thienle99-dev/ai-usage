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

private final class LockedAccountFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var reference: String
    private var fingerprint: String
    init(reference: String, fingerprint: String) { self.reference = reference; self.fingerprint = fingerprint }
    func read() -> (reference: String, fingerprint: String, label: String?) {
        lock.lock(); defer { lock.unlock() }
        return (reference, fingerprint, nil)
    }
    func set(reference: String, fingerprint: String) {
        lock.lock(); defer { lock.unlock() }
        self.reference = reference; self.fingerprint = fingerprint
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func getAndClear() -> Bool { lock.lock(); defer { lock.unlock() }; let result = value; value = false; return result }
}

private func isolatedAccountManager(tool: ManagedAccountTool, indexURL: URL) -> DurableAccountSessionManager {
    let identity = LockedAccountFixture(reference: "fixture-session", fingerprint: "fixture-identity")
    return DurableAccountSessionManager(
        tool: tool,
        indexURL: indexURL,
        identify: { identity.read() },
        stage: { _, accountID in "fixture-\(accountID)" },
        activate: { _ in }
    )
}

private actor FixtureHTTPDataLoader: HTTPDataLoading {
    private var fixtures: [HTTPFixture]
    private let routes: [String: HTTPFixture]
    private var requests: [URLRequest] = []
    private(set) var requestCount = 0

    /// `routes` answer by exact URL, for requests that run concurrently and have no stable order.
    init(_ fixtures: [HTTPFixture], routes: [String: HTTPFixture] = [:]) {
        self.fixtures = fixtures
        self.routes = routes
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        requests.append(request)
        let fixture: HTTPFixture
        if let routed = request.url.flatMap({ routes[$0.absoluteString] }) {
            fixture = routed
        } else {
            guard !fixtures.isEmpty else { throw URLError(.badServerResponse) }
            fixture = fixtures.removeFirst()
        }
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

private final class FixtureManagedClaudeCredentialStore: ManagedClaudeCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [String: Data]

    init(credentials: [String: Data]) { self.credentials = credentials }

    func load(accountID: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let credential = credentials[accountID] else { throw ClaudeCodeSessionError.missingCredential }
        return credential
    }

    func save(_ data: Data, accountID: String) throws {
        lock.lock(); defer { lock.unlock() }
        credentials[accountID] = data
    }

    func remove(accountID: String) throws {
        lock.lock(); defer { lock.unlock() }
        credentials.removeValue(forKey: accountID)
    }
}

private struct FixtureCodexSource: CodexAppServerDataSource {
    let data: Data
    func read() async throws -> Data { data }
}

private struct FixtureManagedAccountQuotaFetcher: ManagedAccountQuotaFetching {
    let snapshots: [String: UsageSnapshot]
    func fetch(provider: Provider, account: ManagedAccountRecord) async throws -> UsageSnapshot {
        guard let snapshot = snapshots[account.identityFingerprint] else { throw ProviderFailure.http(401) }
        return snapshot
    }
}

private actor AsyncTestSignal {
    private var isSignaled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        isSignaled = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

private actor BlockingManagedAccountQuotaFetcher: ManagedAccountQuotaFetching {
    let started = AsyncTestSignal()
    let release = AsyncTestSignal()
    let snapshot: UsageSnapshot

    init(snapshot: UsageSnapshot) { self.snapshot = snapshot }

    func fetch(provider: Provider, account: ManagedAccountRecord) async throws -> UsageSnapshot {
        await started.signal()
        await release.wait()
        return snapshot
    }
}

@MainActor private final class FakeAccountLoginProcessHandle: AccountLoginProcessHandle {
    var isRunning = true
    var sentData: [Data] = []
    var onTerminate: (() -> Void)?
    func terminate() { isRunning = false; onTerminate?() }
    func send(_ data: Data) { sentData.append(data) }
}

@MainActor private final class FakeAccountLoginProcessLauncher: AccountLoginProcessLaunching {
    private(set) var arguments: [String] = []
    private(set) var environment: [String: String] = [:]
    private(set) var handle: FakeAccountLoginProcessHandle?
    private var outputHandler: ((Data) -> Void)?
    private var terminationHandler: ((Int32) -> Void)?

    func launch(executable: URL, arguments: [String], environment: [String: String], output: @escaping @MainActor (Data) -> Void, termination: @escaping @MainActor (Int32) -> Void) throws -> any AccountLoginProcessHandle {
        self.arguments = arguments
        self.environment = environment
        outputHandler = output
        terminationHandler = termination
        let handle = FakeAccountLoginProcessHandle()
        handle.onTerminate = { [weak self] in self?.finish(status: 15) }
        self.handle = handle
        return handle
    }

    func emit(_ text: String) { outputHandler?(Data(text.utf8)) }
    func finish(status: Int32 = 0) {
        handle?.isRunning = false
        terminationHandler?(status)
    }
}

@MainActor private final class FakeAccountLoginSessionVerifier: AccountLoginSessionVerifying {
    var shouldFail = false
    var onVerify: (() -> Void)?

    func verifyAndImport(provider: Provider, directory: URL, store: UsageStore) async throws -> ManagedAccountRecord {
        onVerify?()
        if shouldFail { throw ProviderFailure.http(401) }
        return ManagedAccountRecord(id: "imported", label: "fixture", tool: provider == .claude ? .claudeCode : .codex,
                                    sessionReference: "fixture-ref", identityFingerprint: "fixture-fp", registeredAt: .now)
    }
}

private actor MutableCodexSource: CodexAppServerDataSource {
    private var data: Data
    init(data: Data) { self.data = data }
    func update(_ data: Data) { self.data = data }
    func read() async throws -> Data { data }
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

@MainActor private func makeIsolatedAccountStore(root: URL) -> UsageStore {
    let indexURL = root.appendingPathComponent("account-index.json")
    let codexLive = LockedAccountFixture(reference: "live-codex", fingerprint: "codex-live")
    let claudeLive = LockedAccountFixture(reference: "live-claude", fingerprint: "claude-live")
    let codexManager = DurableAccountSessionManager(
        tool: .codex, indexURL: indexURL, identify: { codexLive.read() },
        stage: { source, id in "codex-\(id)-\(source)" }, activate: { _ in }
    )
    let claudeManager = DurableAccountSessionManager(
        tool: .claudeCode, indexURL: indexURL, identify: { claudeLive.read() },
        stage: { source, id in "claude-\(id)-\(source)" }, activate: { _ in }
    )
    let suite = UserDefaults(suiteName: "AIUsageTests.\(UUID().uuidString)")!
    return UsageStore(
        providers: [], defaults: suite, startImmediately: false,
        codexAccountManager: codexManager, codexIndexURL: indexURL,
        claudeCodeAccountManager: claudeManager
    )
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
    func testCodexAdapterStageProducesIndependentCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live")
        let spareRoot = root.appendingPathComponent("spares")
        try makeCodexHomeDir(at: live, marker: "before")
        let adapter = CodexSessionAdapter(liveHomeURL: live, spareRootURL: spareRoot, indexURL: root.appendingPathComponent("index.json"), identify: { (live.path, "account-a", nil) })
        let record = try adapter.manager.stashActiveSession()!
        try Data("after".utf8).write(to: live.appendingPathComponent("marker.txt"))
        XCTAssertEqual(codexMarker(in: URL(fileURLWithPath: record.sessionReference)), "before")
    }

    @MainActor
    func testCodexAccountRemovalDeletesOnlyItsManagedSessionCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live", isDirectory: true)
        let spareRoot = root.appendingPathComponent("spares", isDirectory: true)
        try makeCodexHomeDir(at: live, marker: "live-session")
        let adapter = CodexSessionAdapter(
            liveHomeURL: live,
            spareRootURL: spareRoot,
            indexURL: root.appendingPathComponent("index.json"),
            identify: { (live.path, "fixture-account", "fixture@example.com") }
        )

        let account = try adapter.manager.importSession(reference: live.path, fingerprint: "fixture-account", label: "fixture@example.com")
        let managedCopy = URL(fileURLWithPath: account.sessionReference, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedCopy.appendingPathComponent("auth.json").path))
        try adapter.manager.activateAccount(account.id)
        let store = UsageStore(
            providers: [],
            defaults: UserDefaults(suiteName: "AIUsageTests.\(UUID().uuidString)")!,
            startImmediately: false,
            codexAccountManager: adapter.manager,
            claudeCodeAccountManager: isolatedAccountManager(tool: .claudeCode, indexURL: root.appendingPathComponent("claude-index.json"))
        )

        store.removeManagedAccount(for: .codex, id: account.id)

        XCTAssertNil(store.managedAccountErrors[.codex]?[account.id], store.managedAccountErrors[.codex]?[account.id] ?? "")
        XCTAssertNil(store.codexAccountError, store.codexAccountError ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedCopy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.appendingPathComponent("auth.json").path))
        XCTAssertTrue(store.codexAccounts.isEmpty)
        XCTAssertTrue(try adapter.manager.currentIndex().accounts.isEmpty)
        XCTAssertNil(try adapter.manager.currentIndex().inUse[.codex])
    }

    func testCodexAdapterStageThenActivateRoundTripsAndParksOtherLogin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live")
        let spareRoot = root.appendingPathComponent("spares")
        try makeCodexHomeDir(at: live, marker: "account-a")
        let identity = LockedAccountFixture(reference: live.path, fingerprint: "account-a")
        let adapter = CodexSessionAdapter(liveHomeURL: live, spareRootURL: spareRoot, indexURL: root.appendingPathComponent("index.json"), identify: { identity.read() }, isBusy: { false })
        let first = try adapter.manager.registerCurrentAccount()
        _ = try adapter.manager.stashActiveSession()
        try makeCodexHomeDir(at: live, marker: "account-b")
        identity.set(reference: live.path, fingerprint: "account-b")
        let second = try adapter.manager.stashActiveSession()!
        identity.set(reference: live.path, fingerprint: "account-b")
        try adapter.manager.activateAccount(first.id)
        XCTAssertEqual(codexMarker(in: live), "account-a")
        XCTAssertEqual(codexMarker(in: URL(fileURLWithPath: second.sessionReference)), "account-b")
    }

    func testCodexAdapterRefusesActivateWhileCodexLoginIsRunning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live")
        let spareRoot = root.appendingPathComponent("spares")
        try makeCodexHomeDir(at: live, marker: "account-a")
        let identity = LockedAccountFixture(reference: live.path, fingerprint: "account-a")
        let adapter = CodexSessionAdapter(liveHomeURL: live, spareRootURL: spareRoot, indexURL: root.appendingPathComponent("index.json"), identify: { identity.read() }, isBusy: { false })
        let first = try adapter.manager.registerCurrentAccount()
        try makeCodexHomeDir(at: live, marker: "account-b")
        identity.set(reference: live.path, fingerprint: "account-b")
        _ = try adapter.manager.stashActiveSession()

        let busy = CodexSessionAdapter(liveHomeURL: live, spareRootURL: spareRoot, indexURL: root.appendingPathComponent("index.json"), identify: { identity.read() }, isBusy: { true })
        XCTAssertThrowsError(try busy.manager.activateAccount(first.id)) { error in
            XCTAssertEqual(error.localizedDescription, CodexSessionAdapterError.busy.localizedDescription)
        }
        XCTAssertEqual(codexMarker(in: live), "account-b")
    }

    func testCodexAdapterActivateRejectsReferenceWithoutAuthAndPreservesLive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live")
        let spareRoot = root.appendingPathComponent("spares")
        try makeCodexHomeDir(at: live, marker: "live")
        let identity = LockedAccountFixture(reference: live.path, fingerprint: "account-a")
        let adapter = CodexSessionAdapter(liveHomeURL: live, spareRootURL: spareRoot, indexURL: root.appendingPathComponent("index.json"), identify: { identity.read() })
        let selected = try adapter.manager.registerCurrentAccount()
        let staged = try adapter.manager.stashActiveSession()!
        try FileManager.default.removeItem(at: URL(fileURLWithPath: staged.sessionReference).appendingPathComponent("auth.json"))
        identity.set(reference: live.path, fingerprint: "account-b")
        XCTAssertThrowsError(try adapter.manager.activateAccount(selected.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.appendingPathComponent("auth.json").path))
        XCTAssertEqual(codexMarker(in: live), "live")
    }

    func testCodexAdapterUnknownIdentityRegisterAndStashWriteNothing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live")
        try makeCodexHomeDir(at: live, marker: "live")
        let index = root.appendingPathComponent("index.json")
        let adapter = CodexSessionAdapter(liveHomeURL: live, spareRootURL: root.appendingPathComponent("spares"), indexURL: index, identify: { (live.path, "", nil) })
        XCTAssertThrowsError(try adapter.manager.registerCurrentAccount())
        XCTAssertThrowsError(try adapter.manager.stashActiveSession())
        XCTAssertFalse(FileManager.default.fileExists(atPath: index.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("spares").path))
    }

    func testCodexAdapterSafeToChangeThrowsWhenLiveHomeMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("missing")
        let adapter = CodexSessionAdapter(liveHomeURL: live, spareRootURL: root.appendingPathComponent("spares"), indexURL: root.appendingPathComponent("index.json"), identify: { (live.path, "account-a", nil) })
        XCTAssertThrowsError(try adapter.manager.activateAccount("none"))
    }

    func testDurableAccountSessionManagerRegistersAndActivatesIdentifiedAccount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("state.json")
        let live = LockedAccountFixture(reference: "live-a", fingerprint: "service-id-a")
        let manager = DurableAccountSessionManager(tool: .codex, indexURL: indexURL,
            identify: { live.read() },
            stage: { source, id in "parked-\(id)-\(source)" },
            activate: { reference in live.set(reference: reference, fingerprint: reference == "parked-b" ? "service-id-b" : "service-id-a") })
        let first = try manager.registerCurrentAccount(label: "Personal")
        XCTAssertEqual(first.identityFingerprint, "service-id-a")
        XCTAssertEqual(try manager.registerCurrentAccount().id, first.id)
        let savedIndex = try JSONDecoder().decode(AccountSessionIndex.self, from: Data(contentsOf: indexURL))
        XCTAssertEqual(savedIndex.inUse[.codex], first.id)
        XCTAssertNil(savedIndex.journal)
    }

    func testAccountSessionRegisterDeduplicatesFingerprintAndStoresDifferentAccounts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = LockedAccountFixture(reference: "opaque-ref-a", fingerprint: "fp-a")
        let manager = DurableAccountSessionManager(tool: .codex, indexURL: root.appendingPathComponent("state.json"),
            identify: { live.read() }, stage: { source, id in "parked-\(id)-\(source)" }, activate: { _ in })
        let first = try manager.registerCurrentAccount()
        XCTAssertEqual(try manager.registerCurrentAccount().id, first.id)
        live.set(reference: "opaque-ref-b", fingerprint: "fp-b")
        XCTAssertNotEqual(try manager.registerCurrentAccount().id, first.id)
        let data = try Data(contentsOf: root.appendingPathComponent("state.json"))
        XCTAssertNil(String(data: data, encoding: .utf8)?.range(of: "secret-credential-fixture"))
        let mode = (try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("state.json").path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode.map { $0 & 0o777 }, 0o600)
    }

    func testImportedAccountUpdatesDuplicateWithoutChangingInUse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = LockedAccountFixture(reference: "live-a", fingerprint: "fp-a")
        let manager = DurableAccountSessionManager(
            tool: .codex,
            indexURL: root.appendingPathComponent("state.json"),
            identify: { live.read() },
            stage: { source, id in "managed-\(id)-\(source)" },
            activate: { _ in }
        )
        let active = try manager.registerCurrentAccount()
        let added = try manager.importSession(reference: "isolated-b", fingerprint: "fp-b", label: "B")
        XCTAssertEqual(try manager.currentIndex().inUse[.codex], active.id)
        XCTAssertEqual(added.sessionReference, "managed-\(added.id)-isolated-b")

        let updated = try manager.importSession(reference: "isolated-b-refreshed", fingerprint: "fp-b", label: "B updated")
        let index = try manager.currentIndex()
        XCTAssertEqual(index.accounts.count, 2)
        XCTAssertEqual(updated.id, added.id)
        XCTAssertEqual(updated.label, "B updated")
        XCTAssertEqual(updated.sessionReference, "managed-\(updated.id)-isolated-b-refreshed")
        XCTAssertEqual(index.inUse[.codex], active.id)
    }

    func testClaudeImportMergesAccountsByEmailAndKeepsActiveRecord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("state.json")
        let live = LockedAccountFixture(reference: "live-current", fingerprint: "fp-current")
        let exactMatcher = DurableAccountSessionManager(
            tool: .claudeCode,
            indexURL: indexURL,
            identify: { live.read() },
            stage: { _, id in ClaudeCodeCredentialVault.reference(id) },
            activate: { _ in }
        )
        let current = try exactMatcher.registerCurrentAccount(label: "current@example.com · Pro")
        let firstDuplicate = try exactMatcher.importSession(
            reference: "first-session", fingerprint: "fp-account", label: "person@example.com · Pro"
        )
        let activeDuplicate = try exactMatcher.importSession(
            reference: "second-session", fingerprint: "fp-organization", label: "person@example.com · Pro"
        )
        try exactMatcher.activateAccount(activeDuplicate.id)

        let credentialStore = FixtureManagedClaudeCredentialStore(credentials: [
            firstDuplicate.id: Data("old-first".utf8),
            activeDuplicate.id: Data("old-active".utf8)
        ])
        let adapter = ClaudeCodeSessionAdapter(
            configDirectory: root.appendingPathComponent("claude-config", isDirectory: true),
            indexURL: indexURL,
            credentialStore: credentialStore
        )

        let updated = try adapter.manager.importSession(
            reference: "new-session", fingerprint: "fp-new-organization", label: "person@example.com · Max"
        )
        let index = try adapter.manager.currentIndex()

        XCTAssertEqual(updated.id, activeDuplicate.id)
        XCTAssertEqual(updated.identityFingerprint, "fp-new-organization")
        XCTAssertEqual(updated.label, "person@example.com · Max")
        XCTAssertEqual(updated.sessionReference, ClaudeCodeCredentialVault.reference(activeDuplicate.id))
        XCTAssertEqual(index.accounts.count, 2)
        XCTAssertTrue(index.accounts.contains(where: { $0.id == current.id }))
        XCTAssertTrue(index.accounts.contains(where: { $0.id == activeDuplicate.id }))
        XCTAssertFalse(index.accounts.contains(where: { $0.id == firstDuplicate.id }))
        XCTAssertEqual(index.inUse[.claudeCode], activeDuplicate.id)
        XCTAssertEqual(try credentialStore.load(accountID: activeDuplicate.id), Data("new-session".utf8))
        XCTAssertThrowsError(try credentialStore.load(accountID: firstDuplicate.id))
        XCTAssertTrue(ClaudeCodeSessionAdapter.sameEmail("person@example.com · Pro", "PERSON@example.com · Max"))
        XCTAssertFalse(ClaudeCodeSessionAdapter.sameEmail("person@example.com · Pro", "other@example.com · Pro"))
        XCTAssertFalse(ClaudeCodeSessionAdapter.sameEmail("person@example.com · Pro", nil))
    }

    @MainActor
    func testClaudeCodeAccountRemovalDeletesManagedCredential() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentialStore = FixtureManagedClaudeCredentialStore(credentials: [:])
        let adapter = ClaudeCodeSessionAdapter(
            configDirectory: root.appendingPathComponent("claude-config", isDirectory: true),
            indexURL: root.appendingPathComponent("index.json"),
            credentialStore: credentialStore
        )
        let credential = Data("claude-session-fixture".utf8)
        let account = try adapter.manager.importSession(reference: String(decoding: credential, as: UTF8.self), fingerprint: "claude-fingerprint", label: "claude@example.com")

        XCTAssertEqual(try credentialStore.load(accountID: account.id), credential)
        let store = UsageStore(
            providers: [],
            defaults: UserDefaults(suiteName: "AIUsageTests.\(UUID().uuidString)")!,
            startImmediately: false,
            codexAccountManager: isolatedAccountManager(tool: .codex, indexURL: root.appendingPathComponent("codex-index.json")),
            claudeCodeAccountManager: adapter.manager
        )
        store.removeManagedAccount(for: .claude, id: account.id)

        XCTAssertNil(store.managedAccountErrors[.claude]?[account.id], store.managedAccountErrors[.claude]?[account.id] ?? "")
        XCTAssertThrowsError(try credentialStore.load(accountID: account.id))
        XCTAssertTrue(store.claudeCodeAccounts.isEmpty)
        XCTAssertTrue(try adapter.manager.currentIndex().accounts.isEmpty)
    }

    func testInterruptedImportCanBeRetriedWithoutChangingInUse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = LockedAccountFixture(reference: "live-a", fingerprint: "fp-a")
        let shouldFail = LockedAccountFixture(reference: "yes", fingerprint: "")
        let manager = DurableAccountSessionManager(
            tool: .codex,
            indexURL: root.appendingPathComponent("state.json"),
            identify: { live.read() },
            stage: { source, _ in
                if shouldFail.read().fingerprint.isEmpty { throw ProviderFailure.process("injected stage failure") }
                return "managed-\(source)"
            },
            activate: { _ in }
        )
        let active = try manager.registerCurrentAccount()
        XCTAssertThrowsError(try manager.importSession(reference: "isolated-b", fingerprint: "fp-b", label: nil))
        shouldFail.set(reference: "no", fingerprint: "ok")
        let added = try manager.importSession(reference: "isolated-b", fingerprint: "fp-b", label: nil)
        let index = try manager.currentIndex()
        XCTAssertNil(index.journal)
        XCTAssertEqual(index.inUse[.codex], active.id)
        XCTAssertEqual(index.accounts.count, 2)
        XCTAssertEqual(added.sessionReference, "managed-isolated-b")
    }

    func testSwitchAutomaticallyPreservesAnUnregisteredLiveSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = LockedAccountFixture(reference: "live-a", fingerprint: "fp-a")
        let manager = DurableAccountSessionManager(
            tool: .codex,
            indexURL: root.appendingPathComponent("state.json"),
            identify: { live.read() },
            stage: { source, id in "parked-\(id)-\(source)" },
            activate: { reference in live.set(reference: reference, fingerprint: "fp-b") }
        )
        let added = try manager.importSession(reference: "isolated-b", fingerprint: "fp-b", label: "B")

        try manager.activateAccount(added.id)

        let index = try manager.currentIndex()
        XCTAssertEqual(index.inUse[.codex], added.id)
        XCTAssertEqual(index.accounts.count, 2)
        let preserved = try XCTUnwrap(index.accounts.first(where: { $0.identityFingerprint == "fp-a" }))
        XCTAssertEqual(preserved.sessionReference, "parked-\(preserved.id)-live-a")
    }

    @MainActor
    func testManagedQuotaIsStoredUnderRequestedAccountWithoutReplacingLiveSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = LockedAccountFixture(reference: "live-home", fingerprint: "active-a")
        let manager = DurableAccountSessionManager(
            tool: .codex,
            indexURL: root.appendingPathComponent("state.json"),
            identify: { live.read() },
            stage: { source, id in "managed-\(id)-\(source)" },
            activate: { _ in }
        )
        _ = try manager.registerCurrentAccount(label: "A")
        let accountBQuota = UsageSnapshot(
            provider: .codex,
            windows: [UsageWindow(label: "5-hour limit", utilization: 27, resetsAt: nil)],
            account: "B", accountID: "not-the-record-id", lastSuccess: .now
        )
        let store = UsageStore(
            providers: [], defaults: isolatedDefaults(), startImmediately: false,
            codexAccountManager: manager,
            accountQuotaFetcher: FixtureManagedAccountQuotaFetcher(snapshots: ["account-b": accountBQuota])
        )
        store.snapshots[.codex] = UsageSnapshot(
            provider: .codex,
            windows: [UsageWindow(label: "5-hour limit", utilization: 88, resetsAt: nil)],
            account: "A", accountID: "active-a", lastSuccess: .now
        )
        try store.importAccount(for: .codex, reference: "isolated-home-b", fingerprint: "account-b", label: "B")
        let accountB = try XCTUnwrap(store.codexAccounts.first(where: { $0.identityFingerprint == "account-b" }))

        await store.refreshManagedAccountQuota(for: .codex, accountID: accountB.id)

        XCTAssertEqual(store.snapshots[.codex]?.accountID, "active-a")
        XCTAssertEqual(store.snapshots[.codex]?.windows.first?.validUtilization, 88)
        XCTAssertEqual(store.managedAccountSnapshots[.codex]?[accountB.id]?.accountID, accountB.id)
        XCTAssertEqual(store.managedAccountSnapshots[.codex]?[accountB.id]?.windows.first?.validUtilization, 27)
    }

    @MainActor
    func testManagedQuotaRefreshAndSwitchKeepResultAttachedToItsAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = LockedAccountFixture(reference: "live-a", fingerprint: "fp-a")
        let activated = AsyncTestSignal()
        let indexURL = root.appendingPathComponent("index.json")
        let codexManager = DurableAccountSessionManager(
            tool: .codex, indexURL: indexURL, identify: { live.read() },
            stage: { source, id in "managed-\(id)-\(source)" },
            activate: { reference in
                live.set(reference: reference, fingerprint: "fp-b")
                Task { await activated.signal() }
            }
        )
        let claudeManager = DurableAccountSessionManager(
            tool: .claudeCode, indexURL: indexURL,
            identify: { ("claude", "claude", nil) }, stage: { source, _ in source }, activate: { _ in }
        )
        _ = try codexManager.registerCurrentAccount(label: "A")
        let quotaFetcher = BlockingManagedAccountQuotaFetcher(snapshot: UsageSnapshot(
            provider: .codex, windows: [UsageWindow(label: "5-hour limit", utilization: 21, resetsAt: nil)],
            account: "B", accountID: nil, lastSuccess: .now
        ))
        let store = UsageStore(
            providers: [], defaults: UserDefaults(suiteName: "AIUsageTests.\(UUID().uuidString)" )!,
            startImmediately: false, codexAccountManager: codexManager,
            codexIndexURL: indexURL, claudeCodeAccountManager: claudeManager,
            accountQuotaFetcher: quotaFetcher
        )
        try store.importAccount(for: .codex, reference: "isolated-b", fingerprint: "fp-b", label: "B")
        let accountB = try XCTUnwrap(store.codexAccounts.first(where: { $0.identityFingerprint == "fp-b" }))
        let refreshTask = Task { await store.refreshManagedAccountQuota(for: .codex, accountID: accountB.id) }
        await quotaFetcher.started.wait()

        await store.activateManagedAccount(for: .codex, id: accountB.id)
        await quotaFetcher.release.signal()
        await refreshTask.value
        await activated.wait()
        for _ in 0..<100 where store.codexInUseAccountID != accountB.id {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(store.managedAccountSnapshots[.codex]?[accountB.id]?.accountID, accountB.id)
        XCTAssertEqual(store.managedAccountSnapshots[.codex]?[accountB.id]?.windows.first?.validUtilization, 21)
        XCTAssertEqual(store.codexInUseAccountID, accountB.id)
        XCTAssertEqual(try codexManager.currentIndex().inUse[.codex], accountB.id)
    }

    @MainActor
    func testAccountLoginCoordinatorImportsAfterFakeCLICompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeIsolatedAccountStore(root: root)
        let launcher = FakeAccountLoginProcessLauncher()
        let verifier = FakeAccountLoginSessionVerifier()
        let verified = expectation(description: "fake login verified")
        verifier.onVerify = { verified.fulfill() }
        let coordinator = AccountLoginCoordinator(
            store: store,
            processLauncher: launcher,
            sessionVerifier: verifier,
            draftRootURL: root.appendingPathComponent("drafts"),
            cliExecutable: { _ in URL(fileURLWithPath: "/fake/claude") }
        )

        coordinator.beginSignIn()
        XCTAssertEqual(coordinator.phase, .signingIn)
        XCTAssertNotNil(launcher.environment["CLAUDE_CONFIG_DIR"])
        XCTAssertNil(launcher.environment["CLAUDE_CODE_OAUTH_TOKEN"])
        launcher.emit("Open https://example.test/login and paste code here")
        XCTAssertEqual(coordinator.loginURL?.host, "example.test")
        XCTAssertTrue(coordinator.requestsCode)
        coordinator.submitCode("123456")
        XCTAssertEqual(launcher.handle?.sentData.last, Data("123456\n".utf8))
        launcher.finish()

        await fulfillment(of: [verified], timeout: 2)
        XCTAssertEqual(coordinator.phase, .succeeded)
        XCTAssertFalse(coordinator.isRunning)
    }

    @MainActor
    func testAccountLoginCoordinatorStartsIsolatedCodexSignIn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = FakeAccountLoginProcessLauncher()
        let coordinator = AccountLoginCoordinator(
            store: makeIsolatedAccountStore(root: root), processLauncher: launcher,
            draftRootURL: root.appendingPathComponent("drafts"),
            cliExecutable: { _ in URL(fileURLWithPath: "/fake/codex") }
        )

        coordinator.select(.codex)
        coordinator.beginSignIn()

        XCTAssertEqual(coordinator.phase, .signingIn)
        XCTAssertEqual(launcher.arguments, ["-c", "cli_auth_credentials_store=\"file\"", "login"])
        XCTAssertNotNil(launcher.environment["CODEX_HOME"])
        XCTAssertNil(launcher.environment["CLAUDE_CONFIG_DIR"])
        XCTAssertNil(launcher.environment["OPENAI_API_KEY"])
        await coordinator.cancel()
        XCTAssertEqual(coordinator.phase, .cancelled)
    }

    @MainActor
    func testAntigravitySignInOpensTerminalAndImportsNewSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("account-index.json")
        let live = LockedAccountFixture(reference: "live-agy", fingerprint: "agy-live")
        let agyManager = DurableAccountSessionManager(
            tool: .antigravity, indexURL: indexURL, identify: { live.read() },
            stage: { source, id in "agy-\(id)-\(source)" }, activate: { _ in }
        )
        let suite = UserDefaults(suiteName: "AIUsageTests.\(UUID().uuidString)")!
        let store = UsageStore(
            providers: [], defaults: suite, startImmediately: false,
            codexIndexURL: indexURL, antigravityAccountManager: agyManager
        )
        var key = "old@example.com"
        var launchedScript: URL?
        var cleared = false
        var scriptText = ""
        let coordinator = AccountLoginCoordinator(
            store: store, processLauncher: FakeAccountLoginProcessLauncher(),
            draftRootURL: root.appendingPathComponent("drafts"),
            cliExecutable: { _ in URL(fileURLWithPath: "/fake/it's agy") },
            terminalLauncher: { url in
                launchedScript = url
                scriptText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            },
            antigravitySessionKey: { key },
            antigravitySessionClearer: { cleared = true },
            antigravityPollInterval: .milliseconds(10)
        )

        coordinator.select(.antigravity)
        coordinator.beginSignIn()
        XCTAssertTrue(coordinator.isRunning)
        for _ in 0..<200 where coordinator.phase != .signingIn { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertEqual(coordinator.phase, .signingIn)
        XCTAssertTrue(cleared)
        XCTAssertTrue(scriptText.contains("exec '/fake/it'\\''s agy'"), scriptText)
        let script = try XCTUnwrap(launchedScript)
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path))

        key = "new@example.com"
        for _ in 0..<200 where coordinator.phase == .signingIn || coordinator.phase == .verifying {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotEqual(coordinator.phase, .signingIn)
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path))
    }

    @MainActor
    func testAntigravitySignInCancelRemovesScript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("account-index.json")
        let live = LockedAccountFixture(reference: "live-agy", fingerprint: "agy-live")
        let agyManager = DurableAccountSessionManager(
            tool: .antigravity, indexURL: indexURL, identify: { live.read() },
            stage: { source, id in "agy-\(id)-\(source)" }, activate: { _ in }
        )
        let store = UsageStore(
            providers: [], defaults: UserDefaults(suiteName: "AIUsageTests.\(UUID().uuidString)")!, startImmediately: false,
            codexIndexURL: indexURL, antigravityAccountManager: agyManager
        )
        var launchedScript: URL?
        let coordinator = AccountLoginCoordinator(
            store: store, processLauncher: FakeAccountLoginProcessLauncher(),
            draftRootURL: root.appendingPathComponent("drafts"),
            cliExecutable: { _ in URL(fileURLWithPath: "/fake/agy") },
            terminalLauncher: { launchedScript = $0 },
            antigravitySessionKey: { "same@example.com" },
            antigravitySessionClearer: {},
            antigravityPollInterval: .milliseconds(10)
        )

        coordinator.select(.antigravity)
        coordinator.beginSignIn()
        for _ in 0..<200 where coordinator.phase != .signingIn { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(coordinator.phase, .signingIn)

        await coordinator.cancel()
        XCTAssertEqual(coordinator.phase, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(launchedScript).path))
    }

    @MainActor
    func testSaveCurrentAccountActionPreservesClaudeAndCodexSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeIsolatedAccountStore(root: root)

        try store.saveCurrentAccount(for: .claude)
        try store.saveCurrentAccount(for: .codex)

        XCTAssertEqual(store.claudeCodeAccounts.count, 1)
        XCTAssertEqual(store.codexAccounts.count, 1)
        XCTAssertEqual(store.claudeCodeAccounts.first?.tool, .claudeCode)
        XCTAssertEqual(store.codexAccounts.first?.tool, .codex)
        XCTAssertEqual(store.claudeCodeInUseAccountID, store.claudeCodeAccounts.first?.id)
        XCTAssertEqual(store.codexInUseAccountID, store.codexAccounts.first?.id)
    }

    @MainActor
    func testAccountLoginCoordinatorShowsRetryableVerificationFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = FakeAccountLoginProcessLauncher()
        let verifier = FakeAccountLoginSessionVerifier()
        verifier.shouldFail = true
        let verified = expectation(description: "fake login verified")
        verifier.onVerify = { verified.fulfill() }
        let coordinator = AccountLoginCoordinator(
            store: makeIsolatedAccountStore(root: root), processLauncher: launcher, sessionVerifier: verifier,
            draftRootURL: root.appendingPathComponent("drafts"), cliExecutable: { _ in URL(fileURLWithPath: "/fake/claude") }
        )

        coordinator.beginSignIn()
        let sessionPath = try XCTUnwrap(launcher.environment["CLAUDE_CONFIG_DIR"])
        launcher.finish()
        await fulfillment(of: [verified], timeout: 2)

        guard case .failed = coordinator.phase else { return XCTFail("expected a retryable failure") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionPath))
    }

    @MainActor
    func testAccountLoginCoordinatorCancelsFakeCLIAndCleansDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = FakeAccountLoginProcessLauncher()
        let coordinator = AccountLoginCoordinator(
            store: makeIsolatedAccountStore(root: root), processLauncher: launcher,
            draftRootURL: root.appendingPathComponent("drafts"), cliExecutable: { _ in URL(fileURLWithPath: "/fake/claude") }
        )

        coordinator.beginSignIn()
        let sessionPath = try XCTUnwrap(launcher.environment["CLAUDE_CONFIG_DIR"])
        await coordinator.cancel()

        XCTAssertEqual(coordinator.phase, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("drafts/pending.json").path))
    }

    func testAntigravityMigrationImportsOnlyAccountsWithKeychainCredentials() {
        let date = Date(timeIntervalSince1970: 100)
        let accounts = [
            AntigravityAccount(id: "kept", identity: "user@example.com", addedAt: date),
            AntigravityAccount(id: "missing", identity: "other@example.com", addedAt: date)
        ]
        let (records, activeID) = migrateAntigravityAccounts(accounts, availableCredentialIDs: ["kept"], activeID: "missing")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, "kept")
        XCTAssertEqual(records[0].tool, .antigravity)
        XCTAssertEqual(records[0].sessionReference, "kept")
        XCTAssertEqual(records[0].label, "user@example.com")
        XCTAssertNil(activeID)
    }

    @MainActor
    func testAntigravityAccountRemovalDeletesCredentialAndClearsSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "AIUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let accountID = "antigravity-fixture-account"
        let credential = LockedAccountFixture(reference: "", fingerprint: "")
        let manager = AntigravityAccountVault.managedSessionAdapter(
            indexURL: root.appendingPathComponent("antigravity-index.json"),
            defaults: defaults,
            removeCredential: { reference in credential.set(reference: reference, fingerprint: "deleted") }
        )
        let record = ManagedAccountRecord(
            id: accountID, label: "user@example.com", tool: .antigravity,
            sessionReference: "credential-reference", identityFingerprint: "identity", registeredAt: .now
        )
        try manager.importAccountsOnce([record], migrationID: "antigravity-delete-fixture", activeAccountID: accountID)
        defaults.set(accountID, forKey: AntigravityAccountVault.activeDefaultsKey)

        let store = UsageStore(
            providers: [], defaults: defaults, startImmediately: false,
            codexAccountManager: isolatedAccountManager(tool: .codex, indexURL: root.appendingPathComponent("codex-index.json")),
            claudeCodeAccountManager: isolatedAccountManager(tool: .claudeCode, indexURL: root.appendingPathComponent("claude-index.json")),
            antigravityAccountManager: manager
        )
        XCTAssertEqual(store.antigravityAccounts.map(\.id), [accountID])

        store.removeAntigravityAccount(accountID)

        XCTAssertEqual(credential.read().reference, "credential-reference")
        XCTAssertEqual(credential.read().fingerprint, "deleted")
        XCTAssertNil(defaults.string(forKey: AntigravityAccountVault.activeDefaultsKey))
        XCTAssertTrue(store.antigravityAccounts.isEmpty)
        XCTAssertTrue(try manager.currentIndex().accounts.isEmpty)
        XCTAssertNil(try manager.currentIndex().inUse[.antigravity])
    }

    func testClaudeDesktopAdapterMovesSessionsWithoutCopyingAndSwitchesFromSignedOut() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("Claude", isDirectory: true)
        let parked = root.appendingPathComponent("parked", isDirectory: true)
        let indexURL = root.appendingPathComponent("index.json")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: live.appendingPathComponent("Local Storage"), withIntermediateDirectories: true)
        try Data("untouched".utf8).write(to: live.appendingPathComponent("Preferences"))
        func writeCookie(_ value: Data) throws {
            let url = live.appendingPathComponent("Cookies")
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE meta (key TEXT, value TEXT); INSERT INTO meta VALUES ('version', '24'); CREATE TABLE cookies (host_key TEXT, name TEXT, path TEXT, encrypted_value BLOB)", nil, nil, nil), SQLITE_OK)
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO cookies VALUES (?, ?, ?, ?)", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, ".claude.ai", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(statement, 2, "sessionKey", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(statement, 3, "/", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            _ = value.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
        try writeCookie(Data("v10-session-a".utf8))
        let originalInode = try FileManager.default.attributesOfItem(atPath: live.appendingPathComponent("Cookies").path)[.systemFileNumber] as? NSNumber
        let adapter = ClaudeDesktopSessionAdapter(liveDataURL: live, parkedRootURL: parked, indexURL: indexURL, isAppRunning: { false })

        let work = try XCTUnwrap(adapter.manager.stashActiveSession(label: "Work"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.appendingPathComponent("Cookies").path))
        let workPark = try XCTUnwrap(try adapter.manager.currentIndex().accounts.first(where: { $0.id == work.id })).sessionReference
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: workPark).appendingPathComponent("Cookies").path))
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("Preferences"), encoding: .utf8), "untouched")

        try writeCookie(Data("v10-session-home".utf8))
        let home = try XCTUnwrap(adapter.manager.stashActiveSession(label: "Home"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.appendingPathComponent("Cookies").path))
        try adapter.manager.activateAccount(work.id)
        let restoredInode = try FileManager.default.attributesOfItem(atPath: live.appendingPathComponent("Cookies").path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(originalInode, restoredInode, "the session database is moved back, never copied")
        try adapter.manager.activateAccount(home.id)
        try adapter.manager.activateAccount(work.id)
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("Preferences"), encoding: .utf8), "untouched")
        let index = try adapter.manager.currentIndex()
        let homePark = try XCTUnwrap(index.accounts.first(where: { $0.id == home.id })).sessionReference
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: homePark).appendingPathComponent("Cookies").path))
        XCTAssertEqual(index.inUse[.claudeDesktop], work.id)
        XCTAssertNil(index.journal)

        try adapter.manager.removeAccount(home.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: homePark))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.appendingPathComponent("Cookies").path))
        try adapter.manager.removeAccount(work.id)
        let afterRemoval = try adapter.manager.currentIndex()
        XCTAssertTrue(afterRemoval.accounts.isEmpty)
        XCTAssertNil(afterRemoval.inUse[.claudeDesktop])
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.appendingPathComponent("Cookies").path))
    }

    func testClaudeDesktopAdapterRefusesToMoveWhileAppIsRunning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("Claude", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        let adapter = ClaudeDesktopSessionAdapter(liveDataURL: live, parkedRootURL: root.appendingPathComponent("parked"),
            indexURL: root.appendingPathComponent("index.json"), isAppRunning: { true })
        XCTAssertThrowsError(try adapter.manager.stashActiveSession()) { error in
            XCTAssertEqual(error as? ClaudeDesktopSessionError, .appRunning)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("parked").path))
    }

    func testClaudeDesktopRecoveryRestoresPreviousSessionAndKeepsTargetParked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("Claude", isDirectory: true)
        let parked = root.appendingPathComponent("parked", isDirectory: true)
        let previous = parked.appendingPathComponent("parked-previous", isDirectory: true)
        let target = parked.appendingPathComponent("parked-target", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("previous-session".utf8).write(to: previous.appendingPathComponent("Cookies"))
        try Data("target-session".utf8).write(to: target.appendingPathComponent("Cookies"))
        let journal = AccountSessionJournal(operation: .activate, tool: .claudeDesktop, accountID: "target",
            previousID: "previous", previousFingerprint: "previous-fingerprint", targetFingerprint: "target-fingerprint",
            stagedReference: nil, startedAt: .now)

        try ClaudeDesktopSessionAdapter.recover(journal: journal, live: live, parkedRoot: parked, fileManager: .default)

        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("Cookies"), encoding: .utf8), "previous-session")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("Cookies"), encoding: .utf8), "target-session")
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.appendingPathComponent("Cookies").path))
    }

    func testAccountRemovalJournalsBeforeCleanupAndRetriesAfterFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let failFirstRemoval = LockedFlag(true)
        let identity = LockedAccountFixture(reference: "live", fingerprint: "live-fingerprint")
        let manager = DurableAccountSessionManager(
            tool: .codex,
            indexURL: root.appendingPathComponent("accounts.json"),
            identify: { identity.read() },
            stage: { _, accountID in "managed-\(accountID)" },
            activate: { _ in },
            removeAccountResource: { _, _ in
                if failFirstRemoval.getAndClear() { throw CocoaError(.fileWriteUnknown) }
            }
        )
        let account = ManagedAccountRecord(
            id: "account-to-remove", label: "test@example.com", tool: .codex,
            sessionReference: "managed-session", identityFingerprint: "account-fingerprint", registeredAt: .now
        )
        try manager.importAccountsOnce([account], migrationID: "remove-retry-fixture")

        XCTAssertThrowsError(try manager.removeAccount(account.id))
        let interruptedIndex = try manager.currentIndex()
        XCTAssertEqual(interruptedIndex.accounts, [account])
        XCTAssertEqual(interruptedIndex.journal?.operation, .removeAccount)

        try manager.removeAccount(account.id)

        let completedIndex = try manager.currentIndex()
        XCTAssertTrue(completedIndex.accounts.isEmpty)
        XCTAssertNil(completedIndex.journal)
        XCTAssertNil(completedIndex.inUse[.codex])
    }

    func testAccountRemovalRetriesWhenFinalIndexCommitFailsAfterCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let failFinalCommit = LockedFlag(true)
        let resource = LockedAccountFixture(reference: "present", fingerprint: "")
        let indexURL = root.appendingPathComponent("accounts.json")
        let manager = DurableAccountSessionManager(
            tool: .codex,
            indexURL: indexURL,
            identify: { ("live", "live-fingerprint", nil) },
            stage: { _, accountID in "managed-\(accountID)" },
            activate: { _ in },
            removeAccountResource: { _, _ in resource.set(reference: "removed", fingerprint: "") },
            indexWriter: { data, url, fileManager in
                if let index = try? JSONDecoder().decode(AccountSessionIndex.self, from: data),
                   index.accounts.isEmpty, index.journal == nil,
                   failFinalCommit.getAndClear() {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: url, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        )
        let account = ManagedAccountRecord(
            id: "account-to-remove-after-commit-failure", label: "test@example.com", tool: .codex,
            sessionReference: "managed-session", identityFingerprint: "account-fingerprint", registeredAt: .now
        )
        try manager.importAccountsOnce([account], migrationID: "remove-commit-retry-fixture")

        XCTAssertThrowsError(try manager.removeAccount(account.id))

        let interruptedIndex = try manager.currentIndex()
        XCTAssertEqual(resource.read().reference, "removed")
        XCTAssertEqual(interruptedIndex.accounts, [account])
        XCTAssertEqual(interruptedIndex.journal?.operation, .removeAccount)

        try manager.removeAccount(account.id)

        let completedIndex = try manager.currentIndex()
        XCTAssertTrue(completedIndex.accounts.isEmpty)
        XCTAssertNil(completedIndex.journal)
        XCTAssertNil(completedIndex.inUse[.codex])
        XCTAssertEqual(resource.read().reference, "removed")
    }

    func testAccountSessionStashAndActivateRoundTripAndClearJournal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = LockedAccountFixture(reference: "ref-a", fingerprint: "fp-a")
        let manager = DurableAccountSessionManager(tool: .codex, indexURL: root.appendingPathComponent("state.json"),
            identify: { live.read() },
            stage: { source, id in "spare-\(id)-\(source)" },
            activate: { reference in
                let fp = reference == "ref-a" ? "fp-a" : "fp-b"
                live.set(reference: reference, fingerprint: fp)
            })
        let first = try manager.registerCurrentAccount()
        live.set(reference: "ref-b", fingerprint: "fp-b")
        let second = try manager.stashActiveSession()!
        XCTAssertNotEqual(first.id, second.id)
        try manager.activateAccount(first.id)
        XCTAssertEqual(live.read().fingerprint, "fp-a")
        let index = try JSONDecoder().decode(AccountSessionIndex.self, from: Data(contentsOf: root.appendingPathComponent("state.json")))
        XCTAssertNil(index.journal)
        XCTAssertEqual(index.inUse[.codex], first.id)
    }

    func testAccountSessionUnidentifiedDoesNotRecordOrStage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DurableAccountSessionManager(tool: .codex, indexURL: root.appendingPathComponent("state.json"),
            identify: { ("opaque", "", nil) }, stage: { _, _ in XCTFail("unidentified account must not stage"); return "spare" }, activate: { _ in })
        XCTAssertThrowsError(try manager.registerCurrentAccount())
        XCTAssertThrowsError(try manager.stashActiveSession())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json").path))
    }

    func testAccountSessionRecoversAfterStageAndActivateFailuresWithoutLosingRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("state.json")
        let live = LockedAccountFixture(reference: "ref-a", fingerprint: "fp-a")
        let shouldFailStage = LockedFlag(true)
        let shouldFailActivate = LockedFlag(true)
        let manager = DurableAccountSessionManager(tool: .codex, indexURL: indexURL,
            identify: { live.read() },
            stage: { source, id in
                if shouldFailStage.getAndClear() { throw AccountSessionError.lockFailed }
                return "spare-\(id)-\(source)"
            }, activate: { reference in
                live.set(reference: reference, fingerprint: reference == "ref-a" ? "fp-a" : "fp-b")
                if shouldFailActivate.getAndClear() { throw AccountSessionError.recoveryRequired("injected activation interruption") }
            })
        let first = try manager.registerCurrentAccount()
        XCTAssertThrowsError(try manager.stashActiveSession())
        let afterStageFailure = try JSONDecoder().decode(AccountSessionIndex.self, from: Data(contentsOf: indexURL))
        XCTAssertEqual(afterStageFailure.accounts.map(\.id), [first.id])
        XCTAssertNotNil(afterStageFailure.journal)
        // Next operation resolves the interrupted stash from the still-live identity.
        XCTAssertEqual(try manager.registerCurrentAccount().id, first.id)
        live.set(reference: "ref-b", fingerprint: "fp-b")
        let second = try manager.registerCurrentAccount()
        XCTAssertThrowsError(try manager.activateAccount(first.id))
        // Adapter changed the live identity before reporting interruption; settle commits
        // the target identity and retains both account records.
        XCTAssertEqual(try manager.registerCurrentAccount().id, first.id)
        XCTAssertEqual(live.read().fingerprint, "fp-a")
        XCTAssertEqual(second.identityFingerprint, "fp-b")
        let final = try JSONDecoder().decode(AccountSessionIndex.self, from: Data(contentsOf: indexURL))
        XCTAssertNil(final.journal)
        XCTAssertEqual(Set(final.accounts.map(\.id)), Set([first.id, second.id]))
    }

    func testAccountSessionLockContentionFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let indexURL = root.appendingPathComponent("state.json")
        let lockFD = open(indexURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(lockFD, 0)
        defer { _ = flock(lockFD, LOCK_UN); close(lockFD) }
        XCTAssertEqual(flock(lockFD, LOCK_EX | LOCK_NB), 0)
        let live = LockedAccountFixture(reference: "ref", fingerprint: "fp")
        let manager = DurableAccountSessionManager(tool: .codex, indexURL: indexURL,
            identify: { live.read() }, stage: { _, _ in "spare" }, activate: { _ in })
        XCTAssertThrowsError(try manager.registerCurrentAccount()) { error in
            XCTAssertEqual(error as? AccountSessionError, .lockFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path))
    }

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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = AutoStartCommandRecorder()
        let store = UsageStore(
            providers: [AutoStartFixtureProvider(provider: .claude)],
            defaults: defaults,
            startImmediately: false,
            claudeCodeAccountManager: isolatedAccountManager(tool: .claudeCode, indexURL: root.appendingPathComponent("accounts.json")),
            autoStartRunner: recorder
        )
        XCTAssertFalse(store.autoStartUsageWindow)
        store.autoStartUsageWindow = true
        await store.refresh()
        for _ in 0..<100 {
            if !(await recorder.providers()).isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let firstStarts = await recorder.providers()
        XCTAssertEqual(firstStarts, [.claude])
        await store.refresh()
        try? await Task.sleep(for: .milliseconds(20))
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = QuotaNotificationRecorder()
        let provider = QuotaFixtureProvider(utilization: 75)
        let store = UsageStore(
            providers: [provider],
            defaults: defaults,
            startImmediately: false,
            claudeCodeAccountManager: isolatedAccountManager(tool: .claudeCode, indexURL: root.appendingPathComponent("accounts.json")),
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
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
            claudeCodeAccountManager: isolatedAccountManager(tool: .claudeCode, indexURL: root.appendingPathComponent("stale-accounts.json")),
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
        for _ in 0..<300 {
            if await recorder.delivered.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        if count > 0 {
            XCTFail("Timed out waiting for \(count) notifications")
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

    func testAntigravityCredentialsDecodeUsesTopLevelIdTokenEmail() throws {
        let payload = Data(#"{"token":{"access_token":"fake-access","token_type":"Bearer","refresh_token":"fake-refresh","expiry":"2099-10-13T12:30:00Z","expires_in":3600},"auth_method":"oauth","id_token_email":"cli@example.com"}"#.utf8)
        let credentials = try XCTUnwrap(AntigravityCredentials.decode(payload))
        XCTAssertEqual(credentials.identityLabel, "cli@example.com")
    }

    func testAntigravityCredentialsDecodePrefersJWTEmailOverTopLevelIdTokenEmail() throws {
        let jwtEmail = "jwt-email@example.com"
        let header = #"{"alg":"none"}"#
        let payloadJSON = #"{"email":"\#(jwtEmail)"}"#
        func base64URL(_ value: String) -> String {
            Data(value.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        }
        let jwt = "\(base64URL(header)).\(base64URL(payloadJSON))."
        let payload = Data(#"{"token":{"access_token":"fake-access","token_type":"Bearer","refresh_token":"fake-refresh","expiry":"2099-10-13T12:30:00Z","expires_in":3600,"id_token":"\#(jwt)"},"auth_method":"oauth","id_token_email":"cli@example.com"}"#.utf8)
        let credentials = try XCTUnwrap(AntigravityCredentials.decode(payload))
        XCTAssertEqual(credentials.identityLabel, jwtEmail)
    }

    func testAntigravityCredentialsDecodeIdentityStableAcrossAccessTokenChanges() throws {
        let firstPayload = Data(#"{"token":{"access_token":"fake-access-one","token_type":"Bearer","refresh_token":"fake-refresh","expiry":"2099-10-13T12:30:00Z","expires_in":3600},"auth_method":"oauth","id_token_email":"cli@example.com"}"#.utf8)
        let secondPayload = Data(#"{"token":{"access_token":"fake-access-two","token_type":"Bearer","refresh_token":"fake-refresh","expiry":"2099-10-13T12:30:00Z","expires_in":3600},"auth_method":"oauth","id_token_email":"cli@example.com"}"#.utf8)
        let first = try XCTUnwrap(AntigravityCredentials.decode(firstPayload))
        let second = try XCTUnwrap(AntigravityCredentials.decode(secondPayload))
        XCTAssertEqual(first.identityLabel, second.identityLabel)
        XCTAssertEqual(first.identityLabel, "cli@example.com")
    }

    /// A home with no ~/.gemini token file, so tests never read the developer's real Antigravity session.
    private static func emptyHome() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("agy-home-\(UUID().uuidString)")
    }

    func testAntigravityProviderUsesExistingCredentialAndQuotaEndpoint() async throws {
        let credential = Data(#"{"token":{"access_token":"fixture-antigravity-token","expiry":"2099-10-13T12:30:00Z"}}"#.utf8)
        let userInfoURL = "https://openidconnect.googleapis.com/v1/userinfo"
        let planURL = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
        let loader = FixtureHTTPDataLoader(
            [HTTPFixture(status: 200, body: Data(#"{"groups":[{"displayName":"Gemini models","buckets":[{"bucketId":"weekly","remainingFraction":0.2}]}]}"#.utf8))],
            routes: [
                userInfoURL: HTTPFixture(status: 200, body: Data(#"{"name":"Antigravity User","email":"agy@example.com"}"#.utf8)),
                planURL: HTTPFixture(status: 200, body: Data(#"{"paidTier":{"id":"g1-pro-tier"}}"#.utf8))
            ]
        )
        let provider = AntigravityProvider(loader: loader, homeDirectory: Self.emptyHome(), credentialReader: { credential }, managedCredentialProvider: { nil })
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.provider, .antigravity)
        XCTAssertEqual(snapshot.windows.first?.label, "Gemini Weekly")
        XCTAssertEqual(snapshot.windows.first?.validUtilization, 80)
        XCTAssertEqual(snapshot.account, "agy@example.com")
        XCTAssertEqual(snapshot.plan, "Pro")
        let requests = await loader.capturedRequests()
        XCTAssertEqual(
            requests.first?.url?.absoluteString,
            "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
        )
        // Account and plan lookups run concurrently, so only their set is stable.
        XCTAssertEqual(Set(requests.dropFirst().compactMap { $0.url?.absoluteString }), [userInfoURL, planURL])
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
        let loader = FixtureHTTPDataLoader(
            [
                HTTPFixture(status: 200, body: Data(#"{"access_token":"new-token","expires_in":3600}"#.utf8)),
                HTTPFixture(status: 200, body: Data(#"{"groups":[{"displayName":"Gemini models","buckets":[{"bucketId":"weekly","remainingFraction":0.2}]}]}"#.utf8))
            ],
            routes: [
                "https://openidconnect.googleapis.com/v1/userinfo":
                    HTTPFixture(status: 200, body: Data(#"{"name":"Antigravity User","email":"agy@example.com"}"#.utf8))
            ]
        )
        let provider = AntigravityProvider(
            loader: loader,
            homeDirectory: Self.emptyHome(),
            credentialReader: { expired },
            managedCredentialProvider: { nil },
            clientProvider: { AntigravityOAuthClient(id: "injected-id", secret: "injected-secret") }
        )
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.account, "agy@example.com")
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
        let provider = AntigravityProvider(
            loader: loader,
            homeDirectory: Self.emptyHome(),
            credentialReader: { expired },
            managedCredentialProvider: { nil },
            clientProvider: { nil }
        )
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

    func testClaudeCodeDefaultLiveServiceMatchesPrimaryReadService() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = home.appendingPathComponent(".claude", isDirectory: true)
        XCTAssertEqual(
            ClaudeCodeCredentialVault.liveService(configDirectory: config, environment: [:], homeDirectory: home),
            "Claude Code-credentials"
        )
    }

    func testClaudeManagedQuotaRefreshPersistsRotatedCredentialBeforeUsageRequest() async throws {
        let original = try JSONSerialization.data(withJSONObject: [
            "credential": ["claudeAiOauth": [
                "accessToken": "expired-access",
                "refreshToken": "old-refresh",
                "expiresAt": 0
            ]],
            "accountMetadata": ["oauthAccount": ["email": "claude@example.com"]]
        ])
        let credentialStore = FixtureManagedClaudeCredentialStore(credentials: ["account-a": original])
        let loader = FixtureHTTPDataLoader([
            HTTPFixture(status: 200, body: Data(#"{"access_token":"fresh-access","refresh_token":"rotated-refresh","expires_in":3600}"#.utf8)),
            HTTPFixture(status: 200, body: Data(#"{"five_hour":{"utilization":31}}"#.utf8))
        ])
        let fetcher = LocalManagedAccountQuotaFetcher(claudeCredentialStore: credentialStore, httpLoader: loader)
        let account = ManagedAccountRecord(
            id: "account-a", label: "A", tool: .claudeCode,
            sessionReference: ClaudeCodeCredentialVault.reference("account-a"),
            identityFingerprint: "claude-a", registeredAt: .now
        )

        let snapshot = try await fetcher.fetch(provider: .claude, account: account)

        XCTAssertEqual(snapshot.windows.first?.validUtilization, 31)
        let saved = try credentialStore.load(accountID: "account-a")
        XCTAssertEqual(try ClaudeCodeCredentialVault.accessToken(from: saved), "fresh-access")
        let savedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        let savedCredential = try XCTUnwrap(savedObject["credential"] as? [String: Any])
        let savedOAuth = try XCTUnwrap(savedCredential["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(savedOAuth["refreshToken"] as? String, "rotated-refresh")
        XCTAssertNotNil(savedObject["accountMetadata"])

        let requests = await loader.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://platform.claude.com/v1/oauth/token")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer fresh-access")
        let refreshBody = try XCTUnwrap(requests[0].httpBody)
        let refreshObject = try XCTUnwrap(JSONSerialization.jsonObject(with: refreshBody) as? [String: String])
        XCTAssertEqual(refreshObject["refresh_token"], "old-refresh")
        XCTAssertEqual(refreshObject["grant_type"], "refresh_token")
    }

    func testClaudeManagedQuotaForcesRefreshAfterEarlyUnauthorizedResponse() async throws {
        let original = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": "revoked-access",
                "refreshToken": "old-refresh",
                "expiresAt": (Date.now.addingTimeInterval(3_600).timeIntervalSince1970 * 1_000) as NSNumber
            ]
        ])
        let credentialStore = FixtureManagedClaudeCredentialStore(credentials: ["account-a": original])
        let loader = FixtureHTTPDataLoader([
            HTTPFixture(status: 401, body: Data()),
            HTTPFixture(status: 200, body: Data(#"{"access_token":"fresh-access","refresh_token":"rotated-refresh","expires_in":3600}"#.utf8)),
            HTTPFixture(status: 200, body: Data(#"{"five_hour":{"utilization":44}}"#.utf8))
        ])
        let fetcher = LocalManagedAccountQuotaFetcher(claudeCredentialStore: credentialStore, httpLoader: loader)
        let account = ManagedAccountRecord(
            id: "account-a", label: "A", tool: .claudeCode,
            sessionReference: ClaudeCodeCredentialVault.reference("account-a"),
            identityFingerprint: "claude-a", registeredAt: .now
        )

        let snapshot = try await fetcher.fetch(provider: .claude, account: account)

        XCTAssertEqual(snapshot.windows.first?.validUtilization, 44)
        let requests = await loader.capturedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer fresh-access")
        XCTAssertEqual(try ClaudeCodeCredentialVault.accessToken(from: credentialStore.load(accountID: "account-a")), "fresh-access")
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
        let accountIndexURL = cache.deletingLastPathComponent().appendingPathComponent("accounts.json")
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
            startImmediately: false,
            codexAccountManager: isolatedAccountManager(tool: .codex, indexURL: accountIndexURL),
            claudeCodeAccountManager: isolatedAccountManager(tool: .claudeCode, indexURL: accountIndexURL)
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
            startImmediately: false,
            codexAccountManager: isolatedAccountManager(tool: .codex, indexURL: accountIndexURL),
            claudeCodeAccountManager: isolatedAccountManager(tool: .claudeCode, indexURL: accountIndexURL)
        )
        await second.refresh()
        XCTAssertEqual(second.status(for: .claude), .authenticationRequired)
        XCTAssertEqual(second.snapshots[.claude]?.windows.first?.validUtilization, 32)
        XCTAssertNotNil(second.snapshots[.claude]?.error)
        XCTAssertEqual(second.status(for: .codex), .connected)
        XCTAssertNil(second.snapshots[.codex]?.error)
    }

    @MainActor
    func testSnapshotCacheIsWrittenOwnerReadableOnly() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("snapshots.json")
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let store = UsageStore(
            providers: [FixtureProvider(provider: .codex, failure: nil, delay: .zero, counter: FetchCounter())],
            defaults: isolatedDefaults(),
            cacheURL: cache,
            startImmediately: false
        )
        await store.refresh()
        let attributes = try FileManager.default.attributesOfItem(atPath: cache.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
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
        first.menuBarMode = .combinedUsage
        first.selectedProvider = .copilot
        first.warningThreshold = 75
        first.criticalThreshold = 95
        first.visibleProviders = [.claude]

        let second = UsageStore(providers: [], defaults: defaults, startImmediately: false)
        XCTAssertEqual(second.appearance, "dark")
        XCTAssertEqual(second.menuBarMode, .combinedUsage)
        XCTAssertEqual(second.selectedProvider, .copilot)
        XCTAssertEqual(second.warningThreshold, 75)
        XCTAssertEqual(second.criticalThreshold, 95)
        XCTAssertEqual(second.visibleProviders, [.claude])
    }

    @MainActor
    func testRemovedMenuBarModeFallsBackToCombinedUsage() {
        let defaults = isolatedDefaults()
        defaults.set("providerSpecific", forKey: "menuBarMode")
        let store = UsageStore(providers: [], defaults: defaults, startImmediately: false)
        XCTAssertEqual(store.menuBarMode, .combinedUsage)
    }

    func testCommandCodeProviderNormalCase() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("commandcode-provider-\(UUID().uuidString)")
        let config = home.appendingPathComponent(".commandcode", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"apiKey":"fixture-api-key","userName":"alice"}"#.utf8).write(to: config.appendingPathComponent("auth.json"))

        let loader = FixtureHTTPDataLoader([
            HTTPFixture(status: 200, body: Data(#"{"success":true,"user":{"id":"u1","name":"Alice","email":"me@example.com","userName":"alice"},"org":{"id":"org1","login":"acme"}}"#.utf8)),
            HTTPFixture(status: 200, body: Data(#"{"credits":{"belowThreshold":false,"creditThreshold":0,"monthlyCredits":5.195,"purchasedCredits":0,"freeCredits":0},"windowLimits":{"limited":true,"exceeded":null,"fiveHour":{"used":0,"cap":3,"exceeded":false,"resetAt":0},"weekly":{"used":0,"cap":6,"exceeded":false,"resetAt":0}},"sandboxAccess":false,"sandboxMinutes":null}"#.utf8)),
            HTTPFixture(status: 200, body: Data(#"{"success":true,"data":{"status":"active","planId":"individual-go-v1","currentPeriodStart":"2026-10-01T00:00:00Z","currentPeriodEnd":"2026-11-01T00:00:00Z","cancelAtPeriodEnd":false}}"#.utf8)),
            HTTPFixture(status: 200, body: Data(#"{"totalCount":5850,"totalCost":5.88}"#.utf8))
        ])
        let snapshot = try await CommandCodeProvider(loader: loader, homeDirectory: home).fetch()
        XCTAssertEqual(snapshot.provider, .commandCode)
        XCTAssertEqual(snapshot.account, "me@example.com · Go")
        XCTAssertEqual(snapshot.windows.map(\.label), ["Credits", "5-hour", "Weekly limit"])
        XCTAssertEqual(snapshot.windows[0].validUtilization ?? -1, 48.05, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[0].detail, "5,850 requests this month")
        XCTAssertEqual(snapshot.windows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        XCTAssertEqual(snapshot.windows[1].validUtilization, 0)
        XCTAssertEqual(snapshot.windows[2].validUtilization, 0)

        let requests = await loader.capturedRequests()
        XCTAssertEqual(requests.count, 4)
    }

    func testCommandCodeProviderSummaryFailureStillReturnsSnapshot() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("commandcode-provider-\(UUID().uuidString)")
        let config = home.appendingPathComponent(".commandcode", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"apiKey":"fixture-api-key"}"#.utf8).write(to: config.appendingPathComponent("auth.json"))

        let loader = FixtureHTTPDataLoader([
            HTTPFixture(status: 200, body: Data(#"{"success":true,"user":{"id":"u1","name":"Alice","email":"me@example.com","userName":"alice"},"org":{"id":"org1","login":"acme"}}"#.utf8)),
            HTTPFixture(status: 200, body: Data(#"{"credits":{"belowThreshold":false,"creditThreshold":0,"monthlyCredits":5.195,"purchasedCredits":0,"freeCredits":0},"windowLimits":{"limited":true,"exceeded":null,"fiveHour":{"used":0,"cap":3,"exceeded":false,"resetAt":0},"weekly":{"used":0,"cap":6,"exceeded":false,"resetAt":0}},"sandboxAccess":false,"sandboxMinutes":null}"#.utf8)),
            HTTPFixture(status: 200, body: Data(#"{"success":true,"data":{"status":"active","planId":"individual-go-v1","currentPeriodStart":"2026-10-01T00:00:00Z","currentPeriodEnd":"2026-11-01T00:00:00Z","cancelAtPeriodEnd":false}}"#.utf8)),
            HTTPFixture(status: 404, body: Data(#"{"error":"not found"}"#.utf8))
        ])
        let snapshot = try await CommandCodeProvider(loader: loader, homeDirectory: home).fetch()
        XCTAssertEqual(snapshot.provider, .commandCode)
        XCTAssertEqual(snapshot.windows.map(\.label), ["Credits", "5-hour", "Weekly limit"])
        XCTAssertNil(snapshot.windows.first?.detail)

        let requests = await loader.capturedRequests()
        XCTAssertEqual(requests.count, 4)
    }

    func testCommandCodeProviderAccountFallsBackToPlanWithoutUser() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("commandcode-provider-\(UUID().uuidString)")
        let config = home.appendingPathComponent(".commandcode", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"apiKey":"fixture-api-key"}"#.utf8).write(to: config.appendingPathComponent("auth.json"))

        let loader = FixtureHTTPDataLoader([
            HTTPFixture(status: 200, body: Data(#"{"success":true,"org":{"id":"org1","login":"acme"}}"#.utf8)),
            HTTPFixture(status: 200, body: Data(#"{"credits":{"belowThreshold":false,"creditThreshold":0,"monthlyCredits":5.195,"purchasedCredits":0,"freeCredits":0},"windowLimits":{"limited":true,"exceeded":null,"fiveHour":{"used":0,"cap":3,"exceeded":false,"resetAt":0},"weekly":{"used":0,"cap":6,"exceeded":false,"resetAt":0}},"sandboxAccess":false,"sandboxMinutes":null}"#.utf8)),
            HTTPFixture(status: 200, body: Data(#"{"success":true,"data":{"status":"active","planId":"individual-go-v1","currentPeriodStart":"2026-10-01T00:00:00Z","currentPeriodEnd":"2026-11-01T00:00:00Z","cancelAtPeriodEnd":false}}"#.utf8)),
            HTTPFixture(status: 200, body: Data(#"{"totalCount":5850,"totalCost":5.88}"#.utf8))
        ])
        let snapshot = try await CommandCodeProvider(loader: loader, homeDirectory: home).fetch()
        XCTAssertEqual(snapshot.provider, .commandCode)
        XCTAssertEqual(snapshot.account, "Go")

        let requests = await loader.capturedRequests()
        XCTAssertEqual(requests.count, 4)
    }

    func testCommandCodeProviderFallsBackToCreditPool() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("commandcode-provider-\(UUID().uuidString)")
        let config = home.appendingPathComponent(".commandcode", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"apiKey":"fixture-api-key"}"#.utf8).write(to: config.appendingPathComponent("auth.json"))

        let loader = FixtureHTTPDataLoader([
            HTTPFixture(status: 200, body: Data(#"{"success":true,"user":{"id":"u1","name":"Alice","email":"alice@example.com","userName":"alice"},"org":null}"#.utf8)),
            HTTPFixture(status: 200, body: Data(#"{"credits":{"belowThreshold":false,"creditThreshold":0,"monthlyCredits":5.19,"purchasedCredits":0,"freeCredits":0},"windowLimits":null,"sandboxAccess":false,"sandboxMinutes":null}"#.utf8)),
            HTTPFixture(status: 200, body: Data(#"{"success":true,"data":{"status":"active","planId":"individual-go-v1","currentPeriodStart":"2026-10-01T00:00:00Z","currentPeriodEnd":"2026-11-01T00:00:00Z","cancelAtPeriodEnd":false}}"#.utf8))
        ])
        let snapshot = try await CommandCodeProvider(loader: loader, homeDirectory: home).fetch()
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertGreaterThan(snapshot.windows.first?.validUtilization ?? -1, 0)
    }

    func testCommandCodeProviderRequiresAuthenticationWithoutAuthFile() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("commandcode-provider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let loader = FixtureHTTPDataLoader([])
        do {
            _ = try await CommandCodeProvider(loader: loader, homeDirectory: home).fetch()
            XCTFail("Expected authentication failure")
        } catch let error as ProviderFailure {
            XCTAssertEqual(error.status, .authenticationRequired)
        }
    }

    func testCommandCodeProviderMaps401ToAuthenticationRequired() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("commandcode-provider-\(UUID().uuidString)")
        let config = home.appendingPathComponent(".commandcode", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"apiKey":"fixture-api-key"}"#.utf8).write(to: config.appendingPathComponent("auth.json"))

        let loader = FixtureHTTPDataLoader([
            HTTPFixture(status: 401, body: Data(#"{"success":false}"#.utf8))
        ])
        do {
            _ = try await CommandCodeProvider(loader: loader, homeDirectory: home).fetch()
            XCTFail("Expected authentication failure")
        } catch let error as ProviderFailure {
            XCTAssertEqual(error.status, .authenticationRequired)
        }
    }

    func testProviderNavigationRegistryLabelsAndSupportedSources() {
        XCTAssertEqual(Provider.allCases.map(\.shortName), [
            "Codex", "Claude", "Cursor", "Copilot", "Gemini", "Antigravity", "Grok", "OpenCode", "Command Code"
        ])
        XCTAssertEqual(Provider.supported, [.codex, .claude, .cursor, .copilot, .gemini, .antigravity, .grok, .openCode, .commandCode])
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
            MenuBarContent.symbolName(mode: .singleProvider, selectedProvider: .codex, snapshots: snapshots, enabled: both, criticalThreshold: 90),
            "terminal.fill"
        )
        XCTAssertEqual(
            MenuBarContent.symbolName(mode: .combinedUsage, selectedProvider: .claude, snapshots: snapshots, enabled: both, criticalThreshold: 90),
            "sparkles"
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

    func testCodexMigrationImportsValidHomesAndActiveWithoutChangingFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = [root.appendingPathComponent("account-a"), root.appendingPathComponent("account-b")]
        for (index, path) in paths.enumerated() {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data("auth-marker-\(index)".utf8).write(to: path.appendingPathComponent("auth.json"))
            try Data("other-\(index)".utf8).write(to: path.appendingPathComponent("other.txt"))
        }
        let before = try paths.map { try Data(contentsOf: $0.appendingPathComponent("auth.json")) }
        let homes = [CodexHome(path: paths[0].path, lastSeenAccountID: "id-a", lastSeenEmail: "a@example.com"),
                     CodexHome(path: paths[1].path, lastSeenAccountID: "id-b", lastSeenAccount: "B")]
        let result = migrateCodexHomes(homes, activeHomePath: paths[1].path)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records.map(\.sessionReference), paths.map(\.path))
        XCTAssertEqual(result.records.map(\.label), ["a@example.com", "B"])
        XCTAssertEqual(result.activeAccountID, result.records[1].id)
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertEqual(try paths.map { try Data(contentsOf: $0.appendingPathComponent("auth.json")) }, before)
        XCTAssertTrue(paths.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testCodexMigrationSecondRunReturnsFalseWithoutDuplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let indexURL = root.appendingPathComponent("index.json")
        let manager = DurableAccountSessionManager(tool: .codex, indexURL: indexURL, identify: { ("", "", nil) }, stage: { _, _ in "" }, activate: { _ in })
        let record = ManagedAccountRecord(id: "id", label: "A", tool: .codex, sessionReference: "/tmp/home", identityFingerprint: "fp", registeredAt: .now)
        XCTAssertTrue(try manager.importAccountsOnce([record], migrationID: "codex-homes-v1"))
        let saved = try Data(contentsOf: indexURL)
        XCTAssertFalse(try manager.importAccountsOnce([record], migrationID: "codex-homes-v1"))
        XCTAssertEqual(try Data(contentsOf: indexURL), saved)
        let index = try JSONDecoder().decode(AccountSessionIndex.self, from: saved)
        XCTAssertEqual(index.accounts.count, 1)
    }

    func testCodexMigrationSkipsHomeMissingAuthFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let home = CodexHome(path: root.path, lastSeenAccountID: "id")
        let result = migrateCodexHomes([home], activeHomePath: nil)
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.skipped, [CodexMigrationSkip(path: root.path, reason: .missingAuthFile)])
    }

    func testCodexMigrationSkipsDuplicateFingerprintAsAmbiguous() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = [root.appendingPathComponent("first"), root.appendingPathComponent("second")]
        for url in urls {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data().write(to: url.appendingPathComponent("auth.json"))
        }
        let result = migrateCodexHomes(urls.map { CodexHome(path: $0.path, lastSeenAccountID: "same-id") }, activeHomePath: nil)
        XCTAssertEqual(result.records.map(\.sessionReference), [urls[0].path])
        XCTAssertEqual(result.skipped, [CodexMigrationSkip(path: urls[1].path, reason: .ambiguousIdentity)])
    }

    func testCodexMigrationDecodesOldIndexWithoutCompletedMigrations() throws {
        let index = try JSONDecoder().decode(AccountSessionIndex.self, from: Data(#"{"schema":1,"accounts":[],"inUse":[]}"#.utf8))
        XCTAssertTrue(index.completedMigrations.isEmpty)
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AIUsageTests.\(UUID().uuidString)")!
    }
}

extension ProviderAndStoreTests {
    @MainActor
    func testCodexWiringStartupMigrationRunsOnceAndPreservesLegacyDefaults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyHome = root.appendingPathComponent("legacy", isDirectory: true)
        try makeCodexHomeDir(at: legacyHome, marker: "keep")
        let defaults = isolatedDefaults()
        let legacy = CodexHome(path: legacyHome.path, lastSeenAccountID: "legacy-id", lastSeenEmail: "legacy@example.com")
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "codexHomes")
        defaults.set(legacyHome.path, forKey: "activeCodexHomePath")
        let identity = LockedAccountFixture(reference: legacyHome.path, fingerprint: "live-id")
        let manager = DurableAccountSessionManager(tool: .codex, indexURL: root.appendingPathComponent("index.json"), identify: { identity.read() }, stage: { _, id in "stage-\(id)" }, activate: { _ in })
        let store = UsageStore(providers: [], defaults: defaults, startImmediately: false, codexAccountManager: manager)
        XCTAssertEqual(store.codexAccounts.map(\.identityFingerprint), ["legacy-id"])
        XCTAssertEqual(store.codexInUseAccountID, store.codexAccounts.first?.id)
        XCTAssertNotNil(defaults.data(forKey: "codexHomes"))
        _ = UsageStore(providers: [], defaults: defaults, startImmediately: false, codexAccountManager: manager)
        XCTAssertEqual(try manager.currentIndex().accounts.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyHome.appendingPathComponent("marker.txt").path))
    }

    @MainActor
    func testCodexWiringDoesNotMoveFoldersDuringStartupImport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("legacy", isDirectory: true)
        try makeCodexHomeDir(at: home, marker: "unchanged")
        let defaults = isolatedDefaults()
        defaults.set(try JSONEncoder().encode([CodexHome(path: home.path, lastSeenAccountID: "a")]), forKey: "codexHomes")
        let identity = LockedAccountFixture(reference: home.path, fingerprint: "a")
        let manager = DurableAccountSessionManager(tool: .codex, indexURL: root.appendingPathComponent("index.json"), identify: { identity.read() }, stage: { _, id in "stage-\(id)" }, activate: { _ in })
        _ = UsageStore(providers: [], defaults: defaults, startImmediately: false, codexAccountManager: manager)
        XCTAssertEqual(codexMarker(in: home), "unchanged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".codex.swap-tmp").path))
    }
}
