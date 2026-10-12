import SwiftUI

@main struct AIUsageApp: App {
    @State private var store = UsageStore()
    var body: some Scene {
        MenuBarExtra {
            UsagePopover().environment(store)
        } label: {
            Text(menuLabel)
        }
        .menuBarExtraStyle(.window)
        Settings { SettingsView().environment(store) }
    }
    private var menuLabel: String {
        if store.menuBarStyle == "App name" { return "AI Usage" }
        let values = store.snapshots.values.filter { store.visibleProviders.contains($0.provider) }.flatMap(\.windows).map(\.utilization)
        return values.isEmpty ? "AI Usage" : "AI \(Int(values.max()!.rounded()))%"
    }
}

struct UsagePopover: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("AI Usage").font(.headline)
                Spacer()
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh now")
                Button { openSettings() } label: { Image(systemName: "gearshape") }.help("Settings")
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "xmark") }.help("Quit")
            }
            ForEach(Provider.allCases.filter { store.visibleProviders.contains($0) }) { provider in
                providerCard(provider)
            }
            HStack { Text("Refreshes every \(max(1, store.refreshInterval / 60)) min"); Spacer(); Text("Settings…").foregroundStyle(.secondary).onTapGesture { openSettings() } }
                .font(.caption)
        }
        .padding(16).frame(width: 340).task { if store.snapshots.isEmpty || store.snapshots.values.contains(where: \.isStale) { await store.refresh() } }
        .preferredColorScheme(store.appearance == "Light" ? .light : store.appearance == "Dark" ? .dark : nil)
    }
    @ViewBuilder private func providerCard(_ provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(provider.rawValue).font(.subheadline.weight(.semibold)); Spacer(); if store.refreshing.contains(provider) { ProgressView().controlSize(.small) } }
            if let snapshot = store.snapshots[provider] {
                if snapshot.windows.isEmpty { Text(snapshot.error ?? "No usage data").foregroundStyle(.secondary).font(.caption) }
                ForEach(snapshot.windows) { window in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(window.label); Spacer(); Text("\(Int(window.utilization.rounded()))%") }
                            .font(.caption)
                        ProgressView(value: window.utilization, total: 100).tint(color(for: window.utilization))
                        if let date = window.resetsAt { Text("Resets \(date, style: .relative)").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                if let account = snapshot.account { Text(account).font(.caption2).foregroundStyle(.secondary) }
                HStack { Text(snapshot.error.map { "Stale · \($0)" } ?? "Updated"); Spacer(); if snapshot.lastSuccess != .distantPast { Text(snapshot.lastSuccess, style: .time) } }
                    .font(.caption2).foregroundStyle(snapshot.error == nil ? Color.secondary : Color.orange)
            } else { Text("Waiting for first refresh…").font(.caption).foregroundStyle(.secondary) }
        }.padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
    private func color(for usage: Double) -> Color { usage >= store.criticalThreshold ? .red : usage >= store.warningThreshold ? .orange : .accentColor }
}

struct SettingsView: View {
    @Environment(UsageStore.self) private var store
    var body: some View {
        @Bindable var store = store
        Form {
            Section("Providers") { ForEach(Provider.allCases) { provider in Toggle(provider.rawValue, isOn: Binding(get: { store.visibleProviders.contains(provider) }, set: { enabled in if enabled { store.visibleProviders.insert(provider) } else { store.visibleProviders.remove(provider) } })) } }
            Section("Display") {
                Picker("Menu bar", selection: $store.menuBarStyle) { Text("Highest usage").tag("Highest usage"); Text("App name").tag("App name") }
                Picker("Appearance", selection: $store.appearance) { Text("System").tag("System"); Text("Light").tag("Light"); Text("Dark").tag("Dark") }
                HStack { Text("Warning at"); Slider(value: $store.warningThreshold, in: 30...95, step: 5); Text("\(Int(store.warningThreshold))%") }
                HStack { Text("Critical at"); Slider(value: $store.criticalThreshold, in: 50...100, step: 5); Text("\(Int(store.criticalThreshold))%") }
                Picker("Refresh", selection: $store.refreshInterval) { Text("1 minute").tag(60); Text("5 minutes").tag(300); Text("15 minutes").tag(900); Text("30 minutes").tag(1800) }.onChange(of: store.refreshInterval) { store.schedule() }
            }
            Section("Provider status") { ForEach(Provider.allCases) { provider in HStack { Text(provider.rawValue); Spacer(); Text(store.snapshots[provider]?.error ?? (store.snapshots[provider] == nil ? "Not refreshed" : "Connected")).foregroundStyle(.secondary) } } }
            Section("About") { Text("AI Usage Monitor · reads existing Claude Code and Codex CLI credentials. Usage endpoints and app-server protocol may change. MIT-licensed design and integration references: claude-usage-widget by bozdemir; codex-usage-bar by CMMUU.").font(.caption).foregroundStyle(.secondary) }
        }.padding(20).frame(width: 480, height: 460)
    }
}
