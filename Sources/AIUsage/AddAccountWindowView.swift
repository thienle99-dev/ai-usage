import AppKit
import SwiftUI

struct AddAccountWindowView: View {
    @Environment(UsageStore.self) private var store
    @Environment(AccountLoginCoordinator.self) private var login
    @Environment(\.openURL) private var openURL
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add account")
                .font(.system(size: 22, weight: .semibold))
            Picker("Tool", selection: Binding(
                get: { login.provider },
                set: { login.select($0) }
            )) {
                Text("Claude Code").tag(Provider.claude)
                Text("Codex").tag(Provider.codex)
            }
            .pickerStyle(.segmented)
            .disabled(login.isRunning || login.phase == .interrupted)

            HStack(spacing: 10) {
                Button("Save current account") { login.saveCurrentAccount() }
                    .disabled(login.isRunning)
                Button("Sign in to another account") { login.beginSignIn() }
                    .buttonStyle(.borderedProminent)
                    .disabled(login.isRunning)
            }

            if login.isRunning || login.phase == .interrupted {
                signInProgress
            } else if case .failed(let error) = login.phase {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(UsageTheme.critical)
                Button("Try again") { login.beginSignIn() }
            } else if login.phase == .cancelled {
                Text("Sign-in cancelled.").foregroundStyle(UsageTheme.secondaryText)
            } else if login.phase == .succeeded {
                Label(login.message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if !login.message.isEmpty {
                Text(login.message).foregroundStyle(UsageTheme.secondaryText)
            }

            if !login.accounts.isEmpty {
                Divider()
                Text("Saved accounts").font(.system(size: 14, weight: .semibold))
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(login.accounts) { account in
                            accountRow(account)
                            if account.id != login.accounts.last?.id { Divider() }
                        }
                    }
                }
                if login.phase == .succeeded {
                    Button("Add another account") { login.resetForAnotherAccount() }
                        .buttonStyle(.bordered)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(minWidth: 500, minHeight: 380)
        .onChange(of: login.requestsCode) { _, requested in
            if requested { code = "" }
        }
    }

    @ViewBuilder private var signInProgress: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(login.message.isEmpty ? "Sign-in in progress…" : login.message)
                    .font(.system(size: 12))
                Spacer()
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

    private func accountRow(_ account: ManagedAccountRecord) -> some View {
        let activeID = login.provider == .claude ? store.claudeCodeInUseAccountID : store.codexInUseAccountID
        let isActive = account.id == activeID
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(account.label).font(.system(size: 12, weight: .medium))
                Text(isActive ? "In use" : "Saved")
                    .font(.system(size: 10)).foregroundStyle(UsageTheme.secondaryText)
            }
            Spacer()
            if let error = store.managedAccountErrors[login.provider]?[account.id], error.localizedCaseInsensitiveContains("auth") || error.localizedCaseInsensitiveContains("credential") {
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
}
