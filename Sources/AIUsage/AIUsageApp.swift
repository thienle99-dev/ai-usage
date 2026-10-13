import SwiftUI
import AppKit
import Darwin

@main struct AIUsageApp: App {
    @State private var store: UsageStore
    @StateObject private var updateManager: UpdateManager

    init() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if ["preflight", "run", "statusline", "quota", "report", "waste", "codex"].contains(arguments.first) {
            Darwin.exit(QuotaAwareCLI.run(arguments: arguments))
        }
        _store = State(initialValue: UsageStore())
        _updateManager = StateObject(wrappedValue: UpdateManager())
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePopover()
                .environment(store)
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
                .environmentObject(updateManager)
                .environment(\.locale, store.locale)
                .preferredColorScheme(store.colorSchemeOverride)
        }
        .defaultSize(width: 760, height: 560)
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

private struct ProviderIconNavigationView: View {
    @Binding var selection: Provider?
    let providers: [Provider]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedID: String { selection?.rawValue ?? "all" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ProviderNavigationItem(
                        title: "All",
                        accessibilityName: "All providers",
                        systemImage: "square.grid.2x2.fill",
                        accent: UsageTheme.primaryText,
                        isSelected: selection == nil
                    ) { selection = nil }
                    .id("all")

                    ForEach(providers) { provider in
                        ProviderNavigationItem(
                            title: provider.shortName,
                            accessibilityName: provider.displayName,
                            systemImage: provider.systemImage,
                            accent: UsageTheme.provider(provider),
                            isSelected: selection == provider
                        ) { selection = provider }
                        .id(provider.rawValue)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .frame(height: 58)
            .background(UsageTheme.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(UsageTheme.separator.opacity(0.75), lineWidth: 0.7))
            .onAppear { proxy.scrollTo(selectedID, anchor: .center) }
            .onChange(of: selection) { _, _ in
                if reduceMotion {
                    proxy.scrollTo(selectedID, anchor: .center)
                } else {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(selectedID, anchor: .center)
                    }
                }
            }
        }
        .accessibilityLabel("Provider navigation")
    }
}

