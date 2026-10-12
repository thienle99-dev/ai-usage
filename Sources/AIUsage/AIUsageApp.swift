import SwiftUI
import AppKit

@main struct AIUsageApp: App {
    @State private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            UsagePopover()
                .environment(store)
                .preferredColorScheme(store.colorSchemeOverride)
        } label: {
            MenuBarStatusView(store: store)
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsWindowView()
                .environment(store)
                .preferredColorScheme(store.colorSchemeOverride)
        }
        .defaultSize(width: 680, height: 500)
        .windowResizability(.contentSize)
    }
}

private struct MenuBarStatusView: View {
    let store: UsageStore

    private var providerUsage: [(Provider, Double)] {
        Provider.allCases.compactMap { provider in
            guard let usage = UsageAggregation.maximum(for: provider, in: store.snapshots, enabled: store.visibleProviders) else { return nil }
            return (provider, usage)
        }
    }
    private var highestUsage: Double? { UsageAggregation.maximum(in: store.snapshots, enabled: store.visibleProviders) }
    private var criticalProviders: [Provider] {
        providerUsage.filter { $0.1 >= store.criticalThreshold }.map(\.0)
    }
    private var symbol: String {
        store.menuBarMode == .criticalProviderOnly && !criticalProviders.isEmpty
            ? "exclamationmark.triangle.fill" : "chart.bar.fill"
    }
    private var text: String {
        switch store.menuBarMode {
        case .iconOnly: ""
        case .combinedUsage:
            highestUsage.map { "\(Int($0.rounded()))%" } ?? ""
        case .providerSpecific:
            providerUsage.map { "\($0.0.shortName) \(Int($0.1.rounded()))%" }.joined(separator: " · ")
        case .criticalProviderOnly:
            criticalProviders.map(\.shortName).joined(separator: " · ")
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
            if !text.isEmpty {
                Text(text).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(text.isEmpty ? "AI Usage Monitor" : "AI Usage Monitor, \(text)")
        .help(text.isEmpty ? "AI Usage Monitor" : "AI Usage Monitor · \(text)")
    }
}

struct UsagePopover: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filter: ProviderFilter = .all

    private var shownProviders: [Provider] {
        Provider.allCases.filter { provider in
            store.visibleProviders.contains(provider) && (filter.provider == nil || filter.provider == provider)
        }
    }
    private var lastSuccess: Date? {
        store.snapshots.values.map(\.lastSuccess).filter { $0 != .distantPast }.max()
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            Picker("Provider", selection: $filter) {
                ForEach(ProviderFilter.allCases) { item in Text(item.title).tag(item) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Filter providers")

            if shownProviders.isEmpty {
                ContentUnavailableView("No providers shown", systemImage: "eye.slash", description: Text("Enable Codex or Claude in Settings."))
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(shownProviders) { provider in
                            ProviderUsageCard(provider: provider) {
                                Task { await store.refresh(provider: provider) }
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(minHeight: 440, maxHeight: 720)
            }

            footer
        }
        .padding(16)
        .frame(width: 380)
        .frame(minHeight: 620)
        .background(UsageTheme.background)
        .task { if store.needsInitialRefreshOnOpen { await store.refresh() } }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(UsageTheme.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Usage").font(.system(size: 16, weight: .semibold))
                if store.isRefreshing {
                    Text("Updating usage…").font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryText)
                } else if let lastSuccess {
                    Text("Updated \(lastSuccess, style: .relative)").font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryText)
                } else {
                    Text("Waiting for first update").font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryText)
                }
            }
            Spacer(minLength: 8)
            Button { Task { await store.refresh() } } label: {
                Group {
                    if store.isRefreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .frame(width: 30, height: 30)
            }
            .buttonStyle(QuietIconButtonStyle())
            .help("Refresh now")
            .accessibilityLabel("Refresh usage now")
            .disabled(store.isRefreshing)

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            } label: {
                Image(systemName: "gearshape").frame(width: 30, height: 30)
            }
            .buttonStyle(QuietIconButtonStyle())
            .help("Settings")
            .accessibilityLabel("Open Settings")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Rectangle().fill(UsageTheme.separator).frame(height: 1)
        }
        .overlay {
            HStack {
                Text(store.refreshPolicy == .manual ? "Manual refresh" : "Auto refresh: \(store.refreshPolicy.title)")
                    .foregroundStyle(UsageTheme.secondaryText)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(UsageTheme.secondaryText)
                    .accessibilityLabel("Quit AI Usage Monitor")
            }
            .font(.system(size: 11))
            .padding(.top, 10)
        }
        .padding(.top, 3)
        .frame(height: 18)
    }
}

