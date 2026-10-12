import Foundation
import SwiftUI
import ServiceManagement

@MainActor @Observable final class UsageStore {
    var snapshots: [Provider: UsageSnapshot] = [:]
    var refreshing: Set<Provider> = []
    var visibleProviders: Set<Provider> = Set(Provider.supported) {
        didSet { defaults.set(visibleProviders.map(\.rawValue), forKey: "visibleProviders") }
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
    var appearance = "system" { didSet { defaults.set(appearance, forKey: "appearance") } }
    var autoStartUsageWindow = false { didSet { defaults.set(autoStartUsageWindow, forKey: "autoStartUsageWindow") } }
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
    var codexSwitchInFlight = false
    var codexSwitchError: String?

    @ObservationIgnored private let providers: [any UsageProvider]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private let codexAuthFileURL: URL
    @ObservationIgnored private let fileModificationDate: @Sendable (String) -> Date?
    @ObservationIgnored private let autoStartRunner: any UsageWindowStartCommandRunning
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
        fileModificationDate: (@Sendable (String) -> Date?)? = nil,
        autoStartRunner: any UsageWindowStartCommandRunning = LocalUsageWindowStartCommandRunner()
    ) {
        self.providers = providers
        self.defaults = defaults
        self.cacheURL = cacheURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIUsage/snapshots.json")
        self.codexAuthFileURL = codexAuthFileURL ?? Self.defaultCodexAuthFileURL()
        self.fileModificationDate = fileModificationDate ?? Self.defaultModificationDate
        self.autoStartRunner = autoStartRunner
        if let raw = defaults.stringArray(forKey: "visibleProviders") {
            visibleProviders = Set(raw.compactMap(Provider.init(rawValue:)))
        }
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
        appearance = (defaults.string(forKey: "appearance") ?? "system").lowercased()
        autoStartUsageWindow = defaults.bool(forKey: "autoStartUsageWindow")
        if let data = defaults.data(forKey: "codexHomes"),
           let homes = try? JSONDecoder().decode([CodexHome].self, from: data) {
            codexHomes = homes
        }
        activeCodexHomePath = defaults.string(forKey: "activeCodexHomePath")
        if let data = try? Data(contentsOf: self.cacheURL), let cached = try? JSONDecoder().decode([UsageSnapshot].self, from: data) {
            snapshots = Dictionary(uniqueKeysWithValues: cached.map { ($0.provider, $0) })
            lastRefreshAttempt = cached.map(\.lastSuccess).filter { $0 != .distantPast }.max()
        }
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        schedule()
        startCodexAuthWatcher()
        if startImmediately { Task { await self.refresh() } }
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
                    if provider == .codex {
                        noteSuccessfulCodexFetch(snapshot)
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

    // MARK: - Codex homes (folder-swap account switching)

    /// Live Codex home directory (`~/.codex` unless `$CODEX_HOME` overrides).
    var codexLiveHomeURL: URL { codexAuthFileURL.deletingLastPathComponent() }

    /// Whether `home`'s folder is currently live. Prefers the tracked active
    /// slot; falls back to identity matching so manual moves behind our back
    /// still resolve. Duplicate identities across slots resolve to the first.
    func isCodexHomeActive(_ home: CodexHome) -> Bool {
        if let active = activeCodexHomePath { return active == home.path }
        guard let liveID = snapshots[.codex]?.accountID, !liveID.isEmpty else { return false }
        return home.lastSeenAccountID == liveID
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

    /// Whether the slot has no folder on disk (checked out live, or never placed).
    func isCodexSlotEmpty(_ home: CodexHome) -> Bool { !Self.pathExists(home.path) }

    /// Removes a registry entry. Never touches the disk; the live folder stays
    /// as-is even if it was the active slot (it then shows as unregistered).
    func removeCodexHome(_ home: CodexHome) {
        codexHomes.removeAll(where: { $0.path == home.path })
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
        codexSwitchInFlight = true
        defer { codexSwitchInFlight = false }
        codexSwitchError = nil
        do {
            let source = try resolveCodexSourceSlot()
            guard source.path != target.path else { return }
            guard let liveTarget = codexHomes.first(where: { $0.path == target.path }) else { return }
            try performCodexHomeSwap(from: source, to: liveTarget)
            activeCodexHomePath = target.path
            lastSeenCodexAuthMtime = fileModificationDate(codexAuthFileURL.path)
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
            codexHomes[index].lastSeenEmail = snapshot.account
            codexHomes[index].lastSeenAt = snapshot.lastSuccess
        }
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
        guard Self.isDirectory(at: targetURL), Self.hasCodexAuthFile(at: targetURL) else {
            throw CodexHomeError.missingAuthFile
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

    private func save() {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(snapshots.values)) { try? data.write(to: cacheURL, options: .atomic) }
    }
}