private struct ProviderNavigationItem: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    let title: String
    let accessibilityName: String
    let systemImage: String
    let accent: Color
    let isSelected: Bool
    let action: () -> Void

    private var itemBackground: Color {
        if isSelected { return accent.opacity(0.12) }
        if isHovered { return UsageTheme.elevated.opacity(0.5) }
        return .clear
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? accent : UsageTheme.secondaryText)
                    .frame(width: 18, height: 18)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isSelected ? UsageTheme.primaryText : UsageTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: 50, height: 46)
            .background(itemBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isSelected)
        .help(accessibilityName)
        .accessibilityLabel(accessibilityName)
        .accessibilityHint("Filters the dashboard to \(accessibilityName)")
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct UsagePopover: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var quitHovered = false
    @State private var showLayoutPopover = false
    @AppStorage("overviewCardLayout") private var overviewCardLayoutRaw = UsageCardLayout.twoColumns.rawValue
    @AppStorage("detailCardLayout") private var detailCardLayoutRaw = UsageCardLayout.compactBalanced.rawValue
    @AppStorage("useUnifiedCardLayout") private var useUnifiedCardLayout = false
    @AppStorage("dashboardTheme") private var dashboardThemeRaw = DashboardTheme.darkMinimal.rawValue

    private var shownProviders: [Provider] {
        store.providerOrder.filter { provider in
            store.visibleProviders.contains(provider) && (store.selectedProvider == nil || store.selectedProvider == provider)
        }
    }
    var body: some View {
        VStack(spacing: 12) {
            header
            ProviderIconNavigationView(
                selection: Binding(
                    get: { store.selectedProvider },
                    set: { store.selectedProvider = $0 }
                ),
                providers: store.providerOrder.filter { store.visibleProviders.contains($0) }
            )

            if shownProviders.isEmpty {
                emptyProviderState
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(shownProviders) { provider in
                            providerCard(provider)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxHeight: .infinity)
            }

            footer
        }
        .padding(16)
        .frame(width: 380, height: 620, alignment: .top)
        .background(UsageTheme.background)
        .accessibilityIdentifier("dashboard-theme-\(dashboardThemeRaw)")
        .task { if store.needsInitialRefreshOnOpen { await store.refresh() } }
    }

    @ViewBuilder
    private func providerCard(_ provider: Provider) -> some View {
        let card = ProviderUsageCard(
            provider: provider,
            layout: activeLayout,
            retry: { Task { await store.refresh(provider: provider) } },
            manageAccounts: { presentSettingsWindow(tab: "Providers") }
        )
        if store.selectedProvider == nil {
            card
                .draggable(provider.rawValue)
                .dropDestination(for: String.self) { values, _ in
                    guard let rawValue = values.first,
                          let movingProvider = Provider(rawValue: rawValue),
                          movingProvider != provider else { return false }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        store.moveProvider(movingProvider, before: provider)
                    }
                    return true
                }
                .help("Drag to reorder provider cards")
        } else {
            card
        }
    }

    private var activeLayout: UsageCardLayout {
        if useUnifiedCardLayout {
            return UsageCardLayout.preference(overviewCardLayoutRaw, fallback: .twoColumns)
        }
        return store.selectedProvider == nil
            ? UsageCardLayout.preference(overviewCardLayoutRaw, fallback: .twoColumns)
            : UsageCardLayout.preference(detailCardLayoutRaw, fallback: .compactBalanced)
    }

    private var emptyProviderState: some View {
        let selected = store.selectedProvider
        let unsupported = selected.map { !$0.isUsageSupported } ?? false
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: unsupported ? (selected?.systemImage ?? "questionmark.circle") : "eye.slash")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(unsupported ? UsageTheme.provider(selected ?? .codex) : UsageTheme.mutedText)
                    .frame(width: 34, height: 34)
                    .background(UsageTheme.elevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(unsupported ? "\(selected?.displayName ?? "Provider") not integrated" : "No providers shown")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(UsageTheme.primaryText)
                    Text(unsupported ? "Usage tracking is unavailable for this provider." : "Enable a provider in Settings.")
                        .font(.system(size: 11))
                        .foregroundStyle(UsageTheme.secondaryText)
                }
                Spacer(minLength: 4)
                Text(unsupported ? "UNAVAILABLE" : "HIDDEN")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(UsageTheme.mutedText)
            }
            Rectangle().fill(UsageTheme.separator).frame(height: 1)
            if unsupported {
                Text("This provider is listed in navigation, but it does not have a usage data source connected yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(UsageTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Show all providers") { store.selectedProvider = nil }
                    .buttonStyle(.borderless)
            } else {
                Spacer(minLength: 0)
                Button("Open Settings…") {
                    presentSettingsWindow()
                }
                .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .background(UsageTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UsageTheme.secondaryText)
                .frame(width: 23, height: 23)
                .background(UsageTheme.elevated.opacity(0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text("AI Usage")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(UsageTheme.primaryText)
                .fixedSize()
            Spacer(minLength: 4)
            Button { Task { await store.refresh() } } label: {
                Group {
                    if store.isRefreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .frame(width: 26, height: 26)
            }
            .buttonStyle(QuietIconButtonStyle())
            .help("Refresh now")
            .accessibilityLabel("Refresh usage now")
            .disabled(store.isRefreshing)

            appearanceToggleButton

            Button {
                presentSettingsWindow()
            } label: {
                Image(systemName: "gearshape").frame(width: 26, height: 26)
            }
            .buttonStyle(QuietIconButtonStyle())
            .help("Settings")
            .accessibilityLabel("Open Settings")

            Button { showLayoutPopover.toggle() } label: {
                Image(systemName: layoutSymbol(activeLayout))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(QuietIconButtonStyle())
            .help("Card layout")
            .accessibilityLabel("Choose card layout")
            .popover(isPresented: $showLayoutPopover, arrowEdge: .bottom) {
                layoutPopover
            }
        }
    }

    private var layoutPopover: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(store.selectedProvider == nil ? "Overview Layout" : "Provider Detail Layout")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(UsageTheme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.top, 4)
            ForEach(UsageCardLayout.allCases) { layout in
                Button {
                    if useUnifiedCardLayout || store.selectedProvider == nil {
                        overviewCardLayoutRaw = layout.rawValue
                    } else {
                        detailCardLayoutRaw = layout.rawValue
                    }
                    showLayoutPopover = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: layoutSymbol(layout))
                            .frame(width: 16)
                        Text(layout.title)
                        Spacer(minLength: 8)
                        if activeLayout == layout {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(activeLayout == layout ? UsageTheme.primaryText : UsageTheme.secondaryText)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .background(activeLayout == layout ? UsageTheme.elevated : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityAddTraits(activeLayout == layout ? .isSelected : [])
            }
            Rectangle().fill(UsageTheme.separator).frame(height: 1).padding(.vertical, 3)
            Text("Status Item Provider")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(UsageTheme.secondaryText)
                .padding(.horizontal, 8)
            ForEach(MenuBarDisplayMode.quickSwitchSources) { source in
                Button {
                    store.menuBarMode = source
                    showLayoutPopover = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: source == .currentProvider ? "person.crop.circle" : source == .highestUsageProvider ? "chart.bar.fill" : "macwindow")
                            .frame(width: 16)
                        Text(source.title)
                        Spacer(minLength: 8)
                        if store.menuBarMode == source {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(store.menuBarMode == source ? UsageTheme.primaryText : UsageTheme.secondaryText)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .background(store.menuBarMode == source ? UsageTheme.elevated : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityAddTraits(store.menuBarMode == source ? .isSelected : [])
            }
            Rectangle().fill(UsageTheme.separator).frame(height: 1).padding(.vertical, 3)
            Button("Token & Cost Report…") {
                showLayoutPopover = false
                openWindow(id: "usage-report")
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(height: 26, alignment: .leading)
            Button("Customize in Settings…") {
                showLayoutPopover = false
                presentSettingsWindow()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(height: 26, alignment: .leading)
            .padding(.bottom, 3)
        }
        .padding(7)
        .frame(width: 230)
        .background(UsageTheme.card)
    }

    private var appearanceToggleButton: some View {
        let isDark = isCurrentlyDark
        let destination = isDark ? "Light" : "Dark"
        return Button {
            store.appearance = isDark ? "light" : "dark"
        } label: {
            Image(systemName: isDark ? "moon" : "sun.max")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(UsageTheme.secondaryText)
                .frame(width: 24, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(QuietIconButtonStyle())
        .help("Switch to \(destination) appearance")
        .accessibilityLabel("Switch to \(destination.lowercased()) appearance")
    }

    private var isCurrentlyDark: Bool {
        switch store.appearance {
        case "dark": true
        case "light": false
        default: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    private func layoutSymbol(_ layout: UsageCardLayout) -> String {
        switch layout {
        case .compactBalanced: "rectangle.grid.1x2"
        case .twoColumns: "rectangle.split.2x1"
        case .minimalRows: "list.bullet"
        case .collapsible: "rectangle.compress.vertical"
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Rectangle().fill(UsageTheme.separator).frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "clock")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(UsageTheme.mutedText)
                    if store.refreshPolicy == .manual {
                        Text("Manual refresh")
                            .foregroundStyle(UsageTheme.secondaryText)
                    } else {
                        Text("Auto refresh")
                            .foregroundStyle(UsageTheme.secondaryText)
                        Text(store.refreshPolicy.title)
                            .foregroundStyle(UsageTheme.primaryText)
                    }
                }
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    Circle()
                        .fill(store.lastRefreshAttempt == nil ? UsageTheme.mutedText : UsageTheme.codex)
                        .frame(width: 4, height: 4)
                    Text(store.lastRefreshAttempt.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "Not refreshed")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(UsageTheme.secondaryText)
                        .lineLimit(1)
                        .fixedSize()
                }
                .accessibilityLabel(store.lastRefreshAttempt.map { "Last updated at \($0.formatted(date: .omitted, time: .shortened))" } ?? "Usage has not been refreshed")
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                Button { NSApp.terminate(nil) } label: {
                    Label("Quit", systemImage: "power")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(UsageTheme.secondaryText)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(quitHovered ? UsageTheme.elevated : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .onHover { quitHovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: quitHovered)
                .accessibilityLabel("Quit AI Usage Monitor")
            }
        }
        .padding(.top, 2)
    }

    private func presentSettingsWindow(tab: String = "General") {
        UserDefaults.standard.set(tab, forKey: "settingsSelectedTab")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
            guard let window = NSApp.windows.first(where: { $0.title == "Settings" }) else { return }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }
}

private struct ProviderUsageCard: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("providerCardExpansion") private var expansionOverrides = ""
    @AppStorage("collapsibleInitiallyExpanded") private var initiallyExpanded = false
    let provider: Provider
    let layout: UsageCardLayout
    let retry: () -> Void
    let manageAccounts: () -> Void

    private var snapshot: UsageSnapshot? { store.snapshots[provider] }
    private var status: ProviderStatus { store.status(for: provider) }
    private var isExpanded: Bool {
        let overrides = Dictionary(uniqueKeysWithValues: expansionOverrides.split(separator: ",").compactMap { entry -> (String, Bool)? in
            let parts = entry.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), parts[1] == "1")
        })
        return overrides[provider.rawValue] ?? initiallyExpanded
    }
    private var primaryWindow: UsageWindow? {
        // Provider window order is authoritative; choose its first valid metric for the collapsed summary.
        snapshot?.windows.first(where: { $0.validUtilization != nil }) ?? snapshot?.windows.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if layout == .collapsible {
                HStack(spacing: 7) {
                    Button { toggleExpanded() } label: {
                    HStack(spacing: 8) {
                        providerIdentity
                        ConnectionStatusView(status: status, isRefreshing: store.refreshing.contains(provider))
                        Spacer(minLength: 3)
                        if let primaryWindow, let amount = primaryWindow.validUtilization {
                            Text("\(Int(amount.rounded()))%")
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .foregroundStyle(usageColor(for: primaryWindow))
                        }
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(UsageTheme.mutedText)
                    }
                    .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(provider.displayName), \(isExpanded ? "expanded" : "collapsed")")
                    .accessibilityHint("Toggles usage details")
                    if provider == .codex {
                        codexAccountSwitcher
                    } else if provider == .antigravity {
                        antigravityAccountSwitcher
                    }
                }
                if snapshot?.windows.isEmpty == true {
                    emptyState(for: snapshot)
                } else if isExpanded {
                    metricContent(for: .compactBalanced)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if let primaryWindow {
                    UsageProgressRow(window: primaryWindow, provider: provider, presentation: .collapsed)
                }
            } else {
                providerHeader
                metricContent(for: layout)
            }

            ForEach(store.publicServiceIncidents[provider] ?? []) { incident in
                ServiceIncidentNotice(incident: incident)
            }

            if provider == .codex, let error = store.codexSwitchError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(UsageTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let snapshot, snapshot.isStale {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Local fetch failed · \(snapshot.error ?? "Refresh failed")")
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 10.5)).foregroundStyle(UsageTheme.warning)
            }
        }
        .padding(layout == .minimalRows ? 11 : 12)
        .background(UsageTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(UsageTheme.separator.opacity(0.8), lineWidth: 0.7))
    }

    private var providerHeader: some View {
        HStack(spacing: 9) {
            providerIdentity
            Spacer(minLength: 4)
            ConnectionStatusView(status: status, isRefreshing: store.refreshing.contains(provider))
            if provider == .codex {
                codexAccountSwitcher
            } else if provider == .antigravity {
                antigravityAccountSwitcher
            }
        }
    }

    private var providerIdentity: some View {
        HStack(spacing: 9) {
            Image(systemName: provider.systemImage)
                .font(.system(size: layout == .minimalRows ? 12 : 13, weight: .semibold))
                .foregroundStyle(UsageTheme.provider(provider))
                .frame(width: layout == .minimalRows ? 24 : 28, height: layout == .minimalRows ? 24 : 28)
                .background(UsageTheme.provider(provider).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName).font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                if let account = snapshot?.account {
                    Text(account).font(.system(size: 10.5)).foregroundStyle(UsageTheme.secondaryText).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    private var codexAccountSwitcher: some View {
        let isBusy = store.codexSwitchInFlight || store.refreshing.contains(.codex)
        let canIdentifyActiveHome = store.codexHomes.contains(where: store.isCodexHomeActive)
        let activeHome = store.codexHomes.first(where: store.isCodexHomeActive)
        let currentIdentity = activeHome.map(store.codexHomeDisplayName) ?? snapshot?.account ?? "Current Codex account"

        return Menu {
            Button {} label: {
                Label("Current · \(currentIdentity)", systemImage: "checkmark")
            }
            .disabled(true)
            Divider()

            if store.codexHomes.isEmpty {
                Button("Add account folders in Settings…", action: manageAccounts)
            } else if !canIdentifyActiveHome {
                Button("Current home must be registered in Settings") {}.disabled(true)
                ForEach(store.codexHomes) { home in
                    Button(store.codexHomeDisplayName(home)) {}.disabled(true)
                }
            } else {
                ForEach(store.codexHomes.filter { !store.isCodexHomeActive($0) }) { home in
                    Button {
                        Task { await store.switchCodexAccount(to: home) }
                    } label: {
                        HStack(spacing: 5) {
                            Text(store.codexHomeDisplayName(home))
                            if store.isCodexSlotEmpty(home) {
                                Text("Empty").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(isBusy || (store.isCodexSlotEmpty(home) && !store.isCodexDefaultHomeSlot(home)))
                }
                if store.codexHomes.allSatisfy(store.isCodexHomeActive) {
                    Button("No other registered accounts") {}.disabled(true)
                }
            }
            Divider()
            Button("Manage Accounts…", action: manageAccounts)
        } label: {
            HStack(spacing: 3) {
                if store.codexSwitchInFlight {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "person.crop.circle")
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(UsageTheme.secondaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isBusy)
        .help("Switch Codex account")
        .accessibilityLabel("Switch Codex account")
        .accessibilityHint("Choose a registered Codex home or manage accounts in Settings")
    }

    private var antigravityAccountSwitcher: some View {
        let isBusy = store.antigravityAccountSwitchInFlight || store.refreshing.contains(.antigravity)
        let activeAccount = store.antigravityAccounts.first { $0.id == store.activeAntigravityAccountID }
        let currentIdentity = activeAccount?.displayName ?? snapshot?.account ?? String(localized: "Antigravity CLI/App sign-in")

        return Menu {
            Button {} label: {
                Label("Current · \(currentIdentity)", systemImage: "checkmark")
            }
            .disabled(true)
            Divider()

            if store.activeAntigravityAccountID != nil {
                Button("Use Antigravity CLI/App sign-in") {
                    Task { await store.switchAntigravityAccount(to: nil) }
                }
                .disabled(isBusy)
            }
            ForEach(store.antigravityAccounts) { account in
                if account.id != store.activeAntigravityAccountID {
                    Button(account.displayName) {
                        Task { await store.switchAntigravityAccount(to: account.id) }
                    }
                    .disabled(isBusy)
                }
            }
            if store.antigravityAccounts.isEmpty {
                Button("Save current account in Settings…", action: manageAccounts)
            } else {
                Divider()
                Button("Manage Accounts…", action: manageAccounts)
            }
        } label: {
            HStack(spacing: 3) {
                if store.antigravityAccountSwitchInFlight {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "person.crop.circle")
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(UsageTheme.secondaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isBusy)
        .help("Switch Antigravity account")
        .accessibilityLabel("Switch Antigravity account")
        .accessibilityHint("Choose a saved account or manage accounts in Settings")
    }

    @ViewBuilder private func metricContent(for layout: UsageCardLayout) -> some View {
        if let snapshot {
            if snapshot.windows.isEmpty {
                emptyState(for: snapshot)
            } else {
                switch layout {
                case .compactBalanced:
                    VStack(spacing: 11) {
                        ForEach(snapshot.windows) { window in UsageProgressRow(window: window, provider: provider) }
                    }
                case .twoColumns:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(snapshot.windows) { window in
                            UsageProgressRow(window: window, provider: provider, presentation: .tile)
                        }
                    }
                case .minimalRows:
                    VStack(spacing: 5) {
                        ForEach(snapshot.windows) { window in UsageProgressRow(window: window, provider: provider, presentation: .minimal) }
                    }
                case .collapsible:
                    VStack(spacing: 11) {
                        ForEach(snapshot.windows) { window in UsageProgressRow(window: window, provider: provider) }
                    }
                }
            }
        } else if store.refreshing.contains(provider) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading usage…").font(.system(size: 12)).foregroundStyle(UsageTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
        } else {
            emptyState(for: nil)
        }
    }

    private func usageColor(for window: UsageWindow) -> Color {
        guard let value = window.validUtilization else { return UsageTheme.mutedText }
        if value >= store.criticalThreshold { return UsageTheme.critical }
        if value >= store.warningThreshold { return UsageTheme.warning }
        return UsageTheme.provider(provider)
    }

    private func toggleExpanded() {
        var overrides = Dictionary(uniqueKeysWithValues: expansionOverrides.split(separator: ",").compactMap { entry -> (String, Bool)? in
            let parts = entry.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), parts[1] == "1")
        })
        overrides[provider.rawValue] = !isExpanded
        expansionOverrides = overrides.keys.sorted().map { "\($0)=\(overrides[$0] == true ? 1 : 0)" }.joined(separator: ",")
    }

    @ViewBuilder private func emptyState(for snapshot: UsageSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let snapshot, let error = snapshot.error {
                Text("Local usage fetch failed · \(error)")
                    .font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
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

private enum UsageMetricPresentation {
    case balanced, tile, minimal, collapsed
}

private struct UsageProgressRow: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let window: UsageWindow
    let provider: Provider
    var presentation: UsageMetricPresentation = .balanced

    private var usageColor: Color {
        guard let value = window.validUtilization else { return UsageTheme.mutedText }
        if value >= store.criticalThreshold { return UsageTheme.critical }
        if value >= store.warningThreshold { return UsageTheme.warning }
        return UsageTheme.provider(provider)
    }

    var body: some View {
        Group {
            switch presentation {
            case .balanced:
                VStack(alignment: .leading, spacing: 4) {
                    metricHeading(showReset: true)
                    progressBar(height: 6)
                    if let detail = window.detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(UsageTheme.secondaryText) }
                }
            case .tile:
                VStack(alignment: .leading, spacing: 7) {
                    metricHeading(showReset: false)
                    progressBar(height: 5)
                    resetLabel
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(UsageTheme.elevated.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityElement(children: .contain)
            case .minimal:
                HStack(spacing: 7) {
                    Text(shortWindowLabel)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(UsageTheme.primaryText)
                        .lineLimit(1)
                        .help("\(window.label) · \(exactReset)")
                    progressBar(height: 5)
                        .frame(maxWidth: .infinity)
                        .layoutPriority(1)
                    percentage(minimal: true)
                        .frame(minWidth: 34, alignment: .trailing)
                    compactResetText
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(UsageTheme.secondaryText)
                        .lineLimit(1)
                        .frame(minWidth: 42, alignment: .trailing)
                        .help(exactReset)
                        .accessibilityLabel("\(window.label), \(exactReset)")
                }
                .frame(minHeight: 24)
                .accessibilityElement(children: .combine)
            case .collapsed:
                HStack(spacing: 7) {
                    Text(window.label).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                    progressBar(height: 5)
                    compactResetView
                }
                .foregroundStyle(UsageTheme.secondaryText)
            }
        }
    }

    @ViewBuilder private func metricHeading(showReset: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(window.label).font(.system(size: 12, weight: .medium)).foregroundStyle(UsageTheme.primaryText).lineLimit(1)
            Spacer(minLength: 2)
            if showReset { compactResetView }
            percentage()
        }
    }

    @ViewBuilder private func percentage(minimal: Bool = false) -> some View {
        if let amount = window.validUtilization {
            Text("\(Int(amount.rounded()))%")
                .font(.system(size: minimal ? 11 : 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(usageColor)
                .accessibilityLabel("\(Int(amount.rounded())) percent used")
        } else {
            Text("Unavailable").font(.system(size: 10, weight: .medium)).foregroundStyle(UsageTheme.mutedText)
                .accessibilityLabel("Usage percentage unavailable because the source value is invalid")
        }
    }

    @ViewBuilder private func progressBar(height: CGFloat) -> some View {
        if let amount = window.validUtilization {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(UsageTheme.track)
                    Capsule().fill(usageColor).frame(width: geometry.size.width * amount / 100)
                }
            }
            .frame(height: height)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: amount)
            .accessibilityElement()
            .accessibilityLabel("\(window.label) used")
            .accessibilityValue("\(Int(amount.rounded())) percent")
        } else {
            Text("Usage unavailable")
                .font(.system(size: 10)).foregroundStyle(UsageTheme.mutedText)
        }
    }

    private var shortWindowLabel: String {
        switch window.label.lowercased() {
        case "5-hour limit": "5h"
        case "weekly limit": "7d"
        case "monthly limit": "30d"
        default: window.label
        }
    }

    private var exactReset: String {
        guard let reset = window.resetsAt else { return "Reset time unavailable" }
        return reset <= .now ? "Reset passed" : "Resets on \(reset.formatted(date: .abbreviated, time: .shortened))"
    }

    private var compactReset: String {
        guard let reset = window.resetsAt else { return "—" }
        let seconds = max(0, Int(reset.timeIntervalSinceNow))
        guard seconds > 0 else { return "now" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(max(minutes, 1))m"
    }

    private var compactResetView: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 8, weight: .medium))
            compactResetText
                .font(.system(size: 10, weight: .medium).monospacedDigit())
        }
        .foregroundStyle(window.resetsAt == nil ? UsageTheme.mutedText : UsageTheme.secondaryText)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .help(exactReset)
        .accessibilityLabel(exactReset)
    }

    private var compactResetText: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            Text(compactReset)
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

struct QuietIconButtonStyle: ButtonStyle {
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
