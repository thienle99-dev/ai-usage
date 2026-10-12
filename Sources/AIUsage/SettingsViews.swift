import SwiftUI
import AppKit

// MARK: - Sidebar

struct SettingsSidebarView: View {
    @Binding var selection: String

    var body: some View {
        List(selection: Binding<String?>(
            get: { selection },
            set: { selection = $0 ?? "General" }
        )) {
            Label("General", systemImage: "gearshape").tag("General")
            Label("Appearance", systemImage: "circle.lefthalf.filled").tag("Appearance")
            Label("Providers", systemImage: "square.grid.2x2").tag("Providers")
            Label("About", systemImage: "info.circle").tag("About")
        }
        .listStyle(.sidebar)
        .font(.system(size: 13))
        .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 190)
    }
}

// MARK: - Page scaffolding

struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPageHeader(title: title, subtitle: subtitle)
            content
        }
    }
}

private struct SettingsPageHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(UsageTheme.primaryText)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(UsageTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(UsageTheme.secondaryText)
                .padding(.leading, 10)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                UsageTheme.card,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(UsageTheme.separator.opacity(0.8), lineWidth: 0.7)
            )
        }
    }
}

struct SettingsRowDivider: View {
    var body: some View {
        Rectangle().fill(UsageTheme.separator).frame(height: 1)
    }
}

// MARK: - Rows

struct SettingsRow<Control: View>: View {
    let icon: String?
    let iconColor: Color
    let title: String
    let description: String?
    let tooltip: String?
    @ViewBuilder let control: Control

    init(
        icon: String? = nil,
        iconColor: Color = UsageTheme.secondaryText,
        title: String,
        description: String? = nil,
        tooltip: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.description = description
        self.tooltip = tooltip
        self.control = control()
    }

    var body: some View {
        Group {
            if let tooltip {
                rowContent.help(tooltip)
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(iconColor)
                    .frame(width: 22)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(UsageTheme.primaryText)
                if let description {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(UsageTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.vertical, 7)
        .frame(minHeight: 44)
    }
}

struct SettingsToggleRow: View {
    let icon: String?
    let iconColor: Color
    let title: String
    let description: String?
    let tooltip: String?
    @Binding var isOn: Bool

    init(
        icon: String? = nil,
        iconColor: Color = UsageTheme.secondaryText,
        title: String,
        description: String? = nil,
        tooltip: String? = nil,
        isOn: Binding<Bool>
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.description = description
        self.tooltip = tooltip
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(icon: icon, iconColor: iconColor, title: title, description: description, tooltip: tooltip) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(title)
        }
    }
}

struct SettingsPickerRow<Selection: Hashable, Content: View>: View {
    let icon: String?
    let title: String
    let description: String?
    let tooltip: String?
    let selection: Binding<Selection>
    @ViewBuilder let options: Content

    init(
        icon: String? = nil,
        title: String,
        description: String? = nil,
        tooltip: String? = nil,
        selection: Binding<Selection>,
        @ViewBuilder options: () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.description = description
        self.tooltip = tooltip
        self.selection = selection
        self.options = options()
    }

    var body: some View {
        SettingsRow(icon: icon, title: title, description: description, tooltip: tooltip) {
            Picker("", selection: selection) { options }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 200, alignment: .trailing)
                .accessibilityLabel(title)
        }
    }
}

struct SettingsDetailRow: View {
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

struct ThresholdSettingRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(UsageTheme.primaryText)
                .frame(width: 64, alignment: .leading)
            Slider(value: $value, in: range, step: 5)
                .tint(color)
            Text("\(Int(value))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(color))
                .frame(minWidth: 48)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) threshold")
        .accessibilityValue("\(Int(value)) percent")
    }
}

