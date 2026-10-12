import SwiftUI

@main struct AIUsageApp: App {
    @State private var store = UsageStore()
    var body: some Scene {
        MenuBarExtra {
            UsagePopover().environment(store)
        } label: {
            MenuBarLabel(text: menuLabel, color: menuBarColor)
        }
        .menuBarExtraStyle(.window)
        Settings { SettingsView().environment(store) }
    }
    private var maxUsage: Double? {
        let values = store.snapshots.values.filter { store.visibleProviders.contains($0.provider) }.flatMap(\.windows).map(\.utilization)
        return values.max()
    }
    private var menuBarColor: Color {
        guard store.menuBarStyle != "App name", let value = maxUsage else {
            return Color(red: 0.55, green: 0.53, blue: 0.7)
        }
        if value >= store.criticalThreshold { return .red }
        if value >= store.warningThreshold { return .orange }
        return Color(red: 0.55, green: 0.53, blue: 0.7)
    }
    private var menuLabel: String {
        if store.menuBarStyle == "App name" { return "AI Usage" }
        return maxUsage.map { "AI \(Int($0.rounded()))%" } ?? "AI Usage"
    }
}

struct MenuBarLabel: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color))
    }
}

struct HeaderIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.85))
            .frame(width: 44, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.purple.opacity(configuration.isPressed ? 0.3 : 0.15))
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct UsagePopover: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("AI Usage").font(.headline)
                Spacer()
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(HeaderIconButtonStyle()).help("Refresh now")
                    .disabled(!store.refreshing.isEmpty)
                Button { openSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(HeaderIconButtonStyle()).help("Settings")
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "xmark") }
                    .buttonStyle(HeaderIconButtonStyle()).help("Quit")
            }
            ForEach(Provider.allCases.filter { store.visibleProviders.contains($0) }) { provider in
                providerCard(provider)
            }
            HStack { Text("Refreshes every \(max(1, store.refreshInterval / 60)) min"); Spacer(); Text("Settings…").foregroundStyle(.secondary).onTapGesture { openSettings() } }
                .font(.caption)
        }
        .padding(16).frame(width: 340).task { if store.needsInitialRefreshOnOpen { await store.refresh() } }
        .preferredColorScheme(store.appearance == "Light" ? .light : store.appearance == "Dark" ? .dark : nil)
    }
    @ViewBuilder private func providerCard(_ provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(provider.rawValue).font(.subheadline.weight(.semibold)); Spacer(); if store.refreshing.contains(provider) { ProgressView().controlSize(.small) } }
            if let snapshot = store.snapshots[provider] {
                if snapshot.windows.isEmpty {
                    Text(snapshot.error ?? "No quota windows or usage credits were reported.")
                        .foregroundStyle(snapshot.error == nil ? Color.secondary : Color.orange)
                        .font(.caption).lineLimit(5).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(snapshot.windows) { window in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(window.label); Spacer(); Text("\(Int(window.utilization.rounded()))%") }
                            .font(.caption)
                        ProgressView(value: window.utilization, total: 100).tint(color(for: window.utilization))
                        if let detail = window.detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
                        if let date = window.resetsAt { Text("Resets \(date, style: .relative)").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                if let account = snapshot.account { Text(account).font(.caption2).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 3) {
                    if let error = snapshot.error {
                        Text("Stale · \(error)").lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Updated")
                    }
                    if snapshot.lastSuccess != .distantPast { Text(snapshot.lastSuccess, style: .time) }
                }.font(.caption2).foregroundStyle(snapshot.error == nil ? Color.secondary : Color.orange)
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
