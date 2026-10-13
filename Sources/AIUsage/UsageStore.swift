import Foundation
import SwiftUI
import ServiceManagement

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
    var codexHomes: [CodexHome] = [] {
        didSet { saveCodexHomes() }
    }
    var activeCodexHomePath: String? {
        didSet {
            if let activeCodexHomePath { defaults.set(activeCodexHomePath, forKey: "activeCodexHomePath") }
            else { defaults.removeObject(forKey: "activeCodexHomePath") }
        }
    }
    private(set) var antigravityAccounts: [AntigravityAccount] = []
    var activeAntigravityAccountID: String? {
        didSet { AntigravityAccountVault.select(activeAntigravityAccountID, defaults: defaults) }
    }
    var antigravityAccountError: String?
    var antigravityAccountSwitchInFlight = false
    var codexSwitchInFlight = false
    var codexSwitchError: String?
    @ObservationIgnored private var codexAccountSnapshots: [String: UsageSnapshot] = [:]

    @ObservationIgnored private let providers: [any UsageProvider]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var publicServiceStatusTask: Task<Void, Never>?
    @ObservationIgnored private var lastPublicServiceStatusRefresh: Date?
    @ObservationIgnored private var publicServiceStatusRefreshInFlight = false
    @ObservationIgnored private var publicServiceStatusMonitoringEnabled = false
    @ObservationIgnored private let codexAuthFileURL: URL
    @ObservationIgnored private let managedCodexAccountsRootURL: URL
    @ObservationIgnored private let fileModificationDate: @Sendable (String) -> Date?
    @ObservationIgnored private let autoStartRunner: any UsageWindowStartCommandRunning
    @ObservationIgnored private let quotaDeliverer: any QuotaNotificationDelivering
    @ObservationIgnored private var codexAuthWatcher: Task<Void, Never>?
    @ObservationIgnored private var lastSeenCodexAuthMtime: Date?

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
        codexAuthFileURL: URL? = nil,
        managedCodexAccountsRootURL: URL? = nil,
        fileModificationDate: (@Sendable (String) -> Date?)? = nil,
        autoStartRunner: any UsageWindowStartCommandRunning = LocalUsageWindowStartCommandRunner(),
        quotaDeliverer: any QuotaNotificationDelivering = UserNotificationQuotaDeliverer()
    ) {
        self.providers = providers
        self.defaults = defaults
        self.cacheURL = cacheURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIUsage/snapshots.json")
        self.codexAuthFileURL = codexAuthFileURL ?? Self.defaultCodexAuthFileURL()
        self.managedCodexAccountsRootURL = managedCodexAccountsRootURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ai-usage/accounts/codex", isDirectory: true)
        self.fileModificationDate = fileModificationDate ?? Self.defaultModificationDate
        self.autoStartRunner = autoStartRunner
        self.quotaDeliverer = quotaDeliverer
        antigravityAccounts = AntigravityAccountVault.accounts(defaults: defaults)
        activeAntigravityAccountID = AntigravityAccountVault.activeAccountID(defaults: defaults)
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
        if let data = defaults.data(forKey: "codexHomes"),
           let homes = try? JSONDecoder().decode([CodexHome].self, from: data) {
            codexHomes = homes
        }
        activeCodexHomePath = defaults.string(forKey: "activeCodexHomePath")
        if let data = defaults.data(forKey: "codexAccountSnapshots"),
           let cached = try? JSONDecoder().decode([String: UsageSnapshot].self, from: data) {
            codexAccountSnapshots = cached.filter { $0.value.provider == .codex }
        }
        if let data = try? Data(contentsOf: self.cacheURL), let cached = try? JSONDecoder().decode([UsageSnapshot].self, from: data) {
            snapshots = Dictionary(uniqueKeysWithValues: cached.map { ($0.provider, $0) })
            if let activeCodexHomePath, let codexSnapshot = snapshots[.codex] {
                let expectedID = codexHomes.first(where: { $0.path == activeCodexHomePath })?.lastSeenAccountID
                if expectedID == nil || expectedID == codexSnapshot.accountID {
                    codexAccountSnapshots[activeCodexHomePath] = codexSnapshot
                } else {
                    // Old provider-only cache may belong to a different account.
                    snapshots[.codex] = nil
                }
            }
            lastRefreshAttempt = cached.map(\.lastSuccess).filter { $0 != .distantPast }.max()
        }
        if let activeCodexHomePath,
           let savedSnapshot = codexAccountSnapshots[activeCodexHomePath],
           savedSnapshot.provider == .codex {
            let expectedID = codexHomes.first(where: { $0.path == activeCodexHomePath })?.lastSeenAccountID
            if (expectedID == nil || savedSnapshot.accountID == expectedID), snapshots[.codex] == nil {
                snapshots[.codex] = savedSnapshot
            }
        }
        publishWidgetSnapshot()
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        schedule()
        startCodexAuthWatcher()
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
                group.addTask {
                    do { return (provider.provider, .success(try await provider.fetch())) }
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
                        noteSuccessfulCodexFetch(snapshot)
                        cacheCodexSnapshot(snapshot)
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
                    if provider == .codex, let snapshot = snapshots[.codex] {
                        cacheCodexSnapshot(snapshot)
                    }
                }
            }
        }
        save()
    }

    func addCurrentAntigravityAccount() async {
        guard !antigravityAccountSwitchInFlight, !refreshing.contains(.antigravity) else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cliData = try? Data(contentsOf: home.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token"))
        guard let data = AntigravityCredentials.preferredData(
            keychainData: AntigravityCredentials.keychainData(),
            cliData: cliData
        ), let credentials = AntigravityCredentials.decode(data) else {
            antigravityAccountError = String(localized: "No Antigravity sign-in was found. Sign in to Antigravity CLI or app, then try again.")
            return
        }
        let identity = credentials.identityLabel
            ?? "Antigravity account \(antigravityAccounts.count + 1)"
        do {
            let account = try AntigravityAccountVault.save(data, identity: identity, defaults: defaults)
            antigravityAccounts = AntigravityAccountVault.accounts(defaults: defaults)
            activeAntigravityAccountID = account.id
            antigravityAccountError = nil
            antigravityAccountSwitchInFlight = true
            defer { antigravityAccountSwitchInFlight = false }
            await refresh(provider: .antigravity)
        } catch {
            antigravityAccountError = error.localizedDescription
        }
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
        activeAntigravityAccountID = id
        antigravityAccountError = nil
        await refresh(provider: .antigravity)
    }

    func removeAntigravityAccount(_ id: String) {
        guard !antigravityAccountSwitchInFlight, !refreshing.contains(.antigravity) else {
            antigravityAccountError = String(localized: "Wait for the Antigravity refresh to finish, then switch accounts.")
            return
        }
        let wasActive = activeAntigravityAccountID == id
        do {
            try AntigravityAccountVault.remove(id, defaults: defaults)
            antigravityAccounts = AntigravityAccountVault.accounts(defaults: defaults)
            activeAntigravityAccountID = AntigravityAccountVault.activeAccountID(defaults: defaults)
            antigravityAccountError = nil
            if wasActive {
                Task { await refresh(provider: .antigravity) }
            }
        } catch {
            antigravityAccountError = error.localizedDescription
        }
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

    /// Interval between `~/.codex/auth.json` mtime checks. A change only
    /// *suggests* a folder swap; the next successful fetch's account identity
    /// decides whether the account actually switched.
    static let codexAuthCheckInterval: Duration = .seconds(30)
    /// Fresh writes (token refreshes, mid-move copies) must settle before
    /// triggering a fetch, so rapid rewrites don't cause refresh storms.
    static let codexAuthSettleInterval: TimeInterval = 5

    private nonisolated static func defaultCodexAuthFileURL() -> URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("auth.json", isDirectory: false)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json", isDirectory: false)
    }

    private nonisolated static func defaultModificationDate(for path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }

    /// Returns true when the Codex auth file changed and settled since the
    /// last check. The first observation only baselines; missing files and
    /// unsettled writes re-baseline without triggering, so a token refresh by
    /// the CLI or a half-finished folder move never causes a spurious fetch.
    func codexAuthDidChange(now: Date = .now) -> Bool {
        let current = fileModificationDate(codexAuthFileURL.path)
        guard let mtime = current else {
            lastSeenCodexAuthMtime = nil
            return false
        }
        guard let lastSeen = lastSeenCodexAuthMtime else {
            lastSeenCodexAuthMtime = mtime
            return false
        }
        guard mtime != lastSeen, now.timeIntervalSince(mtime) >= Self.codexAuthSettleInterval else { return false }
        lastSeenCodexAuthMtime = mtime
        return true
    }

    private func startCodexAuthWatcher() {
        codexAuthWatcher?.cancel()
        codexAuthWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.codexAuthCheckInterval)
                guard !Task.isCancelled, let self else { return }
                guard self.refreshPolicy != .manual, self.visibleProviders.contains(.codex) else { continue }
                if await self.codexAuthDidChange() {
                    await self.refresh(provider: .codex)
                }
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

    // MARK: - Codex homes (folder-swap account switching)

    /// Live Codex home directory (`~/.codex` unless `$CODEX_HOME` overrides).
    var codexLiveHomeURL: URL { codexAuthFileURL.deletingLastPathComponent() }
    var codexDefaultHomeSlotURL: URL {
        managedCodexAccountsRootURL.appendingPathComponent("default-home", isDirectory: true)
    }
    var codexAccountManagementStarted: Bool {
        codexHomes.contains { $0.path == codexDefaultHomeSlotURL.standardizedFileURL.path }
    }
    func isCodexDefaultHomeSlot(_ home: CodexHome) -> Bool {
        home.path == codexDefaultHomeSlotURL.standardizedFileURL.path
    }

    /// Moves the existing live home into managed storage and reserves a slot
    /// for the live home so a new account can be signed in with `codex login`.
    func startManagingCodexAccounts() throws {
        guard !codexSwitchInFlight, !refreshing.contains(.codex) else {
            throw CodexHomeError.busy
        }
        guard !codexAccountManagementStarted else {
            throw CodexHomeError.managementAlreadyStarted
        }

        let fileManager = FileManager.default
        let liveURL = codexLiveHomeURL.standardizedFileURL
        let rootURL = managedCodexAccountsRootURL.standardizedFileURL
        let defaultSlotURL = codexDefaultHomeSlotURL.standardizedFileURL
        let livePathPrefix = liveURL.path.hasSuffix("/") ? liveURL.path : liveURL.path + "/"
        guard rootURL.path != liveURL.path, !rootURL.path.hasPrefix(livePathPrefix) else {
            throw CodexHomeError.managedSlotOccupied(rootURL.path)
        }
        guard Self.isDirectory(at: liveURL) else { throw CodexHomeError.liveHomeMissing }
        guard Self.hasCodexAuthFile(at: liveURL) else { throw CodexHomeError.liveHomeMissingAuth }
        guard !Self.pathExists(defaultSlotURL.path) else {
            throw CodexHomeError.managedSlotOccupied(defaultSlotURL.path)
        }

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        guard Self.volumeIdentifier(for: rootURL) != nil,
              Self.volumeIdentifier(for: rootURL) == Self.volumeIdentifier(for: liveURL) else {
            throw CodexHomeError.crossVolume
        }

        let accountURL = rootURL.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        guard !Self.pathExists(accountURL.path) else {
            throw CodexHomeError.managedSlotOccupied(accountURL.path)
        }
        let currentSnapshot = snapshots[.codex]
        let managedHome = CodexHome(
            path: accountURL.path,
            lastSeenAccountID: currentSnapshot?.accountID,
            lastSeenEmail: currentSnapshot?.accountID?.contains("@") == true ? currentSnapshot?.accountID : nil,
            lastSeenAccount: currentSnapshot?.account,
            lastSeenAt: currentSnapshot?.error == nil ? currentSnapshot?.lastSuccess : nil
        )

        try fileManager.moveItem(at: liveURL, to: accountURL)
        do {
            try fileManager.createDirectory(at: liveURL, withIntermediateDirectories: false)
        } catch {
            do {
                try fileManager.moveItem(at: accountURL, to: liveURL)
            } catch {
                throw CodexHomeError.moveFailed(
                    "The home is safely stored at \(accountURL.path), but could not be restored to \(liveURL.path): \(error.localizedDescription)"
                )
            }
            throw CodexHomeError.moveFailed("Could not prepare the default Codex home: \(error.localizedDescription)")
        }

        if let previousActive = activeCodexHomePath, !Self.pathExists(previousActive) {
            codexHomes.removeAll { $0.path == previousActive }
            codexAccountSnapshots[previousActive] = nil
        }
        codexHomes.append(managedHome)
        codexHomes.append(CodexHome(path: defaultSlotURL.path))
        activeCodexHomePath = defaultSlotURL.path
        if let currentSnapshot { codexAccountSnapshots[accountURL.path] = currentSnapshot }
        codexAccountSnapshots[defaultSlotURL.path] = nil
        snapshots[.codex] = nil
        codexSwitchError = nil
        saveCodexAccountSnapshots()
        save()
    }

    /// Whether `home`'s folder is currently live. Prefers the tracked active
    /// slot; falls back to identity matching so manual moves behind our back
    /// still resolve. Duplicate identities across slots resolve to the first.
    func isCodexHomeActive(_ home: CodexHome) -> Bool {
        if let active = activeCodexHomePath { return active == home.path }
        guard let liveID = snapshots[.codex]?.accountID, !liveID.isEmpty else { return false }
        return home.lastSeenAccountID == liveID
    }

    func codexHomeDisplayName(_ home: CodexHome) -> String {
        if home.path == codexDefaultHomeSlotURL.standardizedFileURL.path,
           home.lastSeenAccount == nil, home.lastSeenEmail == nil {
            return String(localized: "Default Codex home", locale: locale)
        }
        let matchingHomes = codexHomes.filter { $0.displayName == home.displayName }
        guard matchingHomes.count > 1 else { return home.displayName }
        let slotName = URL(fileURLWithPath: home.path, isDirectory: true).lastPathComponent
        return "\(home.displayName) · \(slotName)"
    }

    /// True when the live account matches no registered home.
    var codexLiveHomeIsUnregistered: Bool {
        guard let liveID = snapshots[.codex]?.accountID, !liveID.isEmpty else { return false }
        return !codexHomes.contains(where: { $0.lastSeenAccountID == liveID })
    }

    /// Registers a stash slot. Validates upfront so a later switch can't fail
    /// on a bad folder. The live home itself can't be a slot.
    func addCodexHome(at url: URL) throws {
        let homeURL = URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
        guard Self.isDirectory(at: homeURL) else { throw CodexHomeError.notDirectory }
        guard homeURL.path != codexLiveHomeURL.path else { throw CodexHomeError.isLiveHome }
        guard !codexHomes.contains(where: { $0.path == homeURL.path }) else { throw CodexHomeError.duplicate }
        guard Self.hasCodexAuthFile(at: homeURL) else { throw CodexHomeError.missingAuthFile }
        guard Self.volumeIdentifier(for: homeURL) != nil,
              Self.volumeIdentifier(for: homeURL) == Self.volumeIdentifier(for: codexLiveHomeURL) else {
            throw CodexHomeError.crossVolume
        }
        codexHomes.append(CodexHome(path: homeURL.path))
    }

    /// Assigns an empty parking spot for the live folder: records `url` as a
    /// slot without moving anything. Used once to bootstrap switching when the
    /// live folder has no registered slot yet — the next successful fetch
    /// binds the live identity to it by elimination.
    func assignCodexHomeSlot(at url: URL) throws {
        let slotURL = URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
        let parentURL = slotURL.deletingLastPathComponent()
        guard slotURL.path != codexLiveHomeURL.path else { throw CodexHomeError.isLiveHome }
        guard !codexHomes.contains(where: { $0.path == slotURL.path }) else { throw CodexHomeError.duplicate }
        guard !FileManager.default.fileExists(atPath: slotURL.path) else {
            throw CodexHomeError.occupiedSlot(slotURL.path)
        }
        guard Self.isDirectory(at: parentURL) else { throw CodexHomeError.notDirectory }
        guard Self.volumeIdentifier(for: parentURL) != nil,
              Self.volumeIdentifier(for: parentURL) == Self.volumeIdentifier(for: codexLiveHomeURL) else {
            throw CodexHomeError.crossVolume
        }
        codexHomes.append(CodexHome(path: slotURL.path))
    }

    /// Whether the slot has no signed-in Codex home (including a newly
    /// recreated but not yet authenticated default directory).
    func isCodexSlotEmpty(_ home: CodexHome) -> Bool {
        !Self.hasCodexAuthFile(at: URL(fileURLWithPath: home.path, isDirectory: true))
    }

    /// Removes a registry entry. Never touches the disk; the live folder stays
    /// as-is even if it was the active slot (it then shows as unregistered).
    func removeCodexHome(_ home: CodexHome) {
        codexHomes.removeAll(where: { $0.path == home.path })
        codexAccountSnapshots[home.path] = nil
        saveCodexAccountSnapshots()
        if activeCodexHomePath == home.path { activeCodexHomePath = nil }
    }

    /// Moves folders so `target`'s home becomes live. Explicit user action
    /// only — never called automatically. Only folders move; credential
    /// contents are never read or written.
    func switchCodexAccount(to target: CodexHome) async {
        guard !codexSwitchInFlight else { return }
        guard !refreshing.contains(.codex) else {
            codexSwitchError = CodexHomeError.busy.localizedDescription
            return
        }
        guard !isCodexSlotEmpty(target) || isCodexDefaultHomeSlot(target) else {
            codexSwitchError = CodexHomeError.emptySlot.localizedDescription
            return
        }
        codexSwitchInFlight = true
        defer { codexSwitchInFlight = false }
        codexSwitchError = nil
        do {
            let source = try resolveCodexSourceSlot()
            guard source.path != target.path else { return }
            guard let liveTarget = codexHomes.first(where: { $0.path == target.path }) else { return }
            let targetSnapshotBeforeSwitch = codexAccountSnapshots[target.path]
            if let currentSnapshot = snapshots[.codex] {
                codexAccountSnapshots[source.path] = currentSnapshot
                saveCodexAccountSnapshots()
            }
            try performCodexHomeSwap(from: source, to: liveTarget)
            activeCodexHomePath = target.path
            lastSeenCodexAuthMtime = fileModificationDate(codexAuthFileURL.path)
            restoreCodexSnapshot(for: liveTarget)
            let switchedAt = Date.now
            await refresh(provider: .codex)
            if let expected = liveTarget.lastSeenAccountID, !expected.isEmpty,
               let snap = snapshots[.codex], snap.error == nil, snap.lastSuccess >= switchedAt,
               let found = snap.accountID, !found.isEmpty, found != expected {
                do {
                    try performCodexHomeSwap(from: liveTarget, to: source)
                    activeCodexHomePath = source.path
                } catch {
                    activeCodexHomePath = nil
                }
                if let index = codexHomes.firstIndex(where: { $0.path == liveTarget.path }) {
                    codexHomes[index].lastSeenAccountID = liveTarget.lastSeenAccountID
                    codexHomes[index].lastSeenEmail = liveTarget.lastSeenEmail
                    codexHomes[index].lastSeenAccount = liveTarget.lastSeenAccount
                    codexHomes[index].lastSeenAt = liveTarget.lastSeenAt
                }
                if let targetSnapshotBeforeSwitch {
                    codexAccountSnapshots[liveTarget.path] = targetSnapshotBeforeSwitch
                } else {
                    codexAccountSnapshots[liveTarget.path] = nil
                }
                if let sourceSnapshot = codexAccountSnapshots[source.path] {
                    snapshots[.codex] = sourceSnapshot
                } else {
                    snapshots[.codex] = nil
                }
                saveCodexAccountSnapshots()
                save()
                throw CodexHomeError.identityMismatch(expected: expected, found: found)
            }
        } catch let error as CodexHomeError {
            codexSwitchError = error.localizedDescription
        } catch {
            codexSwitchError = error.localizedDescription
        }
    }

    /// Records the live Codex identity and reconciles which slot's folder is
    /// live. Manual moves to a known slot are adopted by identity; an unknown
    /// identity binds by elimination when exactly one slot has no folder on
    /// disk (covers first observation and re-login in place). Fully unknown
    /// live folders are never auto-registered.
    private func noteSuccessfulCodexFetch(_ snapshot: UsageSnapshot) {
        guard let accountID = snapshot.accountID, !accountID.isEmpty else { return }
        if let match = codexHomes.first(where: { $0.lastSeenAccountID == accountID }) {
            activeCodexHomePath = match.path
        } else if let active = activeCodexHomePath,
                  codexHomes.contains(where: { $0.path == active }),
                  !Self.pathExists(active) {
            // Believed-active slot empty: its folder is presumably live.
        } else {
            activeCodexHomePath = nil
            let missing = codexHomes.filter { !Self.pathExists($0.path) }
            guard missing.count == 1,
                  codexHomes.contains(where: { $0.path == missing[0].path }) else { return }
            activeCodexHomePath = missing[0].path
        }
        if let index = codexHomes.firstIndex(where: { $0.path == activeCodexHomePath }) {
            codexHomes[index].lastSeenAccountID = accountID
            codexHomes[index].lastSeenEmail = snapshot.accountID?.contains("@") == true ? snapshot.accountID : nil
            codexHomes[index].lastSeenAccount = snapshot.account
            codexHomes[index].lastSeenAt = snapshot.lastSuccess
        }
    }

    private func cacheCodexSnapshot(_ snapshot: UsageSnapshot) {
        guard let accountPath = activeCodexHomePath,
              codexHomes.contains(where: { $0.path == accountPath }) else { return }
        codexAccountSnapshots[accountPath] = snapshot
        saveCodexAccountSnapshots()
    }

    private func restoreCodexSnapshot(for home: CodexHome) {
        guard let cached = codexAccountSnapshots[home.path],
              home.lastSeenAccountID == nil || cached.accountID == home.lastSeenAccountID else {
            snapshots[.codex] = nil
            return
        }
        snapshots[.codex] = cached
    }

    /// Which slot's folder currently sits at the live location. Refuses when
    /// the live folder matches nothing known, so a switch can never displace
    /// an unidentified folder into the wrong slot.
    private func resolveCodexSourceSlot() throws -> CodexHome {
        let liveID = snapshots[.codex]?.accountID
        if let active = activeCodexHomePath,
           let entry = codexHomes.first(where: { $0.path == active }) {
            if let liveID, !liveID.isEmpty,
               let recorded = entry.lastSeenAccountID, !recorded.isEmpty,
               recorded != liveID,
               !codexHomes.contains(where: { $0.path != entry.path && $0.lastSeenAccountID == liveID }) {
                throw CodexHomeError.unknownLiveHome
            }
            return entry
        }
        if let liveID, !liveID.isEmpty,
           let match = codexHomes.first(where: { $0.lastSeenAccountID == liveID }) {
            return match
        }
        throw CodexHomeError.unknownLiveHome
    }

    /// live(A) → tmp, B → live, tmp → A-slot. Same-volume renames, near
    /// atomic. Each step restores the previous ones on failure; nothing is
    /// ever deleted or overwritten (occupied slots refuse upfront).
    private func performCodexHomeSwap(from source: CodexHome, to target: CodexHome) throws {
        let fm = FileManager.default
        let liveURL = codexLiveHomeURL
        let sourceURL = URL(fileURLWithPath: source.path, isDirectory: true)
        let targetURL = URL(fileURLWithPath: target.path, isDirectory: true)
        let tmpURL = liveURL.deletingLastPathComponent()
            .appendingPathComponent(".codex.swap-tmp", isDirectory: true)
        if isCodexDefaultHomeSlot(target), !Self.hasCodexAuthFile(at: targetURL) {
            if !Self.pathExists(targetURL.path) {
                try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: false)
            }
            guard Self.isDirectory(at: targetURL) else { throw CodexHomeError.missingAuthFile }
        } else {
            guard Self.isDirectory(at: targetURL), Self.hasCodexAuthFile(at: targetURL) else {
                throw CodexHomeError.missingAuthFile
            }
        }
        guard !fm.fileExists(atPath: tmpURL.path) else {
            throw CodexHomeError.leftoverSwapFolder(tmpURL.path)
        }
        guard Self.isDirectory(at: liveURL) else {
            throw CodexHomeError.moveFailed("The live Codex home is missing.")
        }
        guard !fm.fileExists(atPath: sourceURL.path) else {
            throw CodexHomeError.occupiedSlot(sourceURL.path)
        }
        guard Self.volumeIdentifier(for: liveURL) != nil,
              Self.volumeIdentifier(for: liveURL) == Self.volumeIdentifier(for: targetURL) else {
            throw CodexHomeError.crossVolume
        }
        do {
            try fm.moveItem(at: liveURL, to: tmpURL)
        } catch {
            throw CodexHomeError.moveFailed(error.localizedDescription)
        }
        do {
            try fm.moveItem(at: targetURL, to: liveURL)
        } catch {
            try? fm.moveItem(at: tmpURL, to: liveURL)
            throw CodexHomeError.moveFailed(error.localizedDescription)
        }
        do {
            try fm.moveItem(at: tmpURL, to: sourceURL)
        } catch {
            try? fm.moveItem(at: liveURL, to: targetURL)
            try? fm.moveItem(at: tmpURL, to: liveURL)
            throw CodexHomeError.moveFailed(error.localizedDescription)
        }
    }

    private static func isDirectory(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func pathExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private static func hasCodexAuthFile(at homeURL: URL) -> Bool {
        var isDir: ObjCBool = false
        let path = homeURL.appendingPathComponent("auth.json", isDirectory: false).path
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    private static func volumeIdentifier(for url: URL) -> AnyHashable? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? AnyHashable
    }

    private func saveCodexHomes() {
        if let data = try? JSONEncoder().encode(codexHomes) {
            defaults.set(data, forKey: "codexHomes")
        }
    }

    private func saveCodexAccountSnapshots() {
        if let data = try? JSONEncoder().encode(codexAccountSnapshots) {
            defaults.set(data, forKey: "codexAccountSnapshots")
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(snapshots.values)) { try? data.write(to: cacheURL, options: .atomic) }
        publishWidgetSnapshot()
    }

    private func publishWidgetSnapshot() {
        WidgetSnapshotSharing.write(snapshots: snapshots, order: Provider.supported, visible: visibleProviders)
    }
}
