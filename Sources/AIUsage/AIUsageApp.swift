import SwiftUI
import AppKit
import Darwin

@main struct AIUsageApp: App {
    @State private var store: UsageStore
    @State private var accountLogin: AccountLoginCoordinator
    @StateObject private var updateManager: UpdateManager

    init() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if ["preflight", "run", "statusline", "quota", "report", "waste", "codex"].contains(arguments.first) {
            Darwin.exit(QuotaAwareCLI.run(arguments: arguments))
        }
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let applicationIcon = NSImage(contentsOf: iconURL) {
            // Sparkle reads NSApplicationIcon for its update progress window.
            // Menu bar apps otherwise leave AppKit's generic placeholder there.
            NSApplication.shared.applicationIconImage = applicationIcon
        }
        let store = UsageStore()
        _store = State(initialValue: store)
        _accountLogin = State(initialValue: AccountLoginCoordinator(store: store))
        _updateManager = StateObject(wrappedValue: UpdateManager())
    }

    var body: some Scene {
        MenuBarExtra {
            CompactPopoverView()
                .environment(store)
                .environment(accountLogin)
                .environmentObject(updateManager)
                .environment(\.locale, store.locale)
                .preferredColorScheme(store.colorSchemeOverride)
        } label: {
            MenuBarStatusView(store: store)
                .environment(\.locale, store.locale)
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsWindowView()
                .environment(store)
                .environment(accountLogin)
                .environmentObject(updateManager)
                .environment(\.locale, store.locale)
                .preferredColorScheme(store.colorSchemeOverride)
        }
        .defaultSize(width: 760, height: 560)
        .windowResizability(.contentSize)

        Window("Add Account", id: "add-account") {
            AddAccountWindowView()
                .environment(store)
                .environment(accountLogin)
                .environment(\.locale, store.locale)
                .preferredColorScheme(store.colorSchemeOverride)
        }
        .defaultSize(width: 440, height: 340)
        .windowResizability(.contentSize)

        Window("Token & Cost Report", id: "usage-report") {
            UsageReportView()
                .environment(\.locale, store.locale)
                .preferredColorScheme(store.colorSchemeOverride)
        }
        .defaultSize(width: 880, height: 680)
    }
}

private struct MenuBarStatusView: View {
    let store: UsageStore
    @State private var frontmostAppProvider: Provider?

    private var text: String {
        MenuBarContent.text(
            mode: store.menuBarMode,
            selectedProvider: store.menuBarProvider,
            snapshots: store.snapshots,
            enabled: store.visibleProviders,
            criticalThreshold: store.criticalThreshold,
            currentProvider: store.selectedProvider,
            frontmostAppProvider: frontmostAppProvider
        )
    }
    private var symbol: String {
        MenuBarContent.symbolName(
            mode: store.menuBarMode,
            selectedProvider: store.menuBarProvider,
            snapshots: store.snapshots,
            enabled: store.visibleProviders,
            criticalThreshold: store.criticalThreshold,
            currentProvider: store.selectedProvider,
            frontmostAppProvider: frontmostAppProvider
        )
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
        .onAppear(perform: updateFrontmostApplication)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                frontmostAppProvider = nil
                return
            }
            setFrontmostProvider(from: application)
        }
    }

    private func updateFrontmostApplication() {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            frontmostAppProvider = nil
            return
        }
        setFrontmostProvider(from: application)
    }

    private func setFrontmostProvider(from application: NSRunningApplication) {
        frontmostAppProvider = FrontmostApplicationProvider.provider(
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName,
            processName: application.executableURL?.lastPathComponent
        )
    }
}

struct ConnectionStatusView: View {
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

struct ServiceIncidentNotice: View {
    let incident: ServiceIncident

    private var tint: Color {
        switch incident.impact.lowercased() {
        case "critical", "outage", "service outage": UsageTheme.critical
        case "major", "service disruption": UsageTheme.warning
        default: UsageTheme.warning
        }
    }

    var body: some View {
        Link(destination: incident.url) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Service incident · \(incident.title)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(tint)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("Public status page · \(incident.status)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(UsageTheme.secondaryText)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(UsageTheme.mutedText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Service incident: \(incident.title). Status: \(incident.status). Open public status page.")
    }
}

struct SettingsWindowView: View {
    @Environment(UsageStore.self) private var store
    @AppStorage("settingsSelectedTab") private var selection = "General"

    var body: some View {
        @Bindable var store = store
        let category = SettingsCategory(rawValue: selection) ?? .general
        NavigationSplitView {
            SettingsSidebarView(selection: $selection)
        } detail: {
            ScrollView {
                switch category {
                case .appearance:
                    AppearanceSettingsView(store: $store)
                case .accounts:
                    AccountsSettingsView()
                case .providers:
                    ProvidersSettingsView()
                case .about:
                    AboutSettingsView()
                case .general, .menuBar, .integrations:
                    GeneralSettingsView(store: $store, category: category)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 480, idealHeight: 560)
        .background(UsageTheme.background)
        .preferredColorScheme(store.colorSchemeOverride)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
