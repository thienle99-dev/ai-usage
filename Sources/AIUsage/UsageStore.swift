import Foundation
import SwiftUI

@MainActor @Observable final class UsageStore {
    var snapshots: [Provider: UsageSnapshot] = [:]
    var refreshing: Set<Provider> = []
    var visibleProviders: Set<Provider> = Set(Provider.allCases) { didSet { defaults.set(visibleProviders.map(\.rawValue), forKey: "visibleProviders") } }
    var refreshInterval = 300 { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    var warningThreshold = 70.0 { didSet { defaults.set(warningThreshold, forKey: "warningThreshold") } }
    var criticalThreshold = 90.0 { didSet { defaults.set(criticalThreshold, forKey: "criticalThreshold") } }
    var menuBarStyle = "Highest usage" { didSet { defaults.set(menuBarStyle, forKey: "menuBarStyle") } }
    var appearance = "System" { didSet { defaults.set(appearance, forKey: "appearance") } }
    private let providers: [any UsageProvider] = [ClaudeProvider(), CodexProvider()]
    private var timer: Task<Void, Never>?
    private var didCompleteInitialRefresh = false
    private let defaults = UserDefaults.standard
    private let cacheURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AIUsage/snapshots.json")

    var needsInitialRefreshOnOpen: Bool {
        guard !didCompleteInitialRefresh else { return false }
        return snapshots.isEmpty || snapshots.values.contains(where: \.isStale) || snapshots[.claude]?.account == nil
    }

    init() {
        if let raw = defaults.stringArray(forKey: "visibleProviders") {
            visibleProviders = Set(raw.compactMap(Provider.init(rawValue:)))
        }
        if defaults.object(forKey: "refreshInterval") != nil { refreshInterval = defaults.integer(forKey: "refreshInterval") }
        if defaults.object(forKey: "warningThreshold") != nil { warningThreshold = defaults.double(forKey: "warningThreshold") }
        if defaults.object(forKey: "criticalThreshold") != nil { criticalThreshold = defaults.double(forKey: "criticalThreshold") }
        menuBarStyle = defaults.string(forKey: "menuBarStyle") ?? menuBarStyle
        appearance = defaults.string(forKey: "appearance") ?? appearance
        if let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode([UsageSnapshot].self, from: data) {
            snapshots = Dictionary(uniqueKeysWithValues: cached.map { ($0.provider, $0) })
        }
        schedule()
    }
    func refresh() async {
        await withTaskGroup(of: (Provider, Result<UsageSnapshot, Error>).self) { group in
            for provider in providers {
                refreshing.insert(provider.provider)
                group.addTask { (provider.provider, await Result { try await provider.fetch() }) }
            }
            for await (provider, result) in group {
                refreshing.remove(provider)
                switch result {
                case .success(let snapshot): snapshots[provider] = snapshot
                case .failure(let error):
                    if var snapshot = snapshots[provider] { snapshot.error = error.localizedDescription; snapshots[provider] = snapshot }
                    else { snapshots[provider] = UsageSnapshot(provider: provider, windows: [], account: nil, lastSuccess: .distantPast, error: error.localizedDescription) }
                }
            }
        }
        didCompleteInitialRefresh = true
        save()
    }
    func schedule() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(60, self?.refreshInterval ?? 300)))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }
    private func save() {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(snapshots.values)) { try? data.write(to: cacheURL, options: .atomic) }
    }
}
