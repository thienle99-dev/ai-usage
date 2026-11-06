import AppKit
import SwiftUI

struct CompactPopoverView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var providers: [Provider] {
        store.providerOrder.filter {
            store.visibleProviders.contains($0) && (store.selectedProvider == nil || store.selectedProvider == $0)
        }
    }

    private var isDarkAppearance: Bool {
        switch store.appearance {
        case "dark": true
        case "light": false
        default: colorScheme == .dark
        }
    }

    private var windowAppearanceName: NSAppearance.Name? {
        switch store.appearance {
        case "dark": .darkAqua
        case "light": .aqua
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CompactPopoverHeader(
                isRefreshing: store.isRefreshing,
                refresh: { Task { await store.refresh() } },
                addAccount: { presentSettings(tab: "Providers") },
                toggleAppearance: {
                    setAppearance(isDarkAppearance ? "light" : "dark")
                },
                isDarkAppearance: isDarkAppearance,
                more: moreMenu
            )

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if providers.isEmpty {
                        Text("No providers shown")
                            .font(.system(size: 11))
                            .foregroundStyle(PopoverColorTokens.secondaryText(colorScheme: colorScheme, increasedContrast: colorSchemeContrast == .increased))
                            .padding(.vertical, 5)
                    } else {
                        ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
                            CompactProviderSection(
                                provider: provider,
                                showsSeparator: index > 0,
                                colorScheme: colorScheme,
                                increasedContrast: colorSchemeContrast == .increased
                            )
                        }
                    }
                }
            }
            .padding(.top, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.automatic)

            CompactPopoverFooter(
                lastRefresh: store.lastRefreshAttempt,
                website: { NSWorkspace.shared.open(URL(string: "https://github.com/thienle99-dev/ai-usage")!) },
                settings: { presentSettings() },
                quit: { NSApp.terminate(nil) }
            )
        }
        .padding(.horizontal, 15)
        .frame(width: 280, height: 480, alignment: .topLeading)
        // A light tint over the system backdrop keeps the native window's
        // blur and shape while lifting its Light Mode tone slightly.
        .background {
            if colorScheme == .light && !reduceTransparency && colorSchemeContrast != .increased {
                Color.white.opacity(0.05)
            }
        }
        .background {
            PopoverWindowAppearanceBridge(appearanceName: windowAppearanceName)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .task { if store.needsInitialRefreshOnOpen { await store.refresh() } }
    }

    private var moreMenu: some View {
        Menu {
            Button("All Providers") { store.selectedProvider = nil }
                .disabled(store.selectedProvider == nil)
            ForEach(store.providerOrder.filter { store.visibleProviders.contains($0) }) { provider in
                Button(provider.displayName) { store.selectedProvider = provider }
                    .disabled(store.selectedProvider == provider)
            }
            Divider()
            Button("Token & Cost Report…") { openWindow(id: "usage-report") }
            Button("About…") { presentSettings(tab: "About") }
            Link("Help", destination: URL(string: "https://github.com/thienle99-dev/ai-usage#readme")!)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 28, height: 28)
        .modifier(CompactHeaderHoverStyle())
        .help("More actions")
        .accessibilityLabel("More actions")
    }

    private func presentSettings(tab: String = "General") {
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

    private func setAppearance(_ appearance: String) {
        store.appearance = appearance
    }
}

private struct CompactPopoverHeader<MoreContent: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let isRefreshing: Bool
    let refresh: () -> Void
    let addAccount: () -> Void
    let toggleAppearance: () -> Void
    let isDarkAppearance: Bool
    let more: MoreContent

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 15, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(PopoverColorTokens.secondaryText(colorScheme: colorScheme, increasedContrast: colorSchemeContrast == .increased))
                    .accessibilityHidden(true)
                Text("AI Usage")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PopoverColorTokens.primaryText(colorScheme: colorScheme, increasedContrast: colorSchemeContrast == .increased))
            }
            Spacer(minLength: 4)
            Button(action: refresh) {
                Group {
                    if isRefreshing { ProgressView().controlSize(.mini) }
                    else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .regular))
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(CompactHeaderHoverStyle())
            .disabled(isRefreshing)
            .help("Refresh usage")
            .accessibilityLabel("Refresh usage")

            Button(action: addAccount) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(CompactHeaderHoverStyle())
            .help("Add account")
            .accessibilityLabel("Add account")

            Button(action: toggleAppearance) {
                Image(systemName: isDarkAppearance ? "moon.fill" : "sun.max.fill")
                    .font(.system(size: 12, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(CompactHeaderHoverStyle())
            .help("Switch to \(isDarkAppearance ? "Light" : "Dark") appearance")
            .accessibilityLabel("Switch to \(isDarkAppearance ? "light" : "dark") appearance")

            more
        }
        .foregroundStyle(PopoverColorTokens.secondaryText(colorScheme: colorScheme, increasedContrast: colorSchemeContrast == .increased))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
    }
}