struct SettingsErrorText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(UsageTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    var store: Bindable<UsageStore>
    @State private var claudeStatusLineState: ClaudeStatusLineManager.State = .notInstalled
    @State private var claudeStatusLineError: String?

    var body: some View {
        SettingsPage(title: "General", subtitle: "Configure your AI usage monitor.") {
            SettingsSection(title: "Menu Bar") {
                SettingsPickerRow(
                    title: "Display",
                    description: store.wrappedValue.menuBarMode == .singleProvider
                        ? "Shows the selected provider's highest window. Falls back to combined usage while it is hidden."
                        : "Combined usage uses the highest valid percentage across enabled usage windows.",
                    tooltip: "Choose what appears in the menu bar.",
                    selection: store.menuBarMode
                ) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                if store.wrappedValue.menuBarMode == .singleProvider {
                    SettingsRowDivider()
                    SettingsPickerRow(title: "Provider", selection: store.menuBarProvider) {
                        ForEach(Provider.supported) { provider in Text(provider.displayName).tag(provider) }
                    }
                }
            }
            SettingsSection(title: "Refresh") {
                SettingsPickerRow(
                    title: "Automatic refresh",
                    description: store.wrappedValue.refreshPolicy == .manual
                        ? "The app fetches once at startup; later refreshes require the Refresh button."
                        : "Cached usage stays visible while providers refresh independently.",
                    selection: store.refreshPolicy
                ) {
                    ForEach(RefreshPolicy.allCases) { policy in Text(policy.title).tag(policy) }
                }
            }
            SettingsSection(title: "Automation") {
                SettingsToggleRow(
                    icon: "arrow.clockwise.circle",
                    iconColor: UsageTheme.warning,
                    title: "Start a new window after reset",
                    description: "Sends a short request with Claude Code, Codex, or Antigravity CLI and uses a small amount of quota. Off by default; runs only after a confirmed reset.",
                    tooltip: "Only supported providers with verified reset signals are eligible.",
                    isOn: store.autoStartUsageWindow
                )
            }
            SettingsSection(title: "CLI Integration") {
                HStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .font(.system(size: 16))
                        .foregroundStyle(UsageTheme.claude)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude Code status line")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(UsageTheme.primaryText)
                        Text(claudeStatusLineDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(UsageTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Button(claudeStatusLineButtonTitle) {
                        toggleClaudeStatusLine()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(claudeStatusLineIsCustom)
                }
                .padding(.vertical, 7)
                .frame(minHeight: 44)
                if let claudeStatusLineError {
                    SettingsRowDivider()
                    SettingsErrorText(text: claudeStatusLineError)
                        .padding(.vertical, 4)
                }
            }
            SettingsSection(title: "Notifications") {
                SettingsToggleRow(
                    icon: "bell",
                    iconColor: UsageTheme.warning,
                    title: "Quota notifications",
                    description: "Notify when a usage window crosses warning or critical, and when it recovers. One alert per provider and window until it recovers.",
                    isOn: Binding(
                        get: { store.wrappedValue.quotaNotificationsEnabled },
                        set: {
                            store.wrappedValue.quotaNotificationsEnabled = $0
                            if $0 {
                                let deliverer = UserNotificationQuotaDeliverer()
                                Task { _ = await deliverer.requestAuthorization() }
                            }
                        }
                    )
                )
            }
            SettingsSection(title: "Launch") {
                SettingsToggleRow(
                    icon: "power",
                    title: "Launch at login",
                    description: "Automatically start AI Usage Monitor when you log in.",
                    isOn: Binding(
                        get: { store.wrappedValue.launchAtLoginEnabled },
                        set: { store.wrappedValue.setLaunchAtLogin($0) }
                    )
                )
                if let error = store.wrappedValue.launchAtLoginError {
                    SettingsRowDivider()
                    SettingsErrorText(text: error)
                        .padding(.vertical, 4)
                }
            }
            SettingsSection(title: "Visible providers") {
                ForEach(Array(Provider.supported.enumerated()), id: \.element.id) { index, provider in
                    if index > 0 { SettingsRowDivider() }
                    HStack(spacing: 10) {
                        Image(systemName: provider.systemImage)
                            .font(.system(size: 16))
                            .foregroundStyle(UsageTheme.provider(provider))
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(provider.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(UsageTheme.primaryText)
                            Text(providerSource(provider))
                                .font(.system(size: 11))
                                .foregroundStyle(UsageTheme.secondaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        if ProviderConfigFile.url(for: provider) != nil {
                            ProviderConfigButton(provider: provider)
                        }
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
                        .toggleStyle(.switch)
                        .accessibilityLabel(provider.displayName)
                    }
                    .padding(.vertical, 7)
                    .frame(minHeight: 44)
                }
            }
        }
        .onAppear(perform: refreshClaudeStatusLineState)
    }

    private var claudeStatusLineDescription: String {
        switch claudeStatusLineState {
        case .installed:
            "Shows quota from the local cache. It never makes requests; Claude Code may need a restart."
        case .customStatusLine:
            "A custom status line is already configured. AI Usage Monitor will leave it untouched."
        case .unavailable:
            "Could not read Claude Code settings."
        case .notInstalled:
            "Show cached Claude quota in Claude Code. Installs only when no status line is configured."
        }
    }

    private var claudeStatusLineButtonTitle: String {
        if case .installed = claudeStatusLineState { return "Remove" }
        return "Install"
    }

    private var claudeStatusLineIsCustom: Bool {
        if case .customStatusLine = claudeStatusLineState { return true }
        if case .unavailable = claudeStatusLineState { return true }
        return false
    }

    private func refreshClaudeStatusLineState() {
        claudeStatusLineState = ClaudeStatusLineManager.state(
            settingsURL: ClaudeStatusLineManager.settingsURL(),
            ownershipURL: ClaudeStatusLineManager.ownershipURL()
        )
    }

    private func toggleClaudeStatusLine() {
        let settingsURL = ClaudeStatusLineManager.settingsURL()
        let ownershipURL = ClaudeStatusLineManager.ownershipURL()
        do {
            if case .installed = claudeStatusLineState {
                try ClaudeStatusLineManager.uninstall(settingsURL: settingsURL, ownershipURL: ownershipURL)
            } else {
                let executableURL = Bundle.main.executableURL
                    ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
                try ClaudeStatusLineManager.install(
                    executableURL: executableURL,
                    settingsURL: settingsURL,
                    ownershipURL: ownershipURL
                )
            }
            claudeStatusLineError = nil
        } catch {
            claudeStatusLineError = error.localizedDescription
        }
        refreshClaudeStatusLineState()
    }
}

private struct ProviderConfigButton: View {
    @Environment(UsageStore.self) private var store
    let provider: Provider
    @State private var message: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button("Open Config") {
                guard let configURL = ProviderConfigFile.url(for: provider) else { return }
                if NSWorkspace.shared.open(configURL) {
                    message = nil
                } else {
                    message = "Could not open \(provider.displayName) config at \(configURL.path)."
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!(ProviderConfigFile.url(for: provider).map { ProviderConfigFile.exists($0) } ?? false))
            .help(ProviderConfigFile.url(for: provider).map {
                ProviderConfigFile.exists($0) ? "Open \($0.path)" : "Config file not found: \($0.path)"
            } ?? "")
            if let message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(UsageTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    var store: Bindable<UsageStore>

    var body: some View {
        SettingsPage(title: "Appearance", subtitle: "Match System Appearance, or choose Light or Dark.") {
            SettingsSection(title: "Appearance") {
                SettingsRow(title: "Color scheme") {
                    Picker("", selection: store.appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                    .accessibilityLabel("Color scheme")
                }
            }
            SettingsSection(title: "Usage thresholds") {
                ThresholdSettingRow(label: "Warning", value: store.warningThreshold, range: 50...95, color: UsageTheme.warning)
                SettingsRowDivider()
                ThresholdSettingRow(label: "Critical", value: store.criticalThreshold, range: 70...100, color: UsageTheme.critical)
                Text("Threshold colors apply to valid usage values in cards and the menu bar.")
                    .font(.system(size: 11))
                    .foregroundStyle(UsageTheme.secondaryText)
                    .padding(.vertical, 4)
            }
            UsageCardLayoutSettings()
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
        SettingsSection(title: "Usage Card Layout") {
            Text("Overview Layout")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(UsageTheme.primaryText)
            layoutGrid(selection: overviewSelection)
            SettingsRowDivider()
            Text("Provider Detail Layout")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(UsageTheme.primaryText)
            layoutGrid(selection: detailSelection).disabled(useUnifiedLayout)
            if useUnifiedLayout {
                Text("Overview Layout is used for both Overview and Provider Detail.")
                    .font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryText)
            }
            SettingsRowDivider()
            SettingsToggleRow(
                title: "Use the same layout everywhere",
                isOn: $useUnifiedLayout
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title: "Start collapsible cards expanded",
                description: "Applies when a collapsible layout is selected.",
                isOn: $initiallyExpanded
            )
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
        .padding(.vertical, 4)
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

// MARK: - Providers

struct ProvidersSettingsView: View {
    @Environment(UsageStore.self) private var store
    @State private var expandedProviders = Set(Provider.supported.map(\.rawValue))
    @State private var cursorCookieHeader = ""
    @State private var cursorCredentialMessage: String?
    @State private var cursorHasStoredCookie = CursorCredentialVault.hasStoredCookie
    @State private var openCodeCookieHeader = ""
    @State private var openCodeCredentialMessage: String?
    @State private var openCodeHasStoredCookie = OpenCodeCredentialVault.hasStoredCookie
    @State private var codexHomeMessage: String?

    var body: some View {
        SettingsPage(title: "Providers", subtitle: "Accounts, status, and usage sources.") {
            SettingsSection(title: "Providers") {
                ForEach(Array(Provider.supported.enumerated()), id: \.element.id) { index, provider in
                    if index > 0 { SettingsRowDivider() }
                    providerRow(provider)
                }
            }
            SettingsSection(title: "Codex homes") {
                codexHomesContent
            }
            SettingsSection(title: "Cursor session") {
                cursorContent
            }
            CopilotSessionContent()
            SettingsSection(title: "OpenCode session") {
                openCodeContent
            }
        }
    }

    private func expansionBinding(for provider: Provider) -> Binding<Bool> {
        Binding(
            get: { expandedProviders.contains(provider.rawValue) },
            set: {
                if $0 { expandedProviders.insert(provider.rawValue) }
                else { expandedProviders.remove(provider.rawValue) }
            }
        )
    }

    @ViewBuilder
    private func providerRow(_ provider: Provider) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(for: provider)) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsDetailRow(label: "Status", value: store.status(for: provider).title)
                ForEach(store.publicServiceIncidents[provider] ?? []) { incident in
                    SettingsRowDivider()
                    ServiceIncidentNotice(incident: incident)
                        .padding(.vertical, 7)
                }
                if let snapshot = store.snapshots[provider] {
                    if let account = snapshot.account {
                        SettingsRowDivider()
                        SettingsDetailRow(label: "Account", value: account)
                    }
                    if snapshot.lastSuccess != .distantPast {
                        SettingsRowDivider()
                        SettingsDetailRow(
                            label: "Last successful update",
                            value: snapshot.lastSuccess.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                    if let error = snapshot.error {
                        Text("Local usage fetch failed · \(error)")
                            .font(.system(size: 11))
                            .foregroundStyle(UsageTheme.warning)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 6)
                    }
                }
                SettingsRowDivider()
                SettingsDetailRow(label: "Source", value: providerSource(provider))
                Text(providerHelp(provider))
                    .font(.system(size: 11))
                    .foregroundStyle(UsageTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
                HStack {
                    Spacer()
                    Button("Refresh") { Task { await store.refresh(provider: provider) } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.refreshing.contains(provider))
                        .help("Refresh \(provider.displayName) now")
                }
                .padding(.bottom, 4)
            }
            .padding(.leading, 32)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: provider.systemImage)
                    .font(.system(size: 16))
                    .foregroundStyle(UsageTheme.provider(provider))
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(UsageTheme.primaryText)
                    if let account = store.snapshots[provider]?.account {
                        Text(account)
                            .font(.system(size: 11))
                            .foregroundStyle(UsageTheme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                ConnectionStatusView(
                    status: store.status(for: provider),
                    isRefreshing: store.refreshing.contains(provider)
                )
            }
            .padding(.vertical, 7)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("\(provider.displayName), \(store.status(for: provider).title)")
        }
    }

    @ViewBuilder
    private var codexHomesContent: some View {
        Text("Registered Codex home folders. Making one active moves it into ~/.codex so it becomes live; the current live folder moves back to its slot. Only folders move — credentials are never read or changed here.")
            .font(.system(size: 11))
            .foregroundStyle(UsageTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
        if store.codexLiveHomeIsUnregistered {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(UsageTheme.warning)
                Text("The live folder doesn't match any registered home. Tell the app where this folder belongs when it's not active, then switching works.")
                    .font(.system(size: 11))
                    .foregroundStyle(UsageTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            HStack {
                Spacer()
                Button("Assign home slot…") { assignCodexHomeSlotWithPanel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.codexSwitchInFlight)
            }
            .padding(.bottom, 2)
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
            .padding(.vertical, 4)
        } else {
            ForEach(Array(store.codexHomes.enumerated()), id: \.element.id) { index, home in
                if index > 0 { SettingsRowDivider() }
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 15))
                        .foregroundStyle(UsageTheme.secondaryText)
                        .frame(width: 22)
                        .accessibilityHidden(true)
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
                    .accessibilityLabel("Remove \(home.displayName)")
                }
                .padding(.vertical, 6)
                .frame(minHeight: 44)
            }
            HStack {
                Spacer()
                Button("Add folder…") { addCodexHomeWithPanel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.codexSwitchInFlight)
            }
            .padding(.vertical, 2)
        }
        if let error = store.codexSwitchError {
            SettingsErrorText(text: error)
                .padding(.vertical, 4)
        }
        if let message = codexHomeMessage {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(UsageTheme.secondaryText)
                .padding(.vertical, 2)
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

    @ViewBuilder
    private var cursorContent: some View {
        Text("AI Usage Monitor reads Cursor.app's signed-in session locally and calls Cursor's usage summary. If that session is unavailable, you can supply a cursor.com session cookie as a fallback.")
            .font(.system(size: 11))
            .foregroundStyle(UsageTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
        SecureField("Optional cursor.com Cookie header", text: $cursorCookieHeader)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
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
        .padding(.vertical, 4)
        if let cursorCredentialMessage {
            Text(cursorCredentialMessage)
                .font(.system(size: 11))
                .foregroundStyle(UsageTheme.secondaryText)
        }
        Text("Cursor's usage-summary endpoint is undocumented and may change. The billing-cycle end is shown when returned. Never paste a cookie into logs or screenshots.")
            .font(.system(size: 11))
            .foregroundStyle(UsageTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
    }

    @ViewBuilder
    private var openCodeContent: some View {
        Text("OpenCode usage comes from its authenticated dashboard. Paste the Cookie header from an OpenCode browser session; the app keeps only OpenCode auth cookies in macOS Keychain.")
            .font(.system(size: 11))
            .foregroundStyle(UsageTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
        SecureField("OpenCode Cookie header", text: $openCodeCookieHeader)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
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
        .padding(.vertical, 4)
        if let openCodeCredentialMessage {
            Text(openCodeCredentialMessage)
                .font(.system(size: 11))
                .foregroundStyle(UsageTheme.secondaryText)
        }
        Text("OpenCode's dashboard API is undocumented and may change. Session cookies expire; never paste them into logs or screenshots.")
            .font(.system(size: 11))
            .foregroundStyle(UsageTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
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
}

private struct CopilotSessionContent: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var status: String?
    @State private var userCode: String?
    @State private var signInTask: Task<Void, Never>?
    @State private var hasToken = CopilotCredentialVault.hasToken

    var body: some View {
        SettingsSection(title: "GitHub Copilot") {
            Text("Connect with GitHub's public OAuth device flow. The access token is stored in macOS Keychain and used to read Copilot quota.")
                .font(.system(size: 11))
                .foregroundStyle(UsageTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
            if let userCode {
                Text("Enter code \(userCode) at github.com/login/device")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Link("Open GitHub device login", destination: URL(string: "https://github.com/login/device")!)
                    Spacer()
                    Button("Cancel sign in", role: .cancel) { cancelSignIn() }
                }
                .padding(.vertical, 4)
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
            .padding(.vertical, 4)
            if let status { Text(status).font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryText) }
            Text("Quota data comes from GitHub's undocumented Copilot usage API; available quota types depend on your plan.")
                .font(.system(size: 11))
                .foregroundStyle(UsageTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
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

func providerSource(_ provider: Provider) -> String {
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

func providerHelp(_ provider: Provider) -> String {
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

// MARK: - About

struct AboutSettingsView: View {
    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        SettingsPage(title: "About", subtitle: nil) {
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
                    Text(versionText)
                        .font(.system(size: 11))
                        .foregroundStyle(UsageTheme.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)
            SettingsSection(title: "Overview") {
                Text("A native menu bar utility for Claude Code, Codex, Cursor, GitHub Copilot, Gemini CLI, Antigravity, Grok CLI, and OpenCode usage. Claude usage uses the Claude Code OAuth usage endpoint. Codex usage comes from the local `codex app-server`. Cursor, GitHub Copilot, Gemini CLI, and Antigravity usage use their session-authenticated APIs; Grok CLI usage comes from its local log. Provider interfaces can change.")
                    .font(.system(size: 12))
                    .foregroundStyle(UsageTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
            SettingsSection(title: "License") {
                Text("UI and integration references are MIT licensed: claude-usage-widget by bozdemir and codex-usage-bar by CMMUU.")
                    .font(.system(size: 11))
                    .foregroundStyle(UsageTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
        }
    }
}
