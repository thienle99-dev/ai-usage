import AppKit
import SwiftUI

struct AddAccountWindowView: View {
    @Environment(UsageStore.self) private var store
    @Environment(AccountLoginCoordinator.self) private var login
    @Environment(\.openURL) private var openURL
    @State private var code = ""
    @State private var saveRowHovered = false
    @State private var signInRowHovered = false

    private var providerAccent: Color {
        switch login.provider {
        case .claude: Color(red: 217.0 / 255.0, green: 119.0 / 255.0, blue: 87.0 / 255.0)
        case .codex: Color(red: 22.0 / 255.0, green: 122.0 / 255.0, blue: 112.0 / 255.0)
        case .antigravity: Color(red: 92.0 / 255.0, green: 129.0 / 255.0, blue: 225.0 / 255.0)
        default: .accentColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            providerPicker

            VStack(spacing: 4) {
                actionRow(
                    title: "Save current account",
                    description: login.provider == .antigravity
                        ? "Save the account currently signed in to Antigravity."
                        : "Save the account already authenticated on this Mac.",
                    symbol: "bookmark.plus",
                    isHovered: $saveRowHovered,
                    action: login.saveCurrentAccount
                )
                .disabled(login.isRunning)
                .accessibilityIdentifier("add-account-save-current")

                if login.provider == .antigravity {
                    actionRow(
                        title: "Open Antigravity",
                        description: "Switch Google accounts in Antigravity, then save the signed-in account here.",
                        symbol: "rectangle.portrait.and.arrow.right",
                        isHovered: $signInRowHovered,
                        action: openAntigravity
                    )
                    .accessibilityIdentifier("add-account-open-antigravity")
                } else {
                    actionRow(
                        title: "Sign in to another account",
                        description: "Start authentication for a different account.",
                        symbol: "rectangle.portrait.and.arrow.right",
                        isHovered: $signInRowHovered,
                        action: login.beginSignIn
                    )
                    .disabled(login.isRunning)
                    .accessibilityIdentifier("add-account-sign-in-another")
                }
            }

            if login.isRunning || login.phase == .interrupted {
                signInProgress
            } else if case .failed(let error) = login.phase {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(UsageTheme.critical)
                    Button("Try again") { login.beginSignIn() }
                }
            } else if login.phase == .cancelled {
                Text("Sign-in cancelled.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if login.phase == .succeeded {
                Label(login.message, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            } else if !login.message.isEmpty {
                Text(login.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if login.provider == .antigravity, let error = store.antigravityAccountError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(UsageTheme.critical)
            }

            if !login.accounts.isEmpty {
                savedAccounts
            }
        }
        .padding(20)
        .frame(width: 440, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: login.requestsCode) { _, requested in
            if requested { code = "" }
        }
    }

    private var providerPicker: some View {
        Picker("Tool", selection: Binding(
            get: { login.provider },
            set: { login.select($0) }
        )) {
            Text("Claude Code").tag(Provider.claude)
            Text("Codex").tag(Provider.codex)
            Text("Antigravity").tag(Provider.antigravity)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .font(.system(size: 14, weight: .medium))
        .tint(providerAccent)
        .disabled(login.isRunning || login.phase == .interrupted)
        .accessibilityLabel(Text("Tool"))
        .accessibilityIdentifier("add-account-provider-picker")
    }

    private func actionRow(
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        symbol: String,
        isHovered: Binding<Bool>,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(providerAccent)
                    .frame(width: 22)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(
                isHovered.wrappedValue ? Color.primary.opacity(0.06) : .clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .onHover { isHovered.wrappedValue = $0 }
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var signInProgress: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(login.message.isEmpty ? "Sign-in in progress…" : login.message)
                    .font(.system(size: 12))
                Spacer(minLength: 8)
                if login.phase == .interrupted {
                    Button("Resume sign-in") { login.resumeInterruptedSignIn() }
                    Button("Cancel", role: .cancel) { Task { await login.cancel() } }
                } else {
                    Button("Cancel", role: .cancel) { Task { await login.cancel() } }
                        .disabled(login.phase == .verifying || login.phase == .saving)
                }
            }
            if let url = login.loginURL {
                HStack(spacing: 8) {
                    Button("Open sign-in page") { openURL(url) }
                    Button("Copy link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                }
            }
            if login.requestsCode {
                HStack {
                    TextField("Enter sign-in code", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submitCode)
                    Button("Submit code", action: submitCode)
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(12)
        .background(UsageTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
    }

    private var savedAccounts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Saved accounts")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(login.accounts) { account in
                        accountRow(account)
                        if account.id != login.accounts.last?.id { Divider() }
                    }
                }
            }
            .frame(maxHeight: 120)

            if login.phase == .succeeded {
                Button("Add another account") { login.resetForAnotherAccount() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func accountRow(_ account: ManagedAccountRecord) -> some View {
        let activeID: String?
        switch login.provider {
        case .claude: activeID = store.claudeCodeInUseAccountID
        case .codex: activeID = store.codexInUseAccountID
        case .antigravity: activeID = store.activeAntigravityAccountID
        default: activeID = nil
        }
        let isActive = account.id == activeID
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(account.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text(isActive ? "In use" : "Saved")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if login.provider != .antigravity,
               let error = store.managedAccountErrors[login.provider]?[account.id],
               error.localizedCaseInsensitiveContains("auth") || error.localizedCaseInsensitiveContains("credential") {
                Button("Sign in again") { login.beginSignIn() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }

    private func submitCode() {
        login.submitCode(code.trimmingCharacters(in: .whitespacesAndNewlines))
        code = ""
    }

    private func openAntigravity() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.antigravity") {
            NSWorkspace.shared.open(appURL)
        } else {
            store.antigravityAccountError = String(localized: "Antigravity.app could not be found.")
        }
    }
}
