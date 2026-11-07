import AppKit
import SwiftUI

struct CompactPopoverView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var providerContentHeight: CGFloat = 1

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
                locale: locale,
                isRefreshing: store.isRefreshing,
                refresh: { Task { await store.refresh() } },
                addAccount: { presentAddAccountWindow() },
                toggleAppearance: {
                    setAppearance(isDarkAppearance ? "light" : "dark")
                },
                isDarkAppearance: isDarkAppearance,
                more: moreMenu
            )

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if providers.isEmpty {
                        Text(AppLocalization.string("No providers shown", locale: locale))
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 12)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: PopoverContentHeightKey.self,
                            value: geometry.size.height
                        )
                    }
                }
                .background {
                    ScrollViewScrollerStyleBridge(isDarkAppearance: isDarkAppearance)
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: min(providerContentHeight, 540))
            .padding(.vertical, 8)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.automatic)
            .onPreferenceChange(PopoverContentHeightKey.self) { height in
                providerContentHeight = ceil(height)
            }

            CompactPopoverFooter(
                lastRefresh: store.lastRefreshAttempt,
                website: { NSWorkspace.shared.open(URL(string: "https://github.com/thienle99-dev/ai-usage")!) },
                settings: { presentSettings() },
                quit: { NSApp.terminate(nil) }
            )
        }
        .padding(.horizontal, 15)
        .frame(width: 300, alignment: .topLeading)
        // A light tint over the system backdrop keeps the native window's
        // blur and shape while lifting its Light Mode tone slightly.
        .background {
            if colorScheme == .light && !reduceTransparency && colorSchemeContrast != .increased {
                Color.white.opacity(0.05)
            }
        }
        .background {
            PopoverWindowAppearanceBridge(
                appearanceName: windowAppearanceName,
                reduceTransparency: reduceTransparency,
                increasedContrast: colorSchemeContrast == .increased
            )
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .environment(\.locale, store.locale)
        .task {
            if store.needsInitialRefreshOnOpen { await store.refresh() }
            await store.refreshManagedAccountQuotas()
        }
    }

    private var moreMenu: some View {
        Menu {
            Button { store.selectedProvider = nil } label: {
                Text(AppLocalization.string("All Providers", locale: locale))
            }
                .disabled(store.selectedProvider == nil)
            ForEach(store.providerOrder.filter { store.visibleProviders.contains($0) }) { provider in
                Button(provider.displayName) { store.selectedProvider = provider }
                    .disabled(store.selectedProvider == provider)
            }
            Divider()
            Menu {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        store.language = language.rawValue
                    } label: {
                        if store.language == language.rawValue {
                            Label {
                                Text(AppLocalization.string(language.title, locale: locale))
                            } icon: {
                                Image(systemName: "checkmark")
                            }
                        } else {
                            Text(AppLocalization.string(language.title, locale: locale))
                        }
                    }
                    .disabled(store.language == language.rawValue)
                }
            } label: {
                Label {
                    Text(AppLocalization.string("Language", locale: locale))
                } icon: {
                    Image(systemName: "character.bubble")
                }
            }
            Divider()
            Button { openWindow(id: "usage-report") } label: {
                Text(AppLocalization.string("Token & Cost Report…", locale: locale))
            }
            Button { presentSettings(tab: "About") } label: {
                Text(AppLocalization.string("About…", locale: locale))
            }
            Link(destination: URL(string: "https://github.com/thienle99-dev/ai-usage#readme")!) {
                Text(AppLocalization.string("Help", locale: locale))
            }
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
        .help(AppLocalization.string("More actions", locale: locale))
        .accessibilityLabel(AppLocalization.string("More actions", locale: locale))
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

    private func presentAddAccountWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "add-account")
        let windowTitle = String(localized: "Add Account", locale: store.locale)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
            guard let window = NSApp.windows.first(where: { $0.title == windowTitle }) else { return }
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
    let locale: Locale
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
            .help(AppLocalization.string("Refresh usage", locale: locale))
            .accessibilityLabel(AppLocalization.string("Refresh usage", locale: locale))

            Button(action: addAccount) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(CompactHeaderHoverStyle())
            .help(AppLocalization.string("Add account", locale: locale))
            .accessibilityLabel(AppLocalization.string("Add account", locale: locale))

            Button(action: toggleAppearance) {
                Image(systemName: isDarkAppearance ? "moon.fill" : "sun.max.fill")
                    .font(.system(size: 12, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(CompactHeaderHoverStyle())
            .help(AppLocalization.string(isDarkAppearance ? "Switch to Light appearance" : "Switch to Dark appearance", locale: locale))
            .accessibilityLabel(AppLocalization.string(isDarkAppearance ? "Switch to Light appearance" : "Switch to Dark appearance", locale: locale))

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
    let reduceTransparency: Bool
    let increasedContrast: Bool

    func makeNSView(context: Context) -> PopoverAppearanceView {
        let view = PopoverAppearanceView()
        view.appearanceName = appearanceName
        view.reduceTransparency = reduceTransparency
        view.increasedContrast = increasedContrast
        return view
    }

    func updateNSView(_ view: PopoverAppearanceView, context: Context) {
        view.appearanceName = appearanceName
        view.reduceTransparency = reduceTransparency
        view.increasedContrast = increasedContrast
    }
}

@MainActor
private struct ScrollViewScrollerStyleBridge: NSViewRepresentable {
    let isDarkAppearance: Bool

    func makeNSView(context: Context) -> ScrollViewScrollerStyleView {
        let view = ScrollViewScrollerStyleView()
        view.isDarkAppearance = isDarkAppearance
        return view
    }

    func updateNSView(_ view: ScrollViewScrollerStyleView, context: Context) {
        view.isDarkAppearance = isDarkAppearance
    }
}

@MainActor
private final class ScrollViewScrollerStyleView: NSView {
    var isDarkAppearance = false {
        didSet { applyScrollerStyle() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyScrollerStyle()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyScrollerStyle()
    }

    private func applyScrollerStyle() {
        guard let scrollView = enclosingScrollView else { return }
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        guard let scroller = scrollView.verticalScroller else { return }
        scroller.controlSize = .mini
        scroller.knobStyle = isDarkAppearance ? .light : .dark
    }
}

@MainActor
private final class PopoverAppearanceView: NSView {
    var reduceTransparency = false { didSet { applyAppearance() } }
    var increasedContrast = false { didSet { applyAppearance() } }
    private weak var glassView: NSView?

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
        updateGlassBackground(in: window)
    }

    private func updateGlassBackground(in window: NSWindow) {
        guard #available(macOS 26, *) else { return }
        guard !reduceTransparency, !increasedContrast,
              let frameView = window.contentView?.superview else {
            glassView?.removeFromSuperview()
            glassView = nil
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            return
        }

        // The native panel fill would otherwise sit on top of the glass and flatten it.
        window.isOpaque = false
        window.backgroundColor = .clear

        let glassView: NSGlassEffectView
        if let existingView = self.glassView as? NSGlassEffectView {
            glassView = existingView
        } else {
            glassView = NSGlassEffectView()
            glassView.style = .regular
            glassView.cornerRadius = 18
            glassView.autoresizingMask = [.width, .height]
            frameView.addSubview(glassView, positioned: .below, relativeTo: window.contentView)
            self.glassView = glassView
        }
        glassView.frame = frameView.bounds
    }
}

private struct CompactHeaderHoverStyle: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .popoverGlass(in: Circle(), interactive: true, isActive: isHovered)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

private struct PopoverContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct CompactProviderSection: View {
    @Environment(UsageStore.self) private var store
    @Environment(AccountLoginCoordinator.self) private var accountLogin
    @Environment(\.openWindow) private var openWindow
    @Environment(\.locale) private var locale
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
                    .padding(.vertical, 8)
            }
            HStack(spacing: 6) {
                Image(systemName: provider.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 12)
                    .foregroundStyle(PopoverColorTokens.providerIcon(provider, colorScheme: colorScheme))
                    .accessibilityHidden(true)
                Text(providerLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PopoverColorTokens.secondaryText(colorScheme: colorScheme, increasedContrast: increasedContrast))
            }
            .padding(.bottom, 2)
            VStack(spacing: 4) {
                ForEach(accountRows) { row in
                    CompactAccountRow(
                        row: row,
                        provider: provider,
                        windows: row.selected ? snapshot?.windows ?? [] : row.windows,
                        status: row.status ?? providerStatus,
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
        case .claude:
            return managedAccountRows(
                accounts: store.claudeCodeAccounts,
                activeID: store.claudeCodeInUseAccountID,
                provider: .claude
            )
        case .codex:
            return managedAccountRows(
                accounts: store.codexAccounts,
                activeID: store.codexInUseAccountID,
                provider: .codex
            )

        case .antigravity:
            let activeID = store.activeAntigravityAccountID
            var rows = store.antigravityAccounts.map { account in
                let selected = account.id == activeID
                let email = AntigravityCredentials.emailOnlyIdentity(account.identity)
                let selectedEmail = AntigravityCredentials.emailOnlyIdentity(snapshot?.account) ?? email
                return makeRow(
                    id: account.id,
                    name: selected ? (selectedEmail ?? AppLocalization.string("Antigravity account", locale: locale))
                        : (email ?? AppLocalization.string("Antigravity account", locale: locale)),
                    selected: selected,
                    selectedAction: { Task { await store.refresh(provider: .antigravity) } },
                    inactiveAction: { Task { await store.switchAntigravityAccount(to: account.id) } },
                    plan: selected ? snapshot?.plan : nil
                )
            }
            if !rows.contains(where: \.selected) {
                rows.insert(makeRow(
                    id: "antigravity-live",
                    name: AntigravityCredentials.emailOnlyIdentity(snapshot?.account)
                        ?? AppLocalization.string("Antigravity CLI/App sign-in", locale: locale),
                    selected: true,
                    selectedAction: { Task { await store.refresh(provider: .antigravity) } },
                    plan: snapshot?.plan
                ), at: 0)
            }
            return rows.isEmpty ? [defaultRow] : rows

        default:
            return [defaultRow]
        }
    }

    private func managedAccountRows(
        accounts: [ManagedAccountRecord],
        activeID: String?,
        provider managedProvider: Provider
    ) -> [CompactAccountRowModel] {
        let cached = store.managedAccountSnapshots[managedProvider] ?? [:]
        var rows = accounts.map { account in
            let selected = account.id == activeID
            let quota = cached[account.id]
            let needsLogin = store.managedAccountStatuses[managedProvider]?[account.id] == .authenticationRequired
            let isSwitching = store.accountSessionActionProvider == managedProvider
                && store.accountSessionActionAccountID == account.id
            let accountAction = {
                if needsLogin {
                    accountLogin.select(managedProvider)
                    openWindow(id: "add-account")
                } else if selected {
                    Task { await store.refreshManagedAccountQuota(for: managedProvider, accountID: account.id) }
                } else {
                    Task { await store.activateManagedAccount(for: managedProvider, id: account.id) }
                }
            }
            let row = makeRow(
                id: account.id,
                name: selected ? (snapshot?.account ?? account.label) : (quota?.account ?? account.label),
                selected: selected,
                selectedAction: accountAction,
                inactiveAction: accountAction,
                windows: quota?.windows ?? [],
                status: quota?.status ?? store.managedAccountStatuses[managedProvider]?[account.id] ?? .unavailable,
                error: store.managedAccountErrors[managedProvider]?[account.id],
                isSwitching: isSwitching,
                progressMessage: isSwitching ? store.accountSessionActionStatus : nil,
                actionDisabled: store.accountSessionActionInFlight && !isSwitching
            )
            return row
        }
        if !rows.contains(where: \.selected) {
            rows.insert(makeRow(
                id: "\(managedProvider.rawValue)-live",
                name: snapshot?.account ?? AppLocalization.string("Current session", locale: locale),
                selected: true,
                selectedAction: { Task { await store.refresh(provider: managedProvider) } },
                windows: snapshot?.windows ?? [],
                status: snapshot?.status
            ), at: 0)
        }
        return rows
    }

    private var defaultRow: CompactAccountRowModel {
        makeRow(
            id: "\(provider.rawValue)-current",
            name: snapshot?.account ?? AppLocalization.string("Current session", locale: locale),
            selected: true,
            selectedAction: { Task { await store.refresh(provider: provider) } }
        )
    }

    private func makeRow(
        id: String,
        name: String,
        selected: Bool,
        selectedAction: @escaping () -> Void,
        inactiveAction: (() -> Void)? = nil,
        windows: [UsageWindow] = [],
        status: ProviderStatus? = nil,
        plan: String? = nil,
        error: String? = nil,
        isSwitching: Bool = false,
        progressMessage: String? = nil,
        actionDisabled: Bool = false
    ) -> CompactAccountRowModel {
        let account = accountParts(name)
        return CompactAccountRowModel(
            id: id,
            name: account.name,
            plan: plan ?? account.plan,
            selected: selected,
            action: selected ? selectedAction : (inactiveAction ?? selectedAction),
            windows: windows,
            status: status,
            error: error,
            isSwitching: isSwitching,
            progressMessage: progressMessage,
            actionDisabled: actionDisabled
        )
    }

    private func accountParts(_ value: String) -> (name: String, plan: String?) {
        let parts = value.components(separatedBy: " · ")
        guard parts.count > 1 else { return (value, nil) }
        let rawPlan = parts.dropFirst().joined(separator: " · ")
        let plan = provider == .claude ? UsageParsing.friendlyPlan(rawPlan) : rawPlan
        return (parts[0], plan)
    }

}

private struct CompactAccountRowModel: Identifiable {
    let id: String
    let name: String
    let plan: String?
    let selected: Bool
    let action: () -> Void
    let windows: [UsageWindow]
    let status: ProviderStatus?
    let error: String?
    let isSwitching: Bool
    let progressMessage: String?
    let actionDisabled: Bool
}

private struct CompactAccountRow: View {
    @AppStorage("showPopoverResetTimes") private var showResetTimes = false
    @Environment(\.locale) private var locale
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
                    if row.isSwitching {
                        ProgressView().controlSize(.mini).frame(width: 12)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(PopoverColorTokens.selectedIndicator(provider, colorScheme: colorScheme))
                            .frame(width: 12)
                            .opacity(row.selected ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    Text(row.name)
                        .font(.system(size: 12, weight: .semibold))
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
                            .truncationMode(.tail)
                            .frame(maxWidth: 105, alignment: .trailing)
                            .help(plan)
                    }
                }
                HStack(spacing: 6) {
                    Color.clear.frame(width: 12)
                    Text(row.progressMessage ?? row.error ?? usageSummary)
                        .font(.system(size: 12, weight: .regular).monospacedDigit())
                        .foregroundStyle(row.error != nil && !row.isSwitching || (status == .authenticationRequired && row.selected)
                            ? UsageTheme.critical
                            : PopoverColorTokens.secondaryText(colorScheme: colorScheme, increasedContrast: increasedContrast))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let commandCodeDetail {
                    HStack(spacing: 6) {
                        Color.clear.frame(width: 12)
                        Text(commandCodeDetail)
                            .font(.system(size: 10, weight: .regular).monospacedDigit())
                            .foregroundStyle(PopoverColorTokens.secondaryText(colorScheme: colorScheme, increasedContrast: increasedContrast))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if showResetTimes, let resetSummary {
                    HStack(spacing: 6) {
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
            .padding(.vertical, 6)
            .popoverGlass(
                in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                tint: PopoverColorTokens.rowHoverTint(provider, colorScheme: colorScheme).opacity(0.35),
                isActive: isHovered
            )
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .overlay {
                if isHovered && increasedContrast {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(PopoverColorTokens.separator, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.actionDisabled)
        .onHover { isHovered = $0 }
        .help(detailTooltip)
        .accessibilityLabel(detailTooltip)
        .accessibilityHint(AppLocalization.string("Activate this account or refresh its usage", locale: locale))
        .accessibilityAddTraits(row.selected ? .isSelected : [])
    }

    private var usageSummary: String {
        if status == .authenticationRequired { return AppLocalization.string("Sign-in expired", locale: locale) }

        if provider == .cursor {
            let cursorParts = windows.compactMap { window -> String? in
                guard let value = window.validUtilization else { return nil }
                let sourceLabel = window.label.lowercased()
                let label: String
                if sourceLabel.contains("plan") { label = "Plan" }
                else if sourceLabel.contains("auto") || sourceLabel.contains("composer") { label = "Auto" }
                else if sourceLabel.contains("api") { label = "API" }
                else { label = window.label }
                let percentage = value.formatted(.number.precision(.fractionLength(0)).locale(locale))
                return "\(label) \(percentage)%"
            }
            if !cursorParts.isEmpty { return cursorParts.joined(separator: " · ") }
        }

        if let fiveHour, fiveHour.validUtilization == 100 {
            return limitReachedSummary(label: "5h", window: fiveHour)
        }
        if let weekly, weekly.validUtilization == 100 {
            return limitReachedSummary(label: "Week", window: weekly)
        }

        if provider == .commandCode {
            let commandCodeParts = windows.compactMap { window -> String? in
                guard let value = window.validUtilization else { return nil }
                let label = window.id == fiveHour?.id ? "5h" : window.id == weekly?.id ? "Week" : window.label
                let percentage = value.formatted(.number.precision(.fractionLength(0)).locale(locale))
                return "\(label) \(percentage)%"
            }
            if !commandCodeParts.isEmpty { return commandCodeParts.joined(separator: " · ") }
        }

        let parts = [
            usageText(label: "5h", window: fiveHour),
            usageText(label: "Week", window: weekly)
        ].compactMap { $0 }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        if status == .rateLimited { return AppLocalization.string("Rate limited · Reset unavailable", locale: locale) }
        return AppLocalization.string("Usage unavailable", locale: locale)
    }

    /// Command Code's monthly pool: request count and days until the plan renews.
    private var commandCodeDetail: String? {
        guard provider == .commandCode, status != .authenticationRequired,
              let credits = windows.first(where: { $0.label == "Credits" }) else { return nil }
        var parts: [String] = []
        if let detail = credits.detail, !detail.isEmpty { parts.append(detail) }
        if let renewal = credits.resetsAt {
            let days = max(0, Int(ceil(renewal.timeIntervalSinceNow / 86_400)))
            parts.append(days == 1
                ? AppLocalization.string("1 day to renew", locale: locale)
                : String(format: AppLocalization.string("%d days to renew", locale: locale), locale: locale, arguments: [days]))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var resetSummary: String? {
        let quotaResets: [(String, UsageWindow?)] = [
            (AppLocalization.string("5h", locale: locale), fiveHour),
            (AppLocalization.string("Week", locale: locale), weekly)
        ]
        let parts = quotaResets.compactMap { label, window -> String? in
            guard let window else { return nil }
            let reset = window.resetsAt.map(resetTimeLabel) ?? AppLocalization.string("Unavailable", locale: locale)
            return "\(label) \(reset)"
        }
        guard !parts.isEmpty else { return nil }
        return "\(AppLocalization.string("Reset", locale: locale)) \(parts.joined(separator: " · "))"
    }

    private var detailTooltip: String {
        let state = status.title
        var lines = ["\(providerLabel) · \(state)", row.name]
        if let progressMessage = row.progressMessage { lines.append(progressMessage) }
        if let error = row.error { lines.append(error) }
        if let plan = row.plan, !plan.isEmpty {
            lines.append(String(
                format: AppLocalization.string("Plan: %@", locale: locale),
                locale: locale,
                arguments: [plan]
            ))
        }

        if windows.isEmpty {
            lines.append(AppLocalization.string("Usage unavailable", locale: locale))
        } else {
            for window in windows {
                let used = window.validUtilization.map {
                    String(format: AppLocalization.string("%@%% used", locale: locale), locale: locale, arguments: [$0.formatted(.number.precision(.fractionLength(0...2)).locale(locale))])
                } ?? AppLocalization.string("Usage unavailable", locale: locale)
                lines.append("\(window.label) · \(used)")
                let reset = window.resetsAt.map(resetTimeLabel) ?? AppLocalization.string("Reset unavailable", locale: locale)
                lines.append("\(AppLocalization.string("Reset", locale: locale)) \(reset)")
                if let detail = window.detail, !detail.isEmpty { lines.append(detail) }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func resetTimeLabel(_ date: Date) -> String {
        if Calendar.autoupdatingCurrent.isDateInToday(date) {
            return "\(AppLocalization.string("Today", locale: locale)) · \(date.formatted(.dateTime.locale(locale).hour().minute()))"
        }
        return date.formatted(.dateTime.locale(locale).weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    private func usageText(label: String, window: UsageWindow?) -> String? {
        guard let window, let percentage = window.validUtilization else { return nil }
        let value = percentage.formatted(.number.precision(.fractionLength(0)).locale(locale))
        if label == "5h" {
            return String(format: AppLocalization.string("5h %@%% used", locale: locale), locale: locale, arguments: [value])
        }
        return String(format: AppLocalization.string("Week %@%% used", locale: locale), locale: locale, arguments: [value])
    }

    private func limitReachedSummary(label: String, window: UsageWindow) -> String {
        guard let date = window.resetsAt else {
            if label == "5h" { return AppLocalization.string("5h limit reached · Reset unavailable", locale: locale) }
            return AppLocalization.string("Week limit reached · Reset unavailable", locale: locale)
        }
        let reset = date.formatted(.dateTime.locale(locale).hour().minute())
        if label == "5h" {
            return String(format: AppLocalization.string("5h limit reached · resets %@", locale: locale), locale: locale, arguments: [reset])
        }
        return String(format: AppLocalization.string("Week limit reached · resets %@", locale: locale), locale: locale, arguments: [reset])
    }
}

private struct CompactPopoverFooter: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.locale) private var locale
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
                Text(lastRefresh.map {
                    String(
                        format: AppLocalization.string("Updated %@", locale: locale),
                        locale: locale,
                        arguments: [$0.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))]
                    )
                } ?? AppLocalization.string("Not refreshed", locale: locale))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(PopoverColorTokens.secondaryText(colorScheme: colorScheme, increasedContrast: colorSchemeContrast == .increased))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(lastRefresh.map {
                        String(
                            format: AppLocalization.string("Last updated %@", locale: locale),
                            locale: locale,
                            arguments: [$0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale))]
                        )
                    } ?? AppLocalization.string("Usage has not been refreshed", locale: locale))

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
        .help(AppLocalization.string(label, locale: locale))
        .accessibilityLabel(AppLocalization.string(label, locale: locale))
    }
}
