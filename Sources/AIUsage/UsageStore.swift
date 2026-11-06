import Foundation
import SwiftUI
import ServiceManagement

protocol ManagedAccountQuotaFetching: Sendable {
    func fetch(provider: Provider, account: ManagedAccountRecord) async throws -> UsageSnapshot
}

struct LocalManagedAccountQuotaFetcher: ManagedAccountQuotaFetching {
    private let claudeCredentialStore: any ManagedClaudeCredentialStoring
    private let httpLoader: any HTTPDataLoading

    init(
        claudeCredentialStore: any ManagedClaudeCredentialStoring = KeychainManagedClaudeCredentialStore(),
        httpLoader: any HTTPDataLoading = URLSessionDataLoader()
    ) {
        self.claudeCredentialStore = claudeCredentialStore
        self.httpLoader = httpLoader
    }

    func fetch(provider: Provider, account: ManagedAccountRecord) async throws -> UsageSnapshot {
        switch provider {
        case .codex:
            let home = URL(fileURLWithPath: account.sessionReference, isDirectory: true)
            return try await CodexProvider(source: LocalCodexAppServerDataSource(codexHome: home)).fetch()
        case .claude:
            guard let keychainID = ClaudeCodeCredentialVault.accountID(from: account.sessionReference) else {
                throw ClaudeCodeSessionError.invalidReference
            }
            let storedCredential = try claudeCredentialStore.load(accountID: keychainID)
            var credential = storedCredential
            credential = try await ClaudeCodeCredentialVault.refreshedCredential(from: credential, using: httpLoader)
            if credential != storedCredential {
                try claudeCredentialStore.save(credential, accountID: keychainID)
            }
            let token = try ClaudeCodeCredentialVault.accessToken(from: credential)
            do {
                return try await ClaudeProvider(loader: httpLoader, fetchProfile: false, tokenProvider: { token }).fetch()
            } catch let failure as ProviderFailure {
                guard case .http(401) = failure else { throw failure }
                let refreshed = try await ClaudeCodeCredentialVault.refreshedCredential(
                    from: credential, using: httpLoader, force: true
                )
                guard refreshed != credential else { throw failure }
                try claudeCredentialStore.save(refreshed, accountID: keychainID)
                let refreshedToken = try ClaudeCodeCredentialVault.accessToken(from: refreshed)
                return try await ClaudeProvider(
                    loader: httpLoader, fetchProfile: false, tokenProvider: { refreshedToken }
                ).fetch()
            }
        default:
            throw ProviderFailure.process("Account-specific quota is not supported for this provider.")
        }
    }
}

