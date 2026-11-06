import Foundation
import SwiftUI

@MainActor protocol AccountLoginSessionVerifying {
    func verifyAndImport(provider: Provider, directory: URL, store: UsageStore) async throws -> ManagedAccountRecord
}

@MainActor struct LocalAccountLoginSessionVerifier: AccountLoginSessionVerifying {
    func verifyAndImport(provider: Provider, directory: URL, store: UsageStore) async throws -> ManagedAccountRecord {
        if provider == .codex {
            let payload = try await LocalCodexAppServerDataSource(codexHome: directory).read()
            let parsed = try UsageParsing.codex(payload)
            guard let identity = parsed.accountID, !identity.isEmpty else { throw AccountSessionError.unidentified }
            return try store.importAccount(for: .codex, reference: directory.path, fingerprint: identity, label: parsed.account ?? identity)
        }
        let credential = try ClaudeCodeCredentialVault.nativeCredential(configDirectory: directory)
        let token = try ClaudeCodeCredentialVault.accessToken(from: credential)
        let snapshot = try await ClaudeProvider(tokenProvider: { token }).fetch()
        let session = ClaudeCodeCredentialVault.sessionBundle(credential: credential, configDirectory: directory)
        let identity = ClaudeCodeSessionAdapter.fingerprint(session)
        return try store.importAccount(
            for: .claude,
            reference: String(decoding: session, as: UTF8.self),
            fingerprint: identity,
            label: snapshot.account ?? ClaudeCodeSessionAdapter.label(session)
        )
    }
}

enum ManagedLoginPhase: Equatable {
    case choosing, signingIn, verifying, saving, succeeded, cancelled, failed(String), interrupted
}

/// Owns the add-account flow and its isolated CLI process independently of the popover lifecycle.
@MainActor @Observable final class AccountLoginCoordinator {
    var provider: Provider = .claude
    var phase: ManagedLoginPhase = .choosing
    var message = ""
    var loginURL: URL?
    var requestsCode = false
    var accountLabel: String?
    var accounts: [ManagedAccountRecord] = []

    @ObservationIgnored private let store: UsageStore
    @ObservationIgnored private var process: (any AccountLoginProcessHandle)?
    @ObservationIgnored private var draftDirectory: URL?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var userCancelled = false
    @ObservationIgnored private var timedOut = false
    @ObservationIgnored private var outputTail = ""
    @ObservationIgnored private let processLauncher: any AccountLoginProcessLaunching
    @ObservationIgnored private let sessionVerifier: any AccountLoginSessionVerifying
    @ObservationIgnored private let draftRootURL: URL
    @ObservationIgnored private let cliExecutable: (Provider) throws -> URL

    var isRunning: Bool { process != nil || phase == .verifying || phase == .saving }

    init(
        store: UsageStore,
        processLauncher: any AccountLoginProcessLaunching = FoundationAccountLoginProcessLauncher(),
        sessionVerifier: any AccountLoginSessionVerifying = LocalAccountLoginSessionVerifier(),
        draftRootURL: URL? = nil,
        cliExecutable: ((Provider) throws -> URL)? = nil
    ) {
        self.store = store
        self.processLauncher = processLauncher
        self.sessionVerifier = sessionVerifier
        self.draftRootURL = draftRootURL ?? Self.defaultDraftRoot()
        self.cliExecutable = cliExecutable ?? { provider in
            let executable = try Self.findCLI(for: provider)
            try Self.confirmCLI(executable, provider: provider)
            return executable
        }
        if let draft = Self.readDraft(root: self.draftRootURL) {
            provider = draft.provider
            draftDirectory = draft.directory
            phase = .interrupted
            message = String(localized: "An interrupted sign-in can be resumed.")
        }
        reloadAccounts()
    }

    func select(_ provider: Provider) {
        guard (provider == .claude || provider == .codex), phase != .interrupted else { return }
        self.provider = provider
        if case .failed = phase { phase = .choosing }
        if phase == .succeeded || phase == .cancelled { phase = .choosing; message = "" }
        loginURL = nil
        requestsCode = false
        reloadAccounts()
    }

    func resetForAnotherAccount() {
        guard !isRunning else { return }
        phase = .choosing
        message = ""
        reloadAccounts()
    }

