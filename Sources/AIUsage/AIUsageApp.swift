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
            providerUsage.map { "\($0.0.menuBarAbbreviation) \(Int($0.1.rounded()))%" }.joined(separator: " · ")
        case .criticalProviderOnly:
            criticalProviders.map(\.menuBarAbbreviation).joined(separator: " · ")
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
    @AppStorage("overviewCardLayout") private var overviewCardLayoutRaw = UsageCardLayout.twoColumns.rawValue
    @AppStorage("detailCardLayout") private var detailCardLayoutRaw = UsageCardLayout.compactBalanced.rawValue
    @AppStorage("useUnifiedCardLayout") private var useUnifiedCardLayout = false

    private var shownProviders: [Provider] {
        Provider.supported.filter { provider in
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
                providers: Provider.supported.filter { store.visibleProviders.contains($0) }
            )

            if shownProviders.isEmpty {
                emptyProviderState
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(shownProviders) { provider in
                            ProviderUsageCard(provider: provider, layout: activeLayout) {
                                Task { await store.refresh(provider: provider) }
                            }
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
        .task { if store.needsInitialRefreshOnOpen { await store.refresh() } }
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
        HStack(spacing: 9) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(UsageTheme.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Usage").font(.system(size: 16, weight: .semibold))
                if let lastRefresh = store.lastRefreshAttempt {
                    Text("Updated at \(lastRefresh.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryText)
                } else {
                    Text("Not refreshed yet").font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryText)
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
                presentSettingsWindow()
            } label: {
                Image(systemName: "gearshape").frame(width: 30, height: 30)
            }
            .buttonStyle(QuietIconButtonStyle())
            .help("Settings")
            .accessibilityLabel("Open Settings")

            Menu {
                Section(store.selectedProvider == nil ? "Overview Layout" : "Provider Detail Layout") {
                    ForEach(UsageCardLayout.allCases) { layout in
                        Button {
                            if useUnifiedCardLayout || store.selectedProvider == nil {
                                overviewCardLayoutRaw = layout.rawValue
                            } else {
                                detailCardLayoutRaw = layout.rawValue
                            }
                        } label: {
                            if activeLayout == layout { Label(layout.title, systemImage: "checkmark") }
                            else { Text(layout.title) }
                        }
                    }
                }
                Divider()
                Button("Customize in Settings…") { presentSettingsWindow() }
            } label: {
                Image(systemName: "rectangle.grid.2x2")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(QuietIconButtonStyle())
            .help("Card layout")
            .accessibilityLabel("Choose card layout")
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Rectangle().fill(UsageTheme.separator).frame(height: 1)
            HStack {
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
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    Label("Quit", systemImage: "power")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(UsageTheme.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(quitHovered ? UsageTheme.elevated : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .onHover { quitHovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: quitHovered)
                    .accessibilityLabel("Quit AI Usage Monitor")
            }
            .font(.system(size: 11))
            .frame(height: 28)
        }
        .padding(.top, 2)
    }

    private func presentSettingsWindow() {
        openWindow(id: "settings")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.title == "Settings" })?.makeKeyAndOrderFront(nil)
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
                Button { toggleExpanded() } label: {
                    HStack(spacing: 8) {
                        providerHeader
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

            if let snapshot, snapshot.isStale {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Stale · \(snapshot.error ?? "Refresh failed")")
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
            Spacer(minLength: 4)
            ConnectionStatusView(status: status, isRefreshing: store.refreshing.contains(provider))
        }
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
    @State private var cursorCookieHeader = ""
    @State private var cursorCredentialMessage: String?
    @State private var cursorHasStoredCookie = CursorCredentialVault.hasStoredCookie
    @State private var openCodeCookieHeader = ""
    @State private var openCodeCredentialMessage: String?
    @State private var openCodeHasStoredCookie = OpenCodeCredentialVault.hasStoredCookie
    @State private var codexHomeMessage: String?

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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsCard(title: "Menu Bar") {
                    HStack {
                        Text("Display")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(UsageTheme.primaryText)
                        Spacer()
                        Picker("", selection: store.menuBarMode) {
                            ForEach(MenuBarDisplayMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    .padding(.bottom, 8)
                    SettingCaption(text: "Combined usage uses the highest valid percentage across enabled usage windows.")
                }
                SettingsCard(title: "Refresh") {
                    HStack {
                        Text("Automatic refresh")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(UsageTheme.primaryText)
                        Spacer()
                        Picker("", selection: store.refreshPolicy) {
                            ForEach(RefreshPolicy.allCases) { policy in Text(policy.title).tag(policy) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    .padding(.bottom, 8)
                    SettingCaption(text: store.wrappedValue.refreshPolicy == .manual
                        ? "The app fetches once at startup; later refreshes require the Refresh button."
                        : "Cached usage stays visible while providers refresh independently.")
                }
                SettingsCard(title: "Auto-start 5-hour session") {
                    HStack(spacing: 10) {
                        SettingsIconTile(systemImage: "arrow.clockwise.circle", foreground: UsageTheme.warning, background: UsageTheme.warning.opacity(0.12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start a new window after reset")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(UsageTheme.primaryText)
                            Text("Sends a short request with Claude Code, Codex, or Antigravity CLI and uses a small amount of quota.")
                                .font(.system(size: 11))
                                .foregroundStyle(UsageTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Toggle("Auto-start 5-hour session", isOn: Binding(
                            get: { store.wrappedValue.autoStartUsageWindow },
                            set: { store.wrappedValue.autoStartUsageWindow = $0 }
                        ))
                        .labelsHidden()
                    }
                    SettingCaption(text: "Off by default. Runs only after a provider reports its 5-hour window has reset. Providers without a reliable reset signal are skipped.")
                        .padding(.top, 6)
                }
                SettingsCard(title: "Launch") {
                    HStack(spacing: 10) {
                        SettingsIconTile(systemImage: "power", foreground: UsageTheme.secondaryText, background: UsageTheme.elevated)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Launch at login")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(UsageTheme.primaryText)
                            Text("Open AI Usage Monitor when you log in.")
                                .font(.system(size: 11))
                                .foregroundStyle(UsageTheme.secondaryText)
                        }
                        Spacer()
                        Toggle("Launch at login", isOn: Binding(
                            get: { store.wrappedValue.launchAtLoginEnabled },
                            set: { store.wrappedValue.setLaunchAtLogin($0) }
                        ))
                        .labelsHidden()
                    }
                    if let error = store.wrappedValue.launchAtLoginError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(UsageTheme.warning)
                            .padding(.top, 8)
                    }
                }
                SettingsCard(title: "Visible providers") {
                    ForEach(Array(Provider.supported.enumerated()), id: \.element.id) { index, provider in
                        if index > 0 { SettingsDivider().padding(.leading, 38) }
                        HStack(spacing: 10) {
                            SettingsIconTile(
                                systemImage: provider.systemImage,
                                foreground: UsageTheme.provider(provider),
                                background: UsageTheme.provider(provider).opacity(0.12)
                            )
                            VStack(alignment: .leading, spacing: 1) {
                                Text(provider.displayName)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(UsageTheme.primaryText)
                                Text(providerSource(provider))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(UsageTheme.secondaryText)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            ConnectionStatusView(
                                status: store.wrappedValue.status(for: provider),
                                isRefreshing: store.wrappedValue.refreshing.contains(provider)
                            )
                            Toggle(provider.displayName, isOn: Binding(
                                get: { store.wrappedValue.visibleProviders.contains(provider) },
                                set: { enabled in
                                    if enabled { store.wrappedValue.visibleProviders.insert(provider) }
                                    else {
                                        store.wrappedValue.visibleProviders.remove(provider)
                                        if store.wrappedValue.selectedProvider == provider {
                                            store.wrappedValue.selectedProvider = nil
                                        }
                                    }
                                }
                            ))
                            .labelsHidden()
                        }
                        .padding(.vertical, 7)
                    }
                }
            }
            .padding(20)
        }
    }

    private func appearanceSettings(store: Bindable<UsageStore>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsCard(title: "Appearance") {
                    HStack {
                        Text("Color scheme")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(UsageTheme.primaryText)
                        Spacer()
                        Picker("", selection: store.appearance) {
                            Text("System").tag("system")
                            Text("Light").tag("light")
                            Text("Dark").tag("dark")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 220)
                    }
                }
                SettingsCard(title: "Usage thresholds") {
                    ThresholdSettingRow(label: "Warning", value: store.warningThreshold, range: 50...95, color: UsageTheme.warning)
                    SettingsDivider().padding(.vertical, 10)
                    ThresholdSettingRow(label: "Critical", value: store.criticalThreshold, range: 70...100, color: UsageTheme.critical)
                    SettingCaption(text: "Threshold colors apply to valid usage values in cards and the menu bar.")
                        .padding(.top, 8)
                }
                UsageCardLayoutSettings()
            }
            .padding(20)
        }
        .onChange(of: store.wrappedValue.warningThreshold) {
            if store.wrappedValue.warningThreshold >= store.wrappedValue.criticalThreshold {
                store.wrappedValue.criticalThreshold = min(100, store.wrappedValue.warningThreshold + 5)
            }
        }
        .onChange(of: store.wrappedValue.criticalThreshold) {
            if store.wrappedValue.criticalThreshold <= store.wrappedValue.warningThreshold {
                store.wrappedValue.warningThreshold = max(50, store.wrappedValue.criticalThreshold - 5)
            }
        }
    }

    private var providerSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Provider.supported) { provider in
                    providerCard(provider)
                }
                codexHomesCard
                cursorSessionCard
                CopilotSessionCard()
                openCodeSessionCard
            }
            .padding(20)
        }
    }

    private func providerCard(_ provider: Provider) -> some View {
        SettingsCard(title: provider.displayName) {
            HStack(spacing: 10) {
                SettingsIconTile(
                    systemImage: provider.systemImage,
                    foreground: UsageTheme.provider(provider),
                    background: UsageTheme.provider(provider).opacity(0.12)
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(UsageTheme.primaryText)
                    if let account = store.snapshots[provider]?.account {
                        Text(account)
                            .font(.system(size: 10.5))
                            .foregroundStyle(UsageTheme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                ConnectionStatusView(
                    status: store.status(for: provider),
                    isRefreshing: store.refreshing.contains(provider)
                )
                Button { Task { await store.refresh(provider: provider) } } label: {
                    Group {
                        if store.refreshing.contains(provider) { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .frame(width: 30, height: 30)
                }
                .buttonStyle(QuietIconButtonStyle())
                .help("Refresh \(provider.displayName) now")
                .disabled(store.refreshing.contains(provider))
            }
            .padding(.bottom, 4)
            SettingsDivider()
            SettingsDetailRow(label: "Status", value: store.status(for: provider).title)
            if let snapshot = store.snapshots[provider] {
                if let account = snapshot.account {
                    SettingsDivider()
                    SettingsDetailRow(label: "Account", value: account)
                }
                if snapshot.lastSuccess != .distantPast {
                    SettingsDivider()
                    SettingsDetailRow(
                        label: "Last successful update",
                        value: snapshot.lastSuccess.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                if let error = snapshot.error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(UsageTheme.warning)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
            }
            SettingsDivider()
            SettingsDetailRow(label: "Source", value: providerSource(provider))
            SettingCaption(text: providerHelp(provider))
                .padding(.top, 8)
        }
    }

    private var codexHomesCard: some View {
        SettingsCard(title: "Codex homes") {
            SettingCaption(text: "Registered Codex home folders. Making one active moves it into ~/.codex so it becomes live; the current live folder moves back to its slot. Only folders move — credentials are never read or changed here.")
            if store.codexLiveHomeIsUnregistered {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(UsageTheme.warning)
                    SettingCaption(text: "The live folder doesn't match any registered home. Tell the app where this folder belongs when it's not active, then switching works.")
                }
                .padding(.top, 8)
                HStack {
                    Spacer()
                    Button("Assign home slot…") { assignCodexHomeSlotWithPanel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.codexSwitchInFlight)
                }
            }
            if store.codexHomes.isEmpty {
                HStack {
                    Text("Only ~/.codex is in use.")
                        .font(.system(size: 13))
                        .foregroundStyle(UsageTheme.secondaryText)
                    Spacer()
                    Button("Add folder…") { addCodexHomeWithPanel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.top, 8)
            } else {
                ForEach(Array(store.codexHomes.enumerated()), id: \.element.id) { index, home in
                    if index > 0 { SettingsDivider().padding(.leading, 38) }
                    HStack(spacing: 10) {
                        SettingsIconTile(
                            systemImage: "folder",
                            foreground: UsageTheme.secondaryText,
                            background: UsageTheme.elevated
                        )
                        VStack(alignment: .leading, spacing: 1) {
                            Text(home.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(home.lastSeenEmail == nil ? UsageTheme.secondaryText : UsageTheme.primaryText)
                            Text(home.path)
                                .font(.system(size: 10.5))
                                .foregroundStyle(UsageTheme.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if store.isCodexSlotEmpty(home) && !store.isCodexHomeActive(home) {
                                Text("Empty slot")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(UsageTheme.mutedText)
                            }
                        }
                        Spacer(minLength: 6)
                        if store.isCodexHomeActive(home) {
                            HStack(spacing: 4) {
                                Circle().fill(UsageTheme.codex).frame(width: 6, height: 6)
                                Text("Active")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(UsageTheme.secondaryText)
                            }
                        } else {
                            Button("Make active") { Task { await store.switchCodexAccount(to: home) } }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(store.codexSwitchInFlight || store.refreshing.contains(.codex))
                        }
                        Button { store.removeCodexHome(home) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.codexSwitchInFlight)
                        .help("Remove \(home.displayName) from the registry (files stay on disk)")
                    }
                    .padding(.vertical, 7)
                }
                HStack {
                    Spacer()
                    Button("Add folder…") { addCodexHomeWithPanel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.codexSwitchInFlight)
                }
                .padding(.top, 4)
            }
            if let error = store.codexSwitchError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(UsageTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            if let message = codexHomeMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(UsageTheme.secondaryText)
                    .padding(.top, 6)
            }
        }
    }

    private func addCodexHomeWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Codex home folder (the folder containing auth.json)."
        panel.prompt = "Register"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.addCodexHome(at: url)
            codexHomeMessage = nil
        } catch {
            codexHomeMessage = error.localizedDescription
        }
    }

    private func assignCodexHomeSlotWithPanel() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.message = "Where does the live Codex folder belong when it is not active? Type a folder name inside one of your account folders. Nothing is moved now."
        panel.prompt = "Assign slot"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.assignCodexHomeSlot(at: url)
            codexHomeMessage = nil
        } catch {
            codexHomeMessage = error.localizedDescription
        }
    }

    private var cursorSessionCard: some View {
        SettingsCard(title: "Cursor session") {
            SettingCaption(text: "AI Usage Monitor reads Cursor.app's signed-in session locally and calls Cursor's usage summary. If that session is unavailable, you can supply a cursor.com session cookie as a fallback.")
            SecureField("Optional cursor.com Cookie header", text: $cursorCookieHeader)
                .textFieldStyle(.roundedBorder)
                .padding(.vertical, 6)
            HStack {
                Label(cursorHasStoredCookie ? "Fallback cookie stored in macOS Keychain" : "Using Cursor.app session when available", systemImage: cursorHasStoredCookie ? "checkmark.shield" : "desktopcomputer")
                    .font(.system(size: 11))
                    .foregroundStyle(UsageTheme.secondaryText)
                Spacer()
                Link("CodexBar Cursor source", destination: URL(string: "https://github.com/steipete/CodexBar/blob/main/docs/cursor.md")!)
                    .font(.system(size: 11))
                Button("Save cookie & refresh") { saveCursorCredentials() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(cursorCookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if cursorHasStoredCookie {
                    Button("Remove cookie", role: .destructive) { removeCursorCredentials() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if let cursorCredentialMessage {
                Text(cursorCredentialMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(UsageTheme.secondaryText)
                    .padding(.top, 6)
            }
            SettingCaption(text: "Cursor's usage-summary endpoint is undocumented and may change. The billing-cycle end is shown when returned. Never paste a cookie into logs or screenshots.")
                .padding(.top, 6)
        }
    }

    private var openCodeSessionCard: some View {
        SettingsCard(title: "OpenCode session") {
            SettingCaption(text: "OpenCode usage comes from its authenticated dashboard. Paste the Cookie header from an OpenCode browser session; the app keeps only OpenCode auth cookies in macOS Keychain.")
            SecureField("OpenCode Cookie header", text: $openCodeCookieHeader)
                .textFieldStyle(.roundedBorder)
                .padding(.vertical, 6)
            HStack {
                Label(openCodeHasStoredCookie ? "Session cookie stored in macOS Keychain" : "No OpenCode session connected", systemImage: openCodeHasStoredCookie ? "checkmark.shield" : "key")
                    .font(.system(size: 11))
                    .foregroundStyle(UsageTheme.secondaryText)
                Spacer()
                Button("Save cookie & refresh") { saveOpenCodeCredentials() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(openCodeCookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if openCodeHasStoredCookie {
                    Button("Remove cookie", role: .destructive) { removeOpenCodeCredentials() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if let openCodeCredentialMessage {
                Text(openCodeCredentialMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(UsageTheme.secondaryText)
                    .padding(.top, 6)
            }
            SettingCaption(text: "OpenCode's dashboard API is undocumented and may change. Session cookies expire; never paste them into logs or screenshots.")
                .padding(.top, 6)
        }
    }

    private func providerSource(_ provider: Provider) -> String {
        switch provider {
        case .claude: "Claude Code OAuth usage"
        case .codex: "Local Codex app-server"
        case .cursor: "Cursor session · usage-summary web API"
        case .copilot: "GitHub OAuth · Copilot usage API"
        case .gemini: "Gemini CLI OAuth · Code Assist quota API"
        case .antigravity: "Antigravity OAuth · Google Cloud Code quota API"
        case .grok: "Grok CLI local billing log"
        case .openCode: "OpenCode dashboard session · web API"
        default: "Not integrated"
        }
    }

    private func providerHelp(_ provider: Provider) -> String {
        switch provider {
        case .claude: "Sign in with Claude Code to refresh. Credentials are read-only and never shown here."
        case .codex: "Sign in with Codex CLI or the ChatGPT app. AI Usage Monitor does not read Codex auth files."
        case .cursor: "Cursor.app authentication is read-only. An optional web session cookie is stored in Keychain."
        case .copilot: "Connect your GitHub account using device authorization. The token is stored in Keychain."
        case .gemini: "Sign in with Google through Gemini CLI. Usage is read from its OAuth session; API key and Vertex AI auth are unsupported."
        case .antigravity: "Sign in to Antigravity CLI first. Its existing Keychain credential or legacy token file is read without changing it."
        case .grok: "Use Grok CLI. Weekly credits are read from ~/.grok/logs/unified.jsonl; no network request is made."
        case .openCode: "Add an OpenCode dashboard cookie in Settings. The session is stored in Keychain."
        default: "Usage tracking is not integrated for this provider."
        }
    }

    private func saveCursorCredentials() {
        do {
            try CursorCredentialVault.save(cookieHeader: cursorCookieHeader)
            cursorCookieHeader = ""
            cursorHasStoredCookie = true
            cursorCredentialMessage = "Saved securely. Fetching Cursor usage…"
            Task { await store.refresh(provider: .cursor) }
        } catch {
            cursorCredentialMessage = error.localizedDescription
        }
    }

    private func removeCursorCredentials() {
        CursorCredentialVault.delete()
        cursorCookieHeader = ""
        cursorHasStoredCookie = false
        cursorCredentialMessage = "Saved Cursor cookie removed. Cursor.app session can still be used."
    }

    private func saveOpenCodeCredentials() {
        do {
            try OpenCodeCredentialVault.save(cookieHeader: openCodeCookieHeader)
            openCodeCookieHeader = ""
            openCodeHasStoredCookie = true
            openCodeCredentialMessage = "Saved securely. Fetching OpenCode usage…"
            Task { await store.refresh(provider: .openCode) }
        } catch {
            openCodeCredentialMessage = error.localizedDescription
        }
    }

    private func removeOpenCodeCredentials() {
        OpenCodeCredentialVault.delete()
        openCodeCookieHeader = ""
        openCodeHasStoredCookie = false
        openCodeCredentialMessage = "Saved OpenCode cookie removed."
    }

    private var aboutSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsCard(title: nil) {
                    HStack(spacing: 12) {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(UsageTheme.secondaryText)
                            .frame(width: 34, height: 34)
                            .background(UsageTheme.elevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI Usage Monitor")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(UsageTheme.primaryText)
                            Text("A native menu bar utility for Claude Code, Codex, Cursor, GitHub Copilot, Gemini CLI, Antigravity, Grok CLI, and OpenCode usage.")
                                .font(.system(size: 11))
                                .foregroundStyle(UsageTheme.secondaryText)
                        }
                    }
                    .padding(.bottom, 4)
                    SettingsDivider()
                    Text("Claude usage uses the Claude Code OAuth usage endpoint. Codex usage comes from the local `codex app-server`. Cursor, GitHub Copilot, Gemini CLI, and Antigravity usage use their session-authenticated APIs; Grok CLI usage comes from its local log. Provider interfaces can change.")
                        .font(.system(size: 12))
                        .foregroundStyle(UsageTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 8)
                    SettingsDivider()
                    Text("UI and integration references are MIT licensed: claude-usage-widget by bozdemir and codex-usage-bar by CMMUU.")
                        .font(.system(size: 11))
                        .foregroundStyle(UsageTheme.mutedText)
                        .padding(.top, 8)
                }
            }
            .padding(20)
        }
    }
}

private struct UsageCardLayoutSettings: View {
    @AppStorage("overviewCardLayout") private var overviewRaw = UsageCardLayout.twoColumns.rawValue
    @AppStorage("detailCardLayout") private var detailRaw = UsageCardLayout.compactBalanced.rawValue
    @AppStorage("useUnifiedCardLayout") private var useUnifiedLayout = false
    @AppStorage("collapsibleInitiallyExpanded") private var initiallyExpanded = false

    private var overviewSelection: Binding<UsageCardLayout> {
        Binding(get: { UsageCardLayout.preference(overviewRaw, fallback: .twoColumns) }, set: { overviewRaw = $0.rawValue })
    }
    private var detailSelection: Binding<UsageCardLayout> {
        Binding(get: { UsageCardLayout.preference(detailRaw, fallback: .compactBalanced) }, set: { detailRaw = $0.rawValue })
    }

    var body: some View {
        SettingsCard(title: "Usage Card Layout") {
            Text("Overview Layout")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(UsageTheme.primaryText)
            layoutGrid(selection: overviewSelection)
            SettingsDivider().padding(.vertical, 2)
            Text("Provider Detail Layout")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(UsageTheme.primaryText)
            layoutGrid(selection: detailSelection).disabled(useUnifiedLayout)
            if useUnifiedLayout {
                SettingCaption(text: "Overview Layout is used for both Overview and Provider Detail.")
            }
            Toggle("Use the same layout everywhere", isOn: $useUnifiedLayout)
                .font(.system(size: 12, weight: .medium))
                .toggleStyle(.checkbox)
            Toggle("Start collapsible cards expanded", isOn: $initiallyExpanded)
                .font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryText)
                .toggleStyle(.checkbox)
                .disabled(overviewSelection.wrappedValue != .collapsible && detailSelection.wrappedValue != .collapsible)
        }
    }

    private func layoutGrid(selection: Binding<UsageCardLayout>) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)], spacing: 9) {
            ForEach(UsageCardLayout.allCases) { layout in
                UsageCardLayoutChoice(layout: layout, isSelected: selection.wrappedValue == layout) {
                    selection.wrappedValue = layout
                }
            }
        }
    }
}

private struct UsageCardLayoutChoice: View {
    let layout: UsageCardLayout
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                UsageCardLayoutPreview(layout: layout)
                    .frame(height: 48)
                    .frame(maxWidth: .infinity)
                    .background(UsageTheme.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack(spacing: 5) {
                    Text(layout.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if isSelected { Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(UsageTheme.codex) }
                }
                Text(layout.subtitle).font(.system(size: 9.5)).foregroundStyle(UsageTheme.secondaryText).lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? UsageTheme.codex.opacity(0.08) : UsageTheme.elevated.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(isSelected ? UsageTheme.codex.opacity(0.55) : UsageTheme.separator, lineWidth: isSelected ? 1 : 0.7))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(layout.title), \(layout.subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct UsageCardLayoutPreview: View {
    let layout: UsageCardLayout
    private let accent = UsageTheme.codex

    var body: some View {
        VStack(spacing: 4) {
            switch layout {
            case .compactBalanced:
                previewMetric(label: "5-hour limit", width: 0.38, horizontal: false)
                previewMetric(label: "Weekly limit", width: 0.2, horizontal: false)
            case .twoColumns:
                HStack(spacing: 5) {
                    tileMetric(label: "5-hour", width: 0.38)
                    tileMetric(label: "Weekly", width: 0.2)
                }
            case .minimalRows:
                previewMetric(label: "5h", width: 0.38, horizontal: true)
                previewMetric(label: "7d", width: 0.2, horizontal: true)
            case .collapsible:
                HStack(spacing: 4) {
                    Circle().fill(accent).frame(width: 5, height: 5)
                    Text("Codex · Plus").font(.system(size: 8, weight: .medium))
                    Spacer()
                    Text("10%").font(.system(size: 8, weight: .semibold).monospacedDigit())
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
                }
                previewBar(width: 0.38)
            }
        }
        .padding(.horizontal, 7)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func previewMetric(label: String, width: CGFloat, horizontal: Bool) -> some View {
        if horizontal {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 7.5, weight: .medium)).lineLimit(1)
                previewBar(width: width)
                Spacer(minLength: 2)
                Text(width == 0.38 ? "10%" : "2%").font(.system(size: 7.5, weight: .semibold).monospacedDigit())
            }
        } else {
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text(label).font(.system(size: 7.5, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(width == 0.38 ? "10%" : "2%").font(.system(size: 7.5, weight: .semibold).monospacedDigit())
                }
                previewBar(width: width)
            }
        }
    }

    private func tileMetric(label: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(label).font(.system(size: 7.5, weight: .medium)); Spacer(); Text(width == 0.38 ? "10%" : "2%").font(.system(size: 7, weight: .semibold)) }
            previewBar(width: width)
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .background(UsageTheme.elevated, in: RoundedRectangle(cornerRadius: 5))
    }

    private func previewBar(width: CGFloat) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(UsageTheme.track)
                Capsule().fill(accent).frame(width: proxy.size.width * width)
            }
        }
        .frame(height: 4)
    }
}

private struct CopilotSessionCard: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var status: String?
    @State private var userCode: String?
    @State private var signInTask: Task<Void, Never>?
    @State private var hasToken = CopilotCredentialVault.hasToken

    var body: some View {
        SettingsCard(title: "GitHub Copilot") {
            SettingCaption(text: "Connect with GitHub's public OAuth device flow. The access token is stored in macOS Keychain and used to read Copilot quota.")
            if let userCode {
                Text("Enter code \(userCode) at github.com/login/device")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Link("Open GitHub device login", destination: URL(string: "https://github.com/login/device")!)
                    Spacer()
                    Button("Cancel sign in", role: .cancel) { cancelSignIn() }
                }
            }
            HStack {
                Label(hasToken ? "GitHub token stored in macOS Keychain" : "Not connected", systemImage: hasToken ? "checkmark.shield" : "key")
                    .font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryText)
                Spacer()
                if hasToken {
                    Button("Disconnect", role: .destructive) { disconnect() }.buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button(userCode == nil ? "Connect GitHub" : "Waiting for authorization…") { beginSignIn() }
                        .buttonStyle(.bordered).controlSize(.small).disabled(signInTask != nil)
                }
            }
            if let status { Text(status).font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryText).padding(.top, 4) }
            SettingCaption(text: "Quota data comes from GitHub's undocumented Copilot usage API; available quota types depend on your plan.").padding(.top, 5)
        }
    }

    private func beginSignIn() {
        status = "Requesting a GitHub device code…"
        signInTask = Task {
            do {
                let flow = CopilotDeviceFlow()
                let code = try await flow.requestCode()
                guard !Task.isCancelled else { return }
                userCode = code.userCode
                status = "Waiting for GitHub authorization…"
                if let url = URL(string: code.verificationUri) { openURL(url) }
                let token = try await flow.poll(code)
                try CopilotCredentialVault.save(token: token)
                hasToken = true
                userCode = nil
                status = "Connected. Fetching Copilot usage…"
                await store.refresh(provider: .copilot)
                signInTask = nil
            } catch is CancellationError {
                signInTask = nil
            } catch {
                signInTask = nil
                userCode = nil
                status = error.localizedDescription
            }
        }
    }

    private func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        userCode = nil
        status = "Sign in cancelled."
    }

    private func disconnect() {
        cancelSignIn()
        CopilotCredentialVault.delete()
        hasToken = false
        status = "GitHub Copilot disconnected."
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(UsageTheme.secondaryText)
                    .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(15)
            .background(UsageTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(UsageTheme.separator.opacity(0.8), lineWidth: 0.7))
        }
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(UsageTheme.separator).frame(height: 1)
    }
}

private struct SettingCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(UsageTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsIconTile: View {
    let systemImage: String
    let foreground: Color
    let background: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: 28, height: 28)
            .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SettingsDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(UsageTheme.secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(UsageTheme.primaryText)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 5)
    }
}

private struct ThresholdSettingRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(UsageTheme.primaryText)
                .frame(width: 80, alignment: .leading)
            Slider(value: $value, in: range, step: 5)
                .tint(color)
            Text("\(Int(value))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(color))
                .frame(minWidth: 52)
                .help("\(label) threshold")
        }
        .padding(.vertical, 2)
    }
}