@MainActor @Observable final class UsageStore {
    var snapshots: [Provider: UsageSnapshot] = [:]
    var refreshing: Set<Provider> = []
    var publicServiceIncidents: [Provider: [ServiceIncident]] = [:]
    var visibleProviders: Set<Provider> = Set(Provider.supported) {
        didSet {
            defaults.set(visibleProviders.map(\.rawValue), forKey: "visibleProviders")
            publishWidgetSnapshot()
            if publicServiceStatusMonitoringEnabled {
                Task { await refreshPublicServiceStatus(force: true) }
            }
        }
    }
    var providerOrder: [Provider] = Provider.supported {
        didSet {
            defaults.set(providerOrder.map(\.rawValue), forKey: "providerOrder")
            publishWidgetSnapshot()
        }
    }
    var selectedProvider: Provider? {
        didSet {
            if let selectedProvider { defaults.set(selectedProvider.rawValue, forKey: "selectedProvider") }
            else { defaults.removeObject(forKey: "selectedProvider") }
        }
    }
    var warningThreshold = 70.0 { didSet { defaults.set(warningThreshold, forKey: "warningThreshold") } }
    var criticalThreshold = 90.0 { didSet { defaults.set(criticalThreshold, forKey: "criticalThreshold") } }
    var refreshPolicy: RefreshPolicy = .fiveMinutes {
        didSet {
            defaults.set(refreshPolicy.rawValue, forKey: "refreshPolicy")
            defaults.set(refreshPolicy.interval.map { Int($0.components.seconds) } ?? 0, forKey: "refreshInterval")
            schedule()
        }
    }
    var menuBarMode: MenuBarDisplayMode = .combinedUsage {
        didSet { defaults.set(menuBarMode.rawValue, forKey: "menuBarMode") }
    }
    var menuBarProvider: Provider = .claude {
        didSet { defaults.set(menuBarProvider.rawValue, forKey: "menuBarProvider") }
    }
    var appearance = "system" { didSet { defaults.set(appearance, forKey: "appearance") } }
    var language = AppLanguage.system.rawValue { didSet { defaults.set(language, forKey: "appLanguage") } }
    var autoStartUsageWindow = false { didSet { defaults.set(autoStartUsageWindow, forKey: "autoStartUsageWindow") } }
    var quotaNotificationsEnabled = false { didSet { defaults.set(quotaNotificationsEnabled, forKey: "quotaNotificationsEnabled") } }
    var launchAtLoginEnabled = false
    var launchAtLoginError: String?
    private(set) var lastRefreshAttempt: Date?
    private(set) var codexAccounts: [ManagedAccountRecord] = []
    private(set) var codexInUseAccountID: String?
    private(set) var claudeCodeAccounts: [ManagedAccountRecord] = []
    private(set) var claudeCodeInUseAccountID: String?
    var managedAccountSnapshots: [Provider: [String: UsageSnapshot]] = [:]
    var managedAccountErrors: [Provider: [String: String]] = [:]
    var managedAccountStatuses: [Provider: [String: ProviderStatus]] = [:]
    var refreshingManagedAccounts: Set<String> = []
    private(set) var accountSessionActionInFlight = false
    @ObservationIgnored private var pendingManagedAccountActivations: [String: Provider] = [:]
    var codexAccountError: String?
    var codexAccountActionInFlight = false
    private(set) var antigravityAccounts: [AntigravityAccount] = []
    var activeAntigravityAccountID: String?
    var antigravityAccountError: String?
    var antigravityAccountSwitchInFlight = false
    private(set) var claudeDesktopAccounts: [ManagedAccountRecord] = []
    private(set) var claudeDesktopInUseAccountID: String?
    var claudeDesktopAccountError: String?
    var claudeDesktopAccountActionInFlight = false
    var claudeDesktopAppRunning = false

    @ObservationIgnored private let codexAccountManager: DurableAccountSessionManager
    @ObservationIgnored private let claudeCodeAccountManager: DurableAccountSessionManager
    @ObservationIgnored private let antigravityAccountManager: DurableAccountSessionManager
    @ObservationIgnored private let claudeDesktopAccountManager: DurableAccountSessionManager
    @ObservationIgnored private let providers: [any UsageProvider]
    @ObservationIgnored private let accountQuotaFetcher: any ManagedAccountQuotaFetching
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var publicServiceStatusTask: Task<Void, Never>?
    @ObservationIgnored private var lastPublicServiceStatusRefresh: Date?
    @ObservationIgnored private var publicServiceStatusRefreshInFlight = false
    @ObservationIgnored private var publicServiceStatusMonitoringEnabled = false
    @ObservationIgnored private let autoStartRunner: any UsageWindowStartCommandRunning
    @ObservationIgnored private let quotaDeliverer: any QuotaNotificationDelivering

    var refreshInterval: Int { refreshPolicy.interval.map { Int($0.components.seconds) } ?? 0 }
    var isRefreshing: Bool { !refreshing.isEmpty }
    var colorSchemeOverride: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
    var locale: Locale { AppLanguage.preference(language).locale }

    var needsInitialRefreshOnOpen: Bool {
        guard refreshPolicy != .manual else { return false }
        if snapshots.isEmpty { return true }
        let minimumGap = refreshPolicy.interval.map { TimeInterval($0.components.seconds) } ?? 60
        if let lastRefreshAttempt, Date.now.timeIntervalSince(lastRefreshAttempt) < min(minimumGap, 60) { return false }
        return snapshots.values.contains { snapshot in
            visibleProviders.contains(snapshot.provider)
                && (snapshot.isStale || Date.now.timeIntervalSince(snapshot.lastSuccess) >= minimumGap)
        }
    }