private struct ProviderUsageCard: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let provider: Provider
    let retry: () -> Void

    private var snapshot: UsageSnapshot? { store.snapshots[provider] }
    private var status: ProviderStatus { store.status(for: provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: provider.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(UsageTheme.provider(provider))
                    .frame(width: 28, height: 28)
                    .background(UsageTheme.provider(provider).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName).font(.system(size: 14, weight: .semibold))
                    if let account = snapshot?.account {
                        Text(account).font(.system(size: 10.5)).foregroundStyle(UsageTheme.secondaryText).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                ConnectionStatusView(status: status, isRefreshing: store.refreshing.contains(provider))
            }

            if let snapshot {
                if snapshot.windows.isEmpty {
                    emptyState(for: snapshot)
                } else {
                    VStack(spacing: 14) {
                        ForEach(snapshot.windows) { window in
                            UsageProgressRow(window: window, provider: provider)
                        }
                    }
                }
                if snapshot.isStale {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("Stale · \(snapshot.error ?? "Refresh failed")")
                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(UsageTheme.warning)
                }
                if snapshot.lastSuccess != .distantPast {
                    Text("Last successful update \(snapshot.lastSuccess, style: .relative)")
                        .font(.system(size: 10)).foregroundStyle(UsageTheme.mutedText)
                }
            } else if store.refreshing.contains(provider) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading usage…").font(.system(size: 12)).foregroundStyle(UsageTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } else {
                emptyState(for: nil)
            }
        }
        .padding(15)
        .background(UsageTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(UsageTheme.separator.opacity(0.8), lineWidth: 0.7))
    }

    @ViewBuilder private func emptyState(for snapshot: UsageSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let snapshot, let error = snapshot.error {
                Text(error).font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            } else if snapshot != nil {
                Text("Usage data unavailable").font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryText)
            } else {
                Text(status == .authenticationRequired ? "Sign in with the provider CLI, then refresh." : "Usage data has not been loaded yet.")
                    .font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryText)
            }
            Button("Retry") { retry() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.isRefreshing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UsageProgressRow: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let window: UsageWindow
    let provider: Provider

    private var usageColor: Color {
        guard let value = window.validUtilization else { return UsageTheme.mutedText }
        if value >= store.criticalThreshold { return UsageTheme.critical }
        if value >= store.warningThreshold { return UsageTheme.warning }
        return UsageTheme.provider(provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.system(size: 12, weight: .medium)).foregroundStyle(UsageTheme.primaryText)
                Spacer()
                if let amount = window.validUtilization {
                    Text("\(Int(amount.rounded()))%")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(usageColor)
                } else {
                    Text("Unavailable").font(.system(size: 10.5)).foregroundStyle(UsageTheme.mutedText)
                        .accessibilityLabel("Usage percentage unavailable because the source value is invalid")
                }
            }
            if let amount = window.validUtilization {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(UsageTheme.track)
                        Capsule().fill(usageColor).frame(width: geometry.size.width * amount / 100)
                    }
                }
                .frame(height: 7)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: amount)
                .accessibilityElement()
                .accessibilityLabel("\(window.label) used")
                .accessibilityValue("\(Int(amount.rounded())) percent")
            }
            if let detail = window.detail {
                Text(detail).font(.system(size: 10.5)).foregroundStyle(UsageTheme.secondaryText)
            }
            resetLabel
        }
    }

    @ViewBuilder private var resetLabel: some View {
        if let reset = window.resetsAt {
            if reset <= .now {
                Label("Reset passed · waiting for updated usage", systemImage: "clock")
                    .font(.system(size: 10.5)).foregroundStyle(UsageTheme.secondaryText)
            } else {
                Label("Resets \(reset, style: .relative)", systemImage: "clock")
                    .font(.system(size: 10.5)).foregroundStyle(UsageTheme.secondaryText)
                    .help("Resets on \(reset.formatted(date: .abbreviated, time: .shortened))")
            }
        } else {
            Label("Reset time unavailable", systemImage: "clock")
                .font(.system(size: 10.5)).foregroundStyle(UsageTheme.mutedText)
        }
    }
}

private struct ConnectionStatusView: View {
    let status: ProviderStatus
    let isRefreshing: Bool