@MainActor
private struct PopoverWindowAppearanceBridge: NSViewRepresentable {
    let appearanceName: NSAppearance.Name?

    func makeNSView(context: Context) -> PopoverAppearanceView {
        let view = PopoverAppearanceView()
        view.appearanceName = appearanceName
        return view
    }

    func updateNSView(_ view: PopoverAppearanceView, context: Context) {
        view.appearanceName = appearanceName
    }
}

@MainActor
private final class PopoverAppearanceView: NSView {
    var appearanceName: NSAppearance.Name? {
        didSet { applyAppearance() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAppearance()
    }

    private func applyAppearance() {
        guard let window else { return }
        let appearance = appearanceName.flatMap(NSAppearance.init(named:))
        if window.appearance?.name != appearanceName {
            window.appearance = appearance
        }
    }
}

private struct CompactHeaderHoverStyle: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                isHovered ? Color.primary.opacity(0.06) : .clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .onHover { isHovered = $0 }
    }
}

private struct CompactProviderSection: View {
    @Environment(UsageStore.self) private var store
    let provider: Provider
    let showsSeparator: Bool
    let colorScheme: ColorScheme
    let increasedContrast: Bool

    private var snapshot: UsageSnapshot? { store.snapshots[provider] }
    private var providerStatus: ProviderStatus { store.status(for: provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsSeparator {
                Rectangle()
                    .fill(PopoverColorTokens.separator)
                    .frame(height: 0.5)
                    .padding(.top, 12)
            }
            HStack(spacing: 6) {
                Image(systemName: provider.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PopoverColorTokens.providerIcon(provider, colorScheme: colorScheme))
                    .accessibilityHidden(true)
                Text(providerLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PopoverColorTokens.secondaryText(colorScheme: colorScheme, increasedContrast: increasedContrast))
            }
            VStack(spacing: 5) {
                ForEach(accountRows) { row in
                    CompactAccountRow(
                        row: row,
                        provider: provider,
                        windows: row.selected ? snapshot?.windows ?? [] : [],
                        status: providerStatus,
                        colorScheme: colorScheme,
                        increasedContrast: increasedContrast
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var providerLabel: String {
        switch provider {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .copilot: "Copilot"
        default: provider.displayName
        }
    }

    private var accountRows: [CompactAccountRowModel] {
        switch provider {
        case .codex:
            let activeID = store.codexInUseAccountID
            var rows = store.codexAccounts.map { account in
                let selected = account.id == activeID
                return makeRow(
                    id: account.id,
                    name: selected ? (snapshot?.account ?? account.label) : account.label,
                    selected: selected,
                    selectedAction: { Task { await store.refresh(provider: .codex) } },
                    inactiveAction: { store.activateCodexAccount(account.id) }
                )
            }
            if !rows.contains(where: \.selected) {
                rows.insert(makeRow(
                    id: "codex-live",
                    name: snapshot?.account ?? String(localized: "Current session"),
                    selected: true,
                    selectedAction: { Task { await store.refresh(provider: .codex) } }
                ), at: 0)
            }
            return rows

        case .antigravity:
            let activeID = store.activeAntigravityAccountID
            var rows = store.antigravityAccounts.map { account in
                let selected = account.id == activeID
                return makeRow(
                    id: account.id,
                    name: selected ? (snapshot?.account ?? account.displayName) : account.displayName,
                    selected: selected,
                    selectedAction: { Task { await store.refresh(provider: .antigravity) } },
                    inactiveAction: { Task { await store.switchAntigravityAccount(to: account.id) } }
                )
            }
            if !rows.contains(where: \.selected) {
                rows.insert(makeRow(
                    id: "antigravity-live",
                    name: snapshot?.account ?? String(localized: "Antigravity CLI/App sign-in"),
                    selected: true,
                    selectedAction: { Task { await store.refresh(provider: .antigravity) } }
                ), at: 0)
            }
            return rows.isEmpty ? [defaultRow] : rows

        default:
            return [defaultRow]
        }
    }

    private var defaultRow: CompactAccountRowModel {
        makeRow(
            id: "\(provider.rawValue)-current",
            name: snapshot?.account ?? String(localized: "Current session"),
            selected: true,
            selectedAction: { Task { await store.refresh(provider: provider) } }
        )
    }

    private func makeRow(
        id: String,
        name: String,
        selected: Bool,
        selectedAction: @escaping () -> Void,
        inactiveAction: (() -> Void)? = nil
    ) -> CompactAccountRowModel {
        let account = accountParts(name)
        return CompactAccountRowModel(
            id: id,
            name: account.name,
            plan: account.plan,
            selected: selected,
            action: selected ? selectedAction : (inactiveAction ?? selectedAction)
        )
    }

    private func accountParts(_ value: String) -> (name: String, plan: String?) {
        let parts = value.components(separatedBy: " · ")
        guard parts.count > 1 else { return (value, nil) }
        return (parts[0], parts.dropFirst().joined(separator: " · "))
    }

}

private struct CompactAccountRowModel: Identifiable {
    let id: String
    let name: String
    let plan: String?
    let selected: Bool
    let action: () -> Void
}

private struct CompactAccountRow: View {
    @AppStorage("showPopoverResetTimes") private var showResetTimes = false
    @State private var isHovered = false
    let row: CompactAccountRowModel
    let provider: Provider
    let windows: [UsageWindow]
    let status: ProviderStatus
    let colorScheme: ColorScheme
    let increasedContrast: Bool

    private var providerLabel: String { provider == .claude ? "Claude Code" : provider.shortName }

    private var fiveHour: UsageWindow? {
        windows.first { window in
            let label = window.label.lowercased()
            return label.contains("5-hour") || label.contains("five_hour") || label.contains("5h")
        }
    }

    private var weekly: UsageWindow? {
        windows.first { window in
            let label = window.label.lowercased()
            return label == "weekly limit" || label == "seven_day" || label == "weekly"
        } ?? windows.first { $0.label.lowercased().contains("weekly") }
    }

    var body: some View {
        Button(action: row.action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(PopoverColorTokens.selectedIndicator(provider, colorScheme: colorScheme))
                        .frame(width: 12)
                        .opacity(row.selected ? 1 : 0)
                        .accessibilityHidden(true)
                    Text(row.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(row.selected
                            ? PopoverColorTokens.primaryText(colorScheme: colorScheme, increasedContrast: increasedContrast)
                            : PopoverColorTokens.secondaryText(colorScheme: colorScheme, increasedContrast: increasedContrast))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Spacer(minLength: 3)
                    if let plan = row.plan, !plan.isEmpty {
                        Text(plan)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(PopoverColorTokens.secondaryText(colorScheme: colorScheme, increasedContrast: increasedContrast))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 105, alignment: .trailing)
                            .help(plan)
                    }
                }
                HStack(spacing: 5) {
                    Color.clear.frame(width: 12)
                    Text(usageSummary)
                        .font(.system(size: 12, weight: .regular).monospacedDigit())
                        .foregroundStyle(status == .authenticationRequired && row.selected
                            ? UsageTheme.critical
                            : PopoverColorTokens.secondaryText(colorScheme: colorScheme, increasedContrast: increasedContrast))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if showResetTimes, let resetSummary {
                    HStack(spacing: 5) {
                        Color.clear.frame(width: 12)
                        Text(resetSummary)
                            .font(.system(size: 10, weight: .regular).monospacedDigit())
                            .foregroundStyle(PopoverColorTokens.secondaryText(colorScheme: colorScheme, increasedContrast: increasedContrast))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 7)
            .background(isHovered ? PopoverColorTokens.rowHoverTint(provider, colorScheme: colorScheme) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                if isHovered && increasedContrast {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(PopoverColorTokens.separator, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(detailTooltip)
        .accessibilityLabel(detailTooltip)
        .accessibilityHint("Activate this account or refresh its usage")
        .accessibilityAddTraits(row.selected ? .isSelected : [])
    }

    private var usageSummary: String {
        guard row.selected else { return String(localized: "Saved account · select to switch") }
        if status == .authenticationRequired { return String(localized: "Sign-in expired") }

        if let fiveHour, fiveHour.validUtilization == 100 {
            return limitReachedSummary(label: "5h", window: fiveHour)
        }
        if let weekly, weekly.validUtilization == 100 {
            return limitReachedSummary(label: "Week", window: weekly)
        }

        let parts = [
            usageText(label: "5h", window: fiveHour),
            usageText(label: "Week", window: weekly)
        ].compactMap { $0 }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        if status == .rateLimited { return String(localized: "Rate limited · Reset unavailable") }
        return String(localized: "Usage unavailable")
    }

    private var resetSummary: String? {
        guard row.selected else { return nil }
        let quotaResets: [(String, UsageWindow?)] = [("5h", fiveHour), ("Week", weekly)]
        let parts = quotaResets.compactMap { label, window -> String? in
            guard let window else { return nil }
            let reset = window.resetsAt.map(resetTimeLabel) ?? String(localized: "Unavailable")
            return "\(label) \(reset)"
        }
        guard !parts.isEmpty else { return nil }
        return "\(String(localized: "Reset")) \(parts.joined(separator: " · "))"
    }

    private var detailTooltip: String {
        let state = row.selected ? status.title : String(localized: "Saved")
        var lines = ["\(providerLabel) · \(state)", row.name]
        if let plan = row.plan, !plan.isEmpty {
            lines.append(String(format: String(localized: "Plan: %@"), plan))
        }

        if row.selected {
            if windows.isEmpty {
                lines.append(String(localized: "Usage unavailable"))
            } else {
                for window in windows {
                    let used = window.validUtilization.map {
                        "\($0.formatted(.number.precision(.fractionLength(0...2))))% used"
                    } ?? String(localized: "Usage unavailable")
                    lines.append("\(window.label) · \(used)")
                    let reset = window.resetsAt.map(resetTimeLabel) ?? String(localized: "Reset unavailable")
                    lines.append("\(String(localized: "Reset")) \(reset)")
                    if let detail = window.detail, !detail.isEmpty { lines.append(detail) }
                }
            }
        } else {
            lines.append(String(localized: "Usage is shown for the active account only."))
        }

        return lines.joined(separator: "\n")
    }

    private func resetTimeLabel(_ date: Date) -> String {
        if Calendar.autoupdatingCurrent.isDateInToday(date) {
            return "\(String(localized: "Today")) · \(date.formatted(.dateTime.hour().minute()))"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    private func usageText(label: String, window: UsageWindow?) -> String? {
        guard let window, let percentage = window.validUtilization else { return nil }
        let value = percentage.formatted(.number.precision(.fractionLength(0)))
        if label == "5h" { return String(format: String(localized: "5h %@%% used"), value) }
        return String(format: String(localized: "Week %@%% used"), value)
    }

    private func limitReachedSummary(label: String, window: UsageWindow) -> String {
        guard let date = window.resetsAt else {
            if label == "5h" { return String(localized: "5h limit reached · Reset unavailable") }
            return String(localized: "Week limit reached · Reset unavailable")
        }
        let reset = date.formatted(date: .omitted, time: .shortened)
        if label == "5h" { return String(format: String(localized: "5h limit reached · resets %@"), reset) }
        return String(format: String(localized: "Week limit reached · resets %@"), reset)
    }
}

private struct CompactPopoverFooter: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let lastRefresh: Date?
    let website: () -> Void
    let settings: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(PopoverColorTokens.separator)
                .frame(height: 0.5)
            HStack(spacing: 4) {
                Text(lastRefresh.map { String(format: String(localized: "Updated %@"), $0.formatted(date: .omitted, time: .shortened)) } ?? String(localized: "Not refreshed"))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(PopoverColorTokens.secondaryText(colorScheme: colorScheme, increasedContrast: colorSchemeContrast == .increased))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(lastRefresh.map { "Last updated \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Usage has not been refreshed")

                footerButton(symbol: "globe", label: "Website", action: website)
                footerButton(symbol: "gearshape", label: "Settings", action: settings)
                footerButton(symbol: "power", label: "Quit", action: quit)
            }
            .frame(height: 35)
        }
        .buttonStyle(.plain)
    }

    private func footerButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .modifier(CompactHeaderHoverStyle())
        .foregroundStyle(PopoverColorTokens.secondaryText(colorScheme: colorScheme, increasedContrast: colorSchemeContrast == .increased))
        .help(label)
        .accessibilityLabel(label)
    }
}