    func saveCurrentAccount() {
        phase = .saving
        do {
            try store.saveCurrentAccount(for: provider)
            phase = .succeeded
            message = String(localized: "Current account saved.")
            reloadAccounts()
            Task { await store.refreshManagedAccountQuotas() }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func beginSignIn() {
        guard !isRunning, phase != .interrupted else { return }
        do {
            let executable = try cliExecutable(provider)
            let directory = draftRootURL.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            draftDirectory = directory
            try Self.writeDraft(provider: provider, directory: directory, root: draftRootURL)
            userCancelled = false
            timedOut = false
            loginURL = nil
            requestsCode = false
            outputTail = ""
            phase = .signingIn
            message = String(localized: "Waiting for sign-in to finish in your browser.")
            launch(executable: executable, directory: directory)
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled else { return }
                await self?.cancel(timedOut: true)
            }
        } catch {
            cleanupDraft()
            phase = .failed(error.localizedDescription)
        }
    }

    func resumeInterruptedSignIn() {
        guard phase == .interrupted, draftDirectory != nil else { return }
        Task { await verifyAndSave() }
    }

    func submitCode(_ code: String) {
        guard !code.isEmpty, let process else { return }
        process.send(Data((code + "\n").utf8))
        requestsCode = false
    }

    func cancel(timedOut: Bool = false) async {
        if process == nil && (phase == .verifying || phase == .saving) { return }
        userCancelled = !timedOut
        self.timedOut = timedOut
        timeoutTask?.cancel()
        if let process, process.isRunning {
            process.terminate()
            try? await Task.sleep(for: .milliseconds(150))
        }
        if process == nil {
            cleanupDraft()
            phase = timedOut ? .failed(String(localized: "Sign-in timed out. Try again.")) : .cancelled
        }
    }

    private func launch(executable: URL, directory: URL) {
        let arguments: [String]
        if provider == .claude {
            arguments = ["auth", "login", "--claudeai"]
        } else {
            arguments = ["-c", "cli_auth_credentials_store=\"file\"", "login"]
        }
        var environment = ProcessInfo.processInfo.environment
        for key in ["CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_BEDROCK_BASE_URL", "ANTHROPIC_BEDROCK_REGION", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CODEX_ACCESS_TOKEN", "CODEX_ID_TOKEN", "CODEX_REFRESH_TOKEN", "OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_HOME", "CODEX_BINARY_PATH"] {
            environment.removeValue(forKey: key)
        }
        if provider == .claude {
            environment["CLAUDE_CONFIG_DIR"] = directory.path
        } else {
            environment["CODEX_HOME"] = directory.path
        }
        do {
            process = try processLauncher.launch(
                executable: executable,
                arguments: arguments,
                environment: environment,
                output: { [weak self] data in self?.consume(data) },
                termination: { [weak self] _ in
                    guard let self else { return }
                    self.process = nil
                    self.timeoutTask?.cancel()
                    if self.userCancelled || self.timedOut {
                        self.cleanupDraft()
                        self.phase = self.userCancelled ? .cancelled : .failed(String(localized: "Sign-in timed out. Try again."))
                    } else {
                        Task { await self.verifyAndSave() }
                    }
                }
            )
        } catch {
            process = nil
            cleanupDraft()
            phase = .failed(error.localizedDescription)
        }
    }

    private func consume(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        outputTail = String((outputTail + text).suffix(32_768))
        if let range = outputTail.range(of: #"https?://[^\s\"<>]+"#, options: .regularExpression),
           let url = URL(string: String(outputTail[range])) {
            loginURL = url
            message = String(localized: "Open the sign-in page, then return here.")
        }
        let lower = outputTail.lowercased()
        if lower.contains("paste") && (lower.contains("code") || lower.contains("verification")) {
            requestsCode = true
            message = String(localized: "Enter the code shown by the CLI.")
        } else if lower.contains("success") || lower.contains("complete") {
            message = String(localized: "Verifying account…")
        }
    }

    private func verifyAndSave() async {
        guard let directory = draftDirectory else {
            phase = .failed(String(localized: "Sign-in session could not be recovered."))
            return
        }
        phase = .verifying
        message = String(localized: "Verifying account…")
        do {
            let account = try await sessionVerifier.verifyAndImport(provider: provider, directory: directory, store: store)
            cleanupDraft()
            phase = .succeeded
            message = String(localized: "Account added. Your current account is unchanged.")
            reloadAccounts()
            await store.refreshManagedAccountQuota(for: provider, accountID: account.id)
        } catch {
            cleanupDraft()
            phase = .failed(error.localizedDescription)
        }
    }

    private func reloadAccounts() {
        accounts = provider == .claude ? store.claudeCodeAccounts : store.codexAccounts
    }

    private func cleanupDraft() {
        timeoutTask?.cancel()
        if let directory = draftDirectory {
            if provider == .claude { ClaudeCodeCredentialVault.removeTemporary(configDirectory: directory) }
            try? FileManager.default.removeItem(at: directory)
        }
        Self.removeDraft(root: draftRootURL)
        draftDirectory = nil
    }

    private static func defaultDraftRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIUsage/account-login", isDirectory: true)
    }

    private static func draftURL(root: URL) -> URL { root.appendingPathComponent("pending.json") }

    private static func writeDraft(provider: Provider, directory: URL, root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let draft = LoginDraft(provider: provider, directory: directory)
        try JSONEncoder().encode(draft).write(to: draftURL(root: root), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: draftURL(root: root).path)
    }

    private static func readDraft(root: URL) -> LoginDraft? {
        guard let data = try? Data(contentsOf: draftURL(root: root)) else { return nil }
        return try? JSONDecoder().decode(LoginDraft.self, from: data)
    }

    private static func removeDraft(root: URL) { try? FileManager.default.removeItem(at: draftURL(root: root)) }

    private static func findCLI(for provider: Provider) throws -> URL {
        let name = provider == .claude ? "claude" : "codex"
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/\(name)" }
            + ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/\(name)").path]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ProviderFailure.process(String(localized: provider == .claude ? "Claude CLI not found." : "Codex CLI not found."))
        }
        return URL(fileURLWithPath: path)
    }

    private static func confirmCLI(_ executable: URL, provider: Provider) throws {
        let loginHelp = try help(executable, arguments: provider == .claude ? ["auth", "login", "--help"] : ["login", "--help"])
        let rootHelp = try help(executable, arguments: ["--help"])
        if provider == .claude {
            guard loginHelp.contains("--claudeai") else { throw ProviderFailure.process(String(localized: "The installed Claude CLI does not support Claude.ai sign-in.")) }
        } else {
            guard rootHelp.contains("--config") else { throw ProviderFailure.process(String(localized: "The installed Codex CLI does not support isolated sign-in configuration.")) }
        }
    }

    private static func help(_ executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProviderFailure.process(String(localized: "The installed CLI does not support the required sign-in command.")) }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct LoginDraft: Codable {
    let provider: Provider
    let directory: URL
}
