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
                Button { showSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(HeaderIconButtonStyle()).help("Settings")
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "xmark") }
                    .buttonStyle(HeaderIconButtonStyle()).help("Quit")
            }
            ForEach(Provider.allCases.filter { store.visibleProviders.contains($0) }) { provider in
                providerCard(provider)
            }
            HStack {
                Text("Refreshes every \(max(1, store.refreshInterval / 60)) min")
                Spacer()
                Button("Settings…") { showSettings() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
                .font(.caption)
        }
        .padding(16).frame(width: 340).task { if store.needsInitialRefreshOnOpen { await store.refresh() } }
        .preferredColorScheme(store.appearance == "Light" ? .light : store.appearance == "Dark" ? .dark : nil)
    }
    private func showSettings() {
        // Menu bar apps run as accessory apps. Activate before asking SwiftUI to
        // present its Settings scene so the window doesn't open behind other apps.
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
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

private extension Provider {
    var systemImage: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "terminal.fill"
        }
    }
    var tint: Color {
        switch self {
        case .claude: return .orange
        case .codex: return .green
        }
    }
    var subtitle: String {
        switch self {
        case .claude: return "Claude Code OAuth usage"
        case .codex: return "Codex CLI app-server"
        }
    }
}

struct SettingsView: View {
    @Environment(UsageStore.self) private var store
    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                providersCard(store: $store)
                displayCard(store: $store)
                thresholdsCard(store: $store)
                statusCard
                aboutCard
            }
            .padding(22)
        }
        .frame(width: 560, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(store.appearance == "Light" ? .light : store.appearance == "Dark" ? .dark : nil)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("AIUsage Settings").font(.title3.weight(.semibold))
                Text("Menu bar monitor for Claude and Codex quotas")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func providersCard(store: Bindable<UsageStore>) -> some View {
        SettingsSection(title: "Providers", icon: "cpu") {
            VStack(spacing: 0) {
                ForEach(Provider.allCases) { provider in
                    HStack(spacing: 12) {
                        Image(systemName: provider.systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(provider.tint))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(provider.rawValue).font(.body.weight(.medium))
                            Text(provider.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle(provider.rawValue, isOn: Binding(
                            get: { store.wrappedValue.visibleProviders.contains(provider) },
                            set: { enabled in
                                if enabled { store.wrappedValue.visibleProviders.insert(provider) }
                                else { store.wrappedValue.visibleProviders.remove(provider) }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    .padding(.vertical, 9)
                    if provider != Provider.allCases.last {
                        Divider().padding(.leading, 42)
                    }
                }
            }
        }
    }

    private func displayCard(store: Bindable<UsageStore>) -> some View {
        SettingsSection(title: "Display", icon: "display") {
            VStack(spacing: 12) {
                SettingsRow(label: "Menu bar") {
                    Picker("", selection: store.menuBarStyle) {
                        Text("Highest usage").tag("Highest usage")
                        Text("App name").tag("App name")
                    }
                    .pickerStyle(.menu).frame(maxWidth: 220, alignment: .trailing)
                    .labelsHidden()
                }
                Divider()
                SettingsRow(label: "Appearance") {
                    Picker("", selection: store.appearance) {
                        Text("System").tag("System")
                        Text("Light").tag("Light")
                        Text("Dark").tag("Dark")
                    }
                    .pickerStyle(.segmented).frame(width: 220)
                    .labelsHidden()
                }
                Divider()
                SettingsRow(label: "Refresh") {
                    Picker("", selection: store.refreshInterval) {
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                        Text("15 minutes").tag(900)
                        Text("30 minutes").tag(1800)
                    }
                    .pickerStyle(.menu).frame(maxWidth: 220, alignment: .trailing)
                    .labelsHidden()
                    .onChange(of: store.wrappedValue.refreshInterval) { store.wrappedValue.schedule() }
                }
            }
        }
    }

    private func thresholdsCard(store: Bindable<UsageStore>) -> some View {
        SettingsSection(title: "Thresholds", icon: "exclamationmark.triangle") {
            VStack(spacing: 14) {
                ThresholdRow(
                    label: "Warning",
                    value: store.warningThreshold,
                    tint: .orange,
                    range: 30...95
                )
                Divider()
                ThresholdRow(
                    label: "Critical",
                    value: store.criticalThreshold,
                    tint: .red,
                    range: 50...100
                )
                Text("Menu bar turns orange at warning, red at critical.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: store.wrappedValue.warningThreshold) {
            if store.wrappedValue.warningThreshold >= store.wrappedValue.criticalThreshold {
                store.wrappedValue.criticalThreshold = min(100, store.wrappedValue.warningThreshold + 5)
            }
        }
        .onChange(of: store.wrappedValue.criticalThreshold) {
            if store.wrappedValue.criticalThreshold <= store.wrappedValue.warningThreshold {
                store.wrappedValue.warningThreshold = max(30, store.wrappedValue.criticalThreshold - 5)
            }
        }
    }

    private var statusCard: some View {
        SettingsSection(title: "Provider status", icon: "antenna.radiowaves.left.and.right") {
            VStack(spacing: 0) {
                ForEach(Provider.allCases) { provider in
                    HStack(spacing: 10) {
                        StatusDot(provider: provider)
                        Text(provider.rawValue).font(.body)
                        Spacer()
                        Text(statusText(for: provider))
                            .font(.callout).foregroundStyle(.secondary)
                        if store.refreshing.contains(provider) {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(.vertical, 7)
                    if provider != Provider.allCases.last {
                        Divider().padding(.leading, 22)
                    }
                }
            }
        }
    }

    private var aboutCard: some View {
        SettingsSection(title: "About", icon: "info.circle") {
            Text("AI Usage Monitor · reads existing Claude Code and Codex CLI credentials. Usage endpoints and app-server protocol may change.\nMIT-licensed design and integration references: claude-usage-widget by bozdemir; codex-usage-bar by CMMUU.")
                .font(.caption).foregroundStyle(.secondary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func statusText(for provider: Provider) -> String {
        if let snapshot = store.snapshots[provider] {
            return snapshot.error ?? "Connected"
        }
        return "Not refreshed"
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title.uppercased(), systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    var body: some View {
        HStack {
            Text(label)
                .font(.body)
                .frame(width: 100, alignment: .leading)
            Spacer()
            content
        }
        .padding(.vertical, 3)
    }
}

private struct ThresholdRow: View {
    let label: String
    @Binding var value: Double
    let tint: Color
    let range: ClosedRange<Double>
    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(.body).frame(width: 100, alignment: .leading)
            Slider(value: $value, in: range, step: 5)
                .tint(tint)
            Text("\(Int(value))%")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(tint))
                .frame(minWidth: 56)
        }
        .padding(.vertical, 2)
    }
}

private struct StatusDot: View {
    @Environment(UsageStore.self) private var store
    let provider: Provider
    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 0.5))
    }
    private var dotColor: Color {
        if store.refreshing.contains(provider) { return .blue }
        guard let snapshot = store.snapshots[provider] else { return .gray.opacity(0.5) }
        if snapshot.error != nil { return .orange }
        let peak = snapshot.windows.map(\.utilization).max() ?? 0
        if peak >= store.criticalThreshold { return .red }
        if peak >= store.warningThreshold { return .orange }
        return .green
    }
}