    private var color: Color {
        if isRefreshing { return UsageTheme.codex }
        switch status {
        case .connected: return UsageTheme.codex
        case .authenticationRequired, .rateLimited: return UsageTheme.warning
        case .unavailable, .error: return UsageTheme.critical
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if isRefreshing { ProgressView().controlSize(.mini) }
            else { Circle().fill(color).frame(width: 6, height: 6) }
            Text(isRefreshing ? "Updating" : status.title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(UsageTheme.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct QuietIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(UsageTheme.secondaryText)
            .background(configuration.isPressed ? UsageTheme.elevated : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct SettingsWindowView: View {
    @Environment(UsageStore.self) private var store
    @State private var selection = "General"

    var body: some View {
        @Bindable var store = store
        TabView(selection: $selection) {
            generalSettings(store: $store)
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
                .tag("General")
            appearanceSettings(store: $store)
                .tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }
                .tag("Appearance")
            providerSettings
                .tabItem { Label("Providers", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag("Providers")
            aboutSettings
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag("About")
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 440, idealHeight: 500)
        .background(UsageTheme.background)
        .preferredColorScheme(store.colorSchemeOverride)
    }

    private func generalSettings(store: Bindable<UsageStore>) -> some View {
        Form {
            Section("Menu Bar") {
                Picker("Display", selection: store.menuBarMode) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                Text("Combined usage uses the highest valid percentage across enabled usage windows.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Refresh") {
                Picker("Automatic refresh", selection: store.refreshPolicy) {
                    ForEach(RefreshPolicy.allCases) { policy in Text(policy.title).tag(policy) }
                }
                Text(store.wrappedValue.refreshPolicy == .manual
                     ? "The app fetches once at startup; later refreshes require the Refresh button."
                     : "Cached usage stays visible while providers refresh independently.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Launch") {
                Toggle("Launch at login", isOn: Binding(
                    get: { store.wrappedValue.launchAtLoginEnabled },
                    set: { store.wrappedValue.setLaunchAtLogin($0) }
                ))
                if let error = store.wrappedValue.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(UsageTheme.warning)
                }
            }
            Section("Visible providers") {
                ForEach(Provider.allCases) { provider in
                    Toggle(provider.displayName, isOn: Binding(
                        get: { store.wrappedValue.visibleProviders.contains(provider) },
                        set: { enabled in
                            if enabled { store.wrappedValue.visibleProviders.insert(provider) }
                            else { store.wrappedValue.visibleProviders.remove(provider) }
                        }
                    ))
                }
            }
        }
        .formStyle(.grouped)
        .padding(18)
    }

    private func appearanceSettings(store: Bindable<UsageStore>) -> some View {
        Form {
            Section("Appearance") {
                Picker("Color scheme", selection: store.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }
            Section("Usage thresholds") {
                ThresholdSettingRow(label: "Warning", value: store.warningThreshold, range: 50...95, color: UsageTheme.warning)
                ThresholdSettingRow(label: "Critical", value: store.criticalThreshold, range: 70...100, color: UsageTheme.critical)
                Text("Threshold colors apply to valid usage values in cards and the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(18)
    }

    private var providerSettings: some View {
        Form {
            ForEach(Provider.allCases) { provider in
                Section(provider.displayName) {
                    LabeledContent("Status", value: store.status(for: provider).title)
                    if let snapshot = store.snapshots[provider] {
                        if let account = snapshot.account { LabeledContent("Account", value: account) }
                        if snapshot.lastSuccess != .distantPast {
                            LabeledContent("Last successful update", value: snapshot.lastSuccess.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let error = snapshot.error {
                            Text(error).font(.caption).foregroundStyle(UsageTheme.warning).textSelection(.enabled)
                        }
                    }
                    LabeledContent("Source", value: provider == .claude ? "Claude Code OAuth usage" : "Local Codex app-server")
                    HStack {
                        Text(provider == .claude
                             ? "Sign in with Claude Code to refresh. Credentials are read-only and never shown here."
                             : "Sign in with Codex CLI or the ChatGPT app. AI Usage Monitor does not read Codex auth files.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh") { Task { await store.refresh(provider: provider) } }
                            .disabled(store.refreshing.contains(provider))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(18)
    }

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "chart.bar.fill").font(.system(size: 30)).foregroundStyle(UsageTheme.secondaryText)
            Text("AI Usage Monitor").font(.title2.weight(.semibold))
            Text("A native menu bar utility for Claude Code and Codex usage.")
                .foregroundStyle(UsageTheme.secondaryText)
            Divider().overlay(UsageTheme.separator)
            Text("Claude usage uses the Claude Code OAuth usage endpoint. Codex usage comes from the local `codex app-server`. These provider interfaces can change.")
                .font(.callout).foregroundStyle(UsageTheme.secondaryText)
            Text("UI and integration references are MIT licensed: claude-usage-widget by bozdemir and codex-usage-bar by CMMUU.")
                .font(.caption).foregroundStyle(UsageTheme.mutedText)
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ThresholdSettingRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let color: Color

    var body: some View {
        HStack {
            Text(label).frame(width: 80, alignment: .leading)
            Slider(value: $value, in: range, step: 5).tint(color)
            Text("\(Int(value))%").monospacedDigit().frame(width: 45, alignment: .trailing)
        }
    }
}