    init(
        providers: [any UsageProvider] = [ClaudeProvider(), CodexProvider(), CursorProvider(), CopilotProvider(), GeminiProvider(), AntigravityProvider(), GrokProvider(), OpenCodeProvider()],
        defaults: UserDefaults = .standard,
        cacheURL: URL? = nil,
        startImmediately: Bool = true,
        codexAccountManager: DurableAccountSessionManager? = nil,
        codexLiveHomeURL: URL? = nil,
        codexSpareRootURL: URL? = nil,
        codexIndexURL: URL? = nil,
        claudeCodeAccountManager: DurableAccountSessionManager? = nil,
        antigravityAccountManager: DurableAccountSessionManager? = nil,
        accountQuotaFetcher: any ManagedAccountQuotaFetching = LocalManagedAccountQuotaFetcher(),
        autoStartRunner: any UsageWindowStartCommandRunning = LocalUsageWindowStartCommandRunner(),
        quotaDeliverer: any QuotaNotificationDelivering = UserNotificationQuotaDeliverer()
    ) {
        self.providers = providers
        self.accountQuotaFetcher = accountQuotaFetcher
        self.defaults = defaults
        self.cacheURL = cacheURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIUsage/snapshots.json")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let live = codexLiveHomeURL ?? Self.defaultCodexHomeURL()
        let spare = codexSpareRootURL ?? home.appendingPathComponent(".ai-usage/accounts/codex-sessions", isDirectory: true)
        let indexURL = codexIndexURL ?? home.appendingPathComponent("Library/Application Support/AIUsage/account-sessions.json")
        self.codexAccountManager = codexAccountManager ?? CodexSessionAdapter(liveHomeURL: live, spareRootURL: spare, indexURL: indexURL).manager
        let claudeConfig = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? home.appendingPathComponent(".claude", isDirectory: true)
        self.claudeCodeAccountManager = claudeCodeAccountManager
            ?? ClaudeCodeSessionAdapter(configDirectory: claudeConfig, indexURL: indexURL).manager
        self.antigravityAccountManager = antigravityAccountManager ?? AntigravityAccountVault.managedSessionAdapter(indexURL: indexURL, defaults: defaults)
        self.claudeDesktopAccountManager = ClaudeDesktopSessionAdapter(
            liveDataURL: home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true),
            parkedRootURL: home.appendingPathComponent(".ai-usage/accounts/claude-desktop-sessions", isDirectory: true),
            indexURL: indexURL
        ).manager
        self.autoStartRunner = autoStartRunner
        self.quotaDeliverer = quotaDeliverer
        migrateLegacyAntigravityAccounts()
        refreshAntigravityAccountIndex()
        claudeDesktopAppRunning = ClaudeDesktopSessionAdapter.isClaudeRunning()
        refreshClaudeDesktopAccountIndex()
        if let raw = defaults.stringArray(forKey: "visibleProviders") {
            visibleProviders = Set(raw.compactMap(Provider.init(rawValue:)))
        }
        providerOrder = Self.normalizedProviderOrder(defaults.stringArray(forKey: "providerOrder"))
        if let raw = defaults.string(forKey: "selectedProvider") {
            selectedProvider = Provider(rawValue: raw)
        }
        if defaults.object(forKey: "warningThreshold") != nil { warningThreshold = defaults.double(forKey: "warningThreshold") }
        if defaults.object(forKey: "criticalThreshold") != nil { criticalThreshold = defaults.double(forKey: "criticalThreshold") }
        if let raw = defaults.string(forKey: "refreshPolicy"), let policy = RefreshPolicy(rawValue: raw) {
            refreshPolicy = policy
        } else if defaults.object(forKey: "refreshInterval") != nil {
            refreshPolicy = RefreshPolicy(legacyInterval: defaults.integer(forKey: "refreshInterval"))
        }
        if let raw = defaults.string(forKey: "menuBarMode"), let mode = MenuBarDisplayMode(rawValue: raw) {
            menuBarMode = mode
        } else {
            menuBarMode = MenuBarDisplayMode(legacyValue: defaults.string(forKey: "menuBarStyle") ?? "Highest usage")
        }
        if let raw = defaults.string(forKey: "menuBarProvider"), let provider = Provider(rawValue: raw) {
            menuBarProvider = provider
        }
        appearance = (defaults.string(forKey: "appearance") ?? "system").lowercased()
        language = AppLanguage.preference(defaults.string(forKey: "appLanguage")).rawValue
        autoStartUsageWindow = defaults.bool(forKey: "autoStartUsageWindow")
        quotaNotificationsEnabled = defaults.bool(forKey: "quotaNotificationsEnabled")
        if let data = try? Data(contentsOf: self.cacheURL), let cached = try? JSONDecoder().decode([UsageSnapshot].self, from: data) {
            snapshots = Dictionary(uniqueKeysWithValues: cached.map { ($0.provider, $0) })
            lastRefreshAttempt = cached.map(\.lastSuccess).filter { $0 != .distantPast }.max()
        }
        migrateLegacyCodexAccounts()
        refreshCodexAccountIndex()
        refreshClaudeCodeAccountIndex()
        publishWidgetSnapshot()
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        schedule()
        if startImmediately {
            publicServiceStatusMonitoringEnabled = true
            Task { await self.refresh() }
            publicServiceStatusTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshPublicServiceStatus(force: true)
                    try? await Task.sleep(for: .seconds(300))
                }
            }
        }
    }

    static func normalizedProviderOrder(_ saved: [String]?, supported: [Provider] = Provider.supported) -> [Provider] {
        guard let saved else { return supported }
        var ordered = saved.compactMap { Provider(rawValue: $0) }
            .filter { supported.contains($0) }
        var seen = Set<Provider>()
        ordered = ordered.filter { seen.insert($0).inserted }
        ordered.append(contentsOf: supported.filter { seen.insert($0).inserted })
        return ordered
    }

    func moveProvider(_ provider: Provider, before target: Provider) {
        guard provider != target,
              let sourceIndex = providerOrder.firstIndex(of: provider),
              let targetIndex = providerOrder.firstIndex(of: target) else { return }
        var order = providerOrder
        order.remove(at: sourceIndex)
        let adjustedTarget = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
        order.insert(provider, at: adjustedTarget)
        providerOrder = order
    }

    func refresh(provider requestedProvider: Provider? = nil) async {
        if accountSessionActionInFlight { return }
        let selectedProviders = providers.filter {
            visibleProviders.contains($0.provider)
                && (requestedProvider == nil || $0.provider == requestedProvider)
                && !refreshing.contains($0.provider)
        }
        guard !selectedProviders.isEmpty else { return }
        lastRefreshAttempt = .now
        refreshing.formUnion(selectedProviders.map(\.provider))
        await withTaskGroup(of: (Provider, Result<UsageSnapshot, ProviderFailure>).self) { group in
            for provider in selectedProviders {
                let accountManager = provider.provider == .codex ? codexAccountManager
                    : provider.provider == .claude ? claudeCodeAccountManager : nil
                group.addTask {
                    do {
                        let operationLease = try accountManager?.acquireOperationLock()
                        defer { if let operationLease { withExtendedLifetime(operationLease) {} } }
                        return (provider.provider, .success(try await provider.fetch()))
                    }
                    catch let failure as ProviderFailure { return (provider.provider, .failure(failure)) }
                    catch { return (provider.provider, .failure(.network("Could not refresh usage. Try again."))) }
                }
            }
            for await (provider, result) in group {
                refreshing.remove(provider)
                switch result {
                case .success(var snapshot):
                    snapshot.error = nil
                    snapshot.status = .connected
                    snapshots[provider] = snapshot
                    maybeStartUsageWindow(for: snapshot)
                    maybeNotifyQuota(for: snapshot)
                    if provider == .codex {
                        refreshCodexAccountIndex()
                    }
                case .failure(let failure):
                    if var snapshot = snapshots[provider] {
                        snapshot.error = failure.localizedDescription
                        snapshot.status = failure.status
                        snapshots[provider] = snapshot
                    } else {
                        snapshots[provider] = UsageSnapshot(
                            provider: provider,
                            windows: [],
                            account: nil,
                            lastSuccess: .distantPast,
                            error: failure.localizedDescription,
                            status: failure.status
                        )
                    }
                }
            }
        }
        save()
    }

    func addCurrentAntigravityAccount() async {
        guard !antigravityAccountSwitchInFlight, !refreshing.contains(.antigravity) else { return }
        antigravityAccountSwitchInFlight = true
        defer { antigravityAccountSwitchInFlight = false }
        do {
            _ = try antigravityAccountManager.stashActiveSession()
            antigravityAccountError = nil
            refreshAntigravityAccountIndex()
            await refresh(provider: .antigravity)
        } catch { antigravityAccountError = error.localizedDescription }
    }

    func switchAntigravityAccount(to id: String?) async {
        guard !antigravityAccountSwitchInFlight else { return }
        guard !refreshing.contains(.antigravity) else {
            antigravityAccountError = String(localized: "Wait for the Antigravity refresh to finish, then switch accounts.")
            return
        }
        if let id, !antigravityAccounts.contains(where: { $0.id == id }) { return }
        antigravityAccountSwitchInFlight = true
        defer { antigravityAccountSwitchInFlight = false }
        do {
            if let id { try antigravityAccountManager.activateAccount(id) }
            else {
                try antigravityAccountManager.markExternalSessionInUse()
                AntigravityAccountVault.select(nil, defaults: defaults)
            }
            antigravityAccountError = nil
            refreshAntigravityAccountIndex()
            await refresh(provider: .antigravity)
        } catch { antigravityAccountError = error.localizedDescription }
    }

    func removeAntigravityAccount(_ id: String) {
        guard !antigravityAccountSwitchInFlight, !refreshing.contains(.antigravity) else {
            antigravityAccountError = String(localized: "Wait for the Antigravity refresh to finish, then switch accounts.")
            return
        }
        do {
            guard let record = try antigravityAccountManager.currentIndex().accounts.first(where: { $0.id == id && $0.tool == .antigravity }) else { return }
            if activeAntigravityAccountID == id {
                try antigravityAccountManager.markExternalSessionInUse()
                AntigravityAccountVault.select(nil, defaults: defaults)
            }
            try antigravityAccountManager.removeAccount(id)
            try AntigravityAccountVault.deleteCredentialData(id: record.sessionReference)
            antigravityAccountError = nil
            refreshAntigravityAccountIndex()
        } catch {
            antigravityAccountError = error.localizedDescription
        }
    }

    private func migrateLegacyAntigravityAccounts() {
        do {
            let (records, activeID) = try AntigravityAccountVault.migrationRecords(defaults: defaults)
            try antigravityAccountManager.importAccountsOnce(records, migrationID: "antigravity-legacy-vault-v1", activeAccountID: activeID)
            refreshAntigravityAccountIndex()
        } catch { antigravityAccountError = error.localizedDescription }
    }

    private func refreshAntigravityAccountIndex() {
        do {
            let index = try antigravityAccountManager.currentIndex()
            antigravityAccounts = index.accounts.filter { $0.tool == .antigravity }.map {
                AntigravityAccount(id: $0.id, identity: $0.label, addedAt: $0.registeredAt)
            }
            activeAntigravityAccountID = index.inUse[.antigravity]
        } catch { antigravityAccountError = error.localizedDescription }
    }

    func stashClaudeDesktopSession(label: String) {
        guard !claudeDesktopAccountActionInFlight else { return }
        claudeDesktopAccountActionInFlight = true
        defer { claudeDesktopAccountActionInFlight = false; claudeDesktopAppRunning = ClaudeDesktopSessionAdapter.isClaudeRunning() }
        do {
            _ = try claudeDesktopAccountManager.stashActiveSession(label: label)
            claudeDesktopAccountError = nil
        } catch { claudeDesktopAccountError = error.localizedDescription }
        refreshClaudeDesktopAccountIndex()
    }

    func activateClaudeDesktopAccount(_ id: String) {
        guard !claudeDesktopAccountActionInFlight else { return }
        claudeDesktopAccountActionInFlight = true
        defer { claudeDesktopAccountActionInFlight = false; claudeDesktopAppRunning = ClaudeDesktopSessionAdapter.isClaudeRunning() }
        do {
            try claudeDesktopAccountManager.activateAccount(id)
            claudeDesktopAccountError = nil
        } catch { claudeDesktopAccountError = error.localizedDescription }
        refreshClaudeDesktopAccountIndex()
    }

    func quitClaudeDesktop() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            _ = app.terminate()
        }
        Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(250))
                claudeDesktopAppRunning = ClaudeDesktopSessionAdapter.isClaudeRunning()
                if !claudeDesktopAppRunning { return }
            }
            claudeDesktopAccountError = "Claude Desktop is still open. Quit Claude before switching accounts."
        }
    }

    func refreshClaudeDesktopAppState() {
        claudeDesktopAppRunning = ClaudeDesktopSessionAdapter.isClaudeRunning()
    }

    func openClaudeDesktop() {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") else {
            claudeDesktopAccountError = String(localized: "Claude Desktop could not be found in Applications.")
            return
        }
        guard NSWorkspace.shared.open(appURL) else {
            claudeDesktopAccountError = String(localized: "Claude Desktop could not be opened.")
            return
        }
        claudeDesktopAccountError = nil
    }

    private func refreshClaudeDesktopAccountIndex() {
        do {
            let index = try claudeDesktopAccountManager.currentIndex()
            claudeDesktopAccounts = index.accounts.filter { $0.tool == .claudeDesktop }
            claudeDesktopInUseAccountID = index.inUse[.claudeDesktop]
        } catch { claudeDesktopAccountError = error.localizedDescription }
    }

    private func maybeStartUsageWindow(for snapshot: UsageSnapshot) {
        guard autoStartUsageWindow, visibleProviders.contains(snapshot.provider) else { return }
        let key = "autoStartUsageWindow.lastPing.\(snapshot.provider.rawValue)"
        let lastStartedAt = defaults.object(forKey: key) as? Date
        let now = Date.now
        guard UsageWindowAutoStartPolicy.shouldStart(snapshot: snapshot, now: now, lastStartedAt: lastStartedAt) else { return }
        // Persist before dispatch so overlapping refreshes cannot send duplicate prompts.
        defaults.set(now, forKey: key)
        let runner = autoStartRunner
        let provider = snapshot.provider
        Task { await runner.run(provider: provider) }
    }

    private func maybeNotifyQuota(for snapshot: UsageSnapshot) {
        guard quotaNotificationsEnabled,
              visibleProviders.contains(snapshot.provider),
              !snapshot.isStale else { return }
        for window in snapshot.validWindows {
            guard let utilization = window.validUtilization else { continue }
            let base = "quotaNotification.\(snapshot.provider.rawValue).\(window.label)"
            var episode = QuotaNotificationPolicy.Episode(
                warned: defaults.bool(forKey: base + ".warned"),
                critical: defaults.bool(forKey: base + ".critical")
            )
            let (event, updated) = QuotaNotificationPolicy.evaluate(
                utilization: utilization,
                warningThreshold: warningThreshold,
                criticalThreshold: criticalThreshold,
                episode: episode
            )
            episode = updated
            guard let event else {
                // Persist cleared state so a recovered episode re-arms.
                defaults.set(episode.warned, forKey: base + ".warned")
                defaults.set(episode.critical, forKey: base + ".critical")
                continue
            }
            let threshold = event == .critical ? criticalThreshold : warningThreshold
            // Persist before dispatch so overlapping refreshes cannot double-notify.
            defaults.set(episode.warned, forKey: base + ".warned")
            defaults.set(episode.critical, forKey: base + ".critical")
            let notification = QuotaNotification(
                provider: snapshot.provider,
                windowLabel: window.label,
                kind: event,
                utilization: utilization,
                threshold: threshold
            )
            let deliverer = quotaDeliverer
            Task { await deliverer.deliver(notification) }
        }
    }

    func schedule() {
        timer?.cancel()
        guard let interval = refreshPolicy.interval else { timer = nil; return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLoginEnabled = enabled
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            launchAtLoginError = "Could not update Launch at Login. Check System Settings → General → Login Items."
        }
    }

    func status(for provider: Provider) -> ProviderStatus {
        if refreshing.contains(provider) { return snapshots[provider]?.status ?? .connected }
        guard let snapshot = snapshots[provider] else { return .unavailable }
        return snapshot.status ?? (snapshot.error == nil ? .connected : .error)
    }

    func refreshPublicServiceStatus(force: Bool = false) async {
        guard !publicServiceStatusRefreshInFlight else { return }
        if !force, let lastPublicServiceStatusRefresh,
           Date.now.timeIntervalSince(lastPublicServiceStatusRefresh) < 300 { return }
        guard !visibleProviders.isEmpty else { return }
        publicServiceStatusRefreshInFlight = true
        defer { publicServiceStatusRefreshInFlight = false }
        lastPublicServiceStatusRefresh = .now
        let refreshed = await PublicServiceStatus.fetch(for: visibleProviders)
        for (provider, incidents) in refreshed {
            publicServiceIncidents[provider] = incidents
        }
        for provider in Array(publicServiceIncidents.keys) where !visibleProviders.contains(provider) {
            publicServiceIncidents[provider] = nil
        }
    }

    // MARK: - Managed Codex accounts

    private nonisolated static func defaultCodexHomeURL() -> URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    private func migrateLegacyCodexAccounts() {
        let homes: [CodexHome]
        if let data = defaults.data(forKey: "codexHomes"), let decoded = try? JSONDecoder().decode([CodexHome].self, from: data) { homes = decoded } else { homes = [] }
        let migration = migrateCodexHomes(homes, activeHomePath: defaults.string(forKey: "activeCodexHomePath"))
        do {
            try codexAccountManager.importAccountsOnce(migration.records, migrationID: "codex-legacy-homes-v1", activeAccountID: migration.activeAccountID)
            refreshCodexAccountIndex()
        } catch { codexAccountError = error.localizedDescription }
    }

    private func refreshCodexAccountIndex() {
        do {
            let index = try codexAccountManager.currentIndex()
            codexAccounts = index.accounts.filter { $0.tool == .codex }
            codexInUseAccountID = index.inUse[.codex]
        } catch { codexAccountError = error.localizedDescription }
    }

    func registerCurrentCodexLogin() { performCodexAccountAction { _ = try self.codexAccountManager.registerCurrentAccount(label: nil) } }
    func stashCodexActiveSession() { performCodexAccountAction { _ = try self.codexAccountManager.stashActiveSession() } }
    func activateCodexAccount(_ id: String) { performCodexAccountAction { try self.codexAccountManager.activateAccount(id) } }

    func saveCurrentAccount(for provider: Provider) throws {
        guard !accountSessionActionInFlight, refreshing.isDisjoint(with: [.claude, .codex]), refreshingManagedAccounts.isEmpty else {
            throw AccountSessionError.lockFailed
        }
        accountSessionActionInFlight = true
        defer { accountSessionActionInFlight = false }
        switch provider {
        case .codex:
            _ = try codexAccountManager.stashActiveSession()
            refreshCodexAccountIndex()
        case .claude:
            _ = try claudeCodeAccountManager.stashActiveSession()
            refreshClaudeCodeAccountIndex()
        default:
            throw AccountSessionError.unidentified
        }
    }

    @discardableResult
    func importAccount(for provider: Provider, reference: String, fingerprint: String, label: String?) throws -> ManagedAccountRecord {
        guard !accountSessionActionInFlight, !refreshing.contains(provider), refreshingManagedAccounts.isEmpty else {
            throw AccountSessionError.lockFailed
        }
        accountSessionActionInFlight = true
        defer { accountSessionActionInFlight = false }
        switch provider {
        case .codex:
            let account = try codexAccountManager.importSession(reference: reference, fingerprint: fingerprint, label: label)
            refreshCodexAccountIndex()
            return account
        case .claude:
            let account = try claudeCodeAccountManager.importSession(reference: reference, fingerprint: fingerprint, label: label)
            refreshClaudeCodeAccountIndex()
            return account
        default:
            throw AccountSessionError.unidentified
        }
    }

    func activateManagedAccount(for provider: Provider, id: String) async {
        guard !accountSessionActionInFlight, refreshing.isDisjoint(with: [.claude, .codex]) else { return }
        if refreshingManagedAccounts.contains(id) {
            pendingManagedAccountActivations[id] = provider
            return
        }
        accountSessionActionInFlight = true
        defer { accountSessionActionInFlight = false }
        do {
            switch provider {
            case .codex:
                let accountLease = try codexAccountManager.acquireAccountLock(id)
                defer { withExtendedLifetime(accountLease) {} }
                try codexAccountManager.activateAccount(id)
                refreshCodexAccountIndex()
            case .claude:
                let accountLease = try claudeCodeAccountManager.acquireAccountLock(id)
                defer { withExtendedLifetime(accountLease) {} }
                try claudeCodeAccountManager.activateAccount(id)
                refreshClaudeCodeAccountIndex()
            default: return
            }
            accountSessionActionInFlight = false
            await refresh(provider: provider)
        } catch {
            managedAccountErrors[provider, default: [:]][id] = error.localizedDescription
        }
    }

    func refreshManagedAccountQuota(for provider: Provider, accountID: String) async {
        guard !accountSessionActionInFlight, refreshing.isDisjoint(with: [.claude, .codex]), !refreshingManagedAccounts.contains(accountID) else { return }
        let records = provider == .codex ? codexAccounts : claudeCodeAccounts
        guard let account = records.first(where: { $0.id == accountID }) else { return }
        refreshingManagedAccounts.insert(accountID)
        defer {
            refreshingManagedAccounts.remove(accountID)
            if let pendingProvider = pendingManagedAccountActivations.removeValue(forKey: accountID) {
                Task { await self.activateManagedAccount(for: pendingProvider, id: accountID) }
            }
        }
        do {
            let manager = provider == .codex ? codexAccountManager : claudeCodeAccountManager
            let accountLease = try manager.acquireAccountLock(accountID)
            defer { withExtendedLifetime(accountLease) {} }
            let fetched = try await accountQuotaFetcher.fetch(provider: provider, account: account)
            var scoped = fetched
            scoped.accountID = accountID
            managedAccountSnapshots[provider, default: [:]][accountID] = scoped
            managedAccountErrors[provider, default: [:]][accountID] = nil
            managedAccountStatuses[provider, default: [:]][accountID] = scoped.status
        } catch let failure as ProviderFailure {
            managedAccountErrors[provider, default: [:]][accountID] = failure.localizedDescription
            managedAccountStatuses[provider, default: [:]][accountID] = failure.status
        } catch {
            managedAccountErrors[provider, default: [:]][accountID] = error.localizedDescription
            managedAccountStatuses[provider, default: [:]][accountID] = .error
        }
    }

    func refreshManagedAccountQuotas() async {
        let work = [(Provider.codex, codexAccounts), (.claude, claudeCodeAccounts)]
        for (provider, accounts) in work {
            for account in accounts { await refreshManagedAccountQuota(for: provider, accountID: account.id) }
        }
    }

    private func refreshClaudeCodeAccountIndex() {
        do {
            let index = try claudeCodeAccountManager.currentIndex()
            claudeCodeAccounts = index.accounts.filter { $0.tool == .claudeCode }
            claudeCodeInUseAccountID = index.inUse[.claudeCode]
        } catch {
            managedAccountErrors[.claude, default: [:]]["index"] = error.localizedDescription
        }
    }

    private func performCodexAccountAction(_ action: () throws -> Void) {
        guard !codexAccountActionInFlight, !refreshing.contains(.codex) else { return }
        codexAccountActionInFlight = true
        defer { codexAccountActionInFlight = false }
        do { try action(); codexAccountError = nil; refreshCodexAccountIndex(); Task { await self.refresh(provider: .codex) } }
        catch { codexAccountError = error.localizedDescription; refreshCodexAccountIndex() }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(snapshots.values)) {
            try? data.write(to: cacheURL, options: .atomic)
            // Snapshots carry account identifiers; keep them readable only by the current user.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        }
        publishWidgetSnapshot()
    }

    private func publishWidgetSnapshot() {
        WidgetSnapshotSharing.write(snapshots: snapshots, order: Provider.supported, visible: visibleProviders)
    }
}
