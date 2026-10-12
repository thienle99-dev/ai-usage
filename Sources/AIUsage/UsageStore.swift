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
    var launchAtLoginEnabled = false
    var launchAtLoginError: String?
    private(set) var lastRefreshAttempt: Date?

    @ObservationIgnored private let providers: [any UsageProvider]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private var timer: Task<Void, Never>?

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
            snapshot.isStale || Date.now.timeIntervalSince(snapshot.lastSuccess) >= minimumGap
        }
    }

    init(
        providers: [any UsageProvider] = [ClaudeProvider(), CodexProvider(), CursorProvider()],
        defaults: UserDefaults = .standard,
        cacheURL: URL? = nil,
        startImmediately: Bool = true
    ) {
        self.providers = providers
        self.defaults = defaults
        self.cacheURL = cacheURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIUsage/snapshots.json")
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
        if let data = try? Data(contentsOf: self.cacheURL), let cached = try? JSONDecoder().decode([UsageSnapshot].self, from: data) {
            snapshots = Dictionary(uniqueKeysWithValues: cached.map { ($0.provider, $0) })
            lastRefreshAttempt = cached.map(\.lastSuccess).filter { $0 != .distantPast }.max()
        }
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        schedule()
        if startImmediately { Task { await self.refresh() } }
    }

    func refresh(provider requestedProvider: Provider? = nil) async {
        let selectedProviders = providers.filter {
            (requestedProvider == nil || $0.provider == requestedProvider) && !refreshing.contains($0.provider)
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

    private func save() {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(snapshots.values)) { try? data.write(to: cacheURL, options: .atomic) }
    }
}
