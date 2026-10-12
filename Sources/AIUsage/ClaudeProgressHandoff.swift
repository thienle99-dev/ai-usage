import AppKit
import Darwin
import Foundation
import SwiftUI

struct ClaudeHandoffSession: Identifiable, Hashable, Sendable {
    var id: String { sessionID }
    let sessionID: String
    let name: String
    let cwd: String
    let status: String
    let updatedAt: Double

    var displayName: String {
        let project = URL(fileURLWithPath: cwd).lastPathComponent
        let title = name.isEmpty ? project : name
        return "\(title.isEmpty ? sessionID.prefix(8) : Substring(title)) · \(status)"
    }
}

struct ClaudeHandoffDraft: Sendable {
    let session: ClaudeHandoffSession
    let latestRequest: String
    let gitStatus: String
    let gitDiff: String
    let todos: [String]
    let prompt: String
    let warnings: [String]
}

enum ClaudeProgressHandoff {
    static let optInKey = "claudeProgressHandoffEnabled"

    enum HandoffError: LocalizedError {
        case optInRequired
        case noLiveSessions
        case transcriptUnavailable
        case noRecentRequest
        case gitCommandFailed(String)
        case claudeNotFound
        case terminalOpenFailed

        var errorDescription: String? {
            switch self {
            case .optInRequired:
                "Enable Progress hand-off in Settings before reading session data."
            case .noLiveSessions:
                "No live Claude Code sessions were found. Open the project in Claude Code and try again."
            case .transcriptUnavailable:
                "The selected session transcript could not be found in Claude Code's local project history."
            case .noRecentRequest:
                "No recent text request was found in the selected session transcript."
            case .gitCommandFailed(let message): message
            case .claudeNotFound:
                "Claude Code CLI was not found. Install Claude Code or add `claude` to PATH."
            case .terminalOpenFailed:
                "Could not open the hand-off in Terminal."
            }
        }
    }

    private struct SessionRecord: Decodable {
        let pid: Int
        let sessionId: String
        let name: String?
        let cwd: String?
        let status: String?
        let statusUpdatedAt: Double?
        let updatedAt: Double?
    }

    static func liveSessions(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> [ClaudeHandoffSession] {
        let directory = homeDirectory.appendingPathComponent(".claude/sessions", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            throw HandoffError.noLiveSessions
        }

        let decoder = JSONDecoder()
        let rows = files.compactMap { file -> SessionRecord? in
            guard file.pathExtension == "json",
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true,
                  let data = try? Data(contentsOf: file),
                  let row = try? decoder.decode(SessionRecord.self, from: data),
                  row.pid > 0, !row.sessionId.isEmpty,
                  let cwd = row.cwd, !cwd.isEmpty,
                  let updatedAt = row.statusUpdatedAt ?? row.updatedAt else { return nil }
            return SessionRecord(pid: row.pid, sessionId: row.sessionId, name: row.name, cwd: cwd, status: row.status, statusUpdatedAt: updatedAt, updatedAt: updatedAt)
        }

        guard !rows.isEmpty else { throw HandoffError.noLiveSessions }
        let pids = rows.map { String($0.pid) }.joined(separator: ",")
        let output = try run(URL(fileURLWithPath: "/bin/ps"), arguments: ["-o", "pid=", "-p", pids], timeout: 5)
        let livePIDs = Set(output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) })
        let sessions = rows.filter { livePIDs.contains($0.pid) }.map {
            ClaudeHandoffSession(
                sessionID: $0.sessionId,
                name: $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                cwd: $0.cwd ?? "",
                status: $0.status ?? "idle",
                updatedAt: $0.statusUpdatedAt ?? $0.updatedAt ?? 0
            )
        }.sorted { $0.updatedAt > $1.updatedAt }
        guard !sessions.isEmpty else { throw HandoffError.noLiveSessions }
        return sessions
    }

    static func makeDraft(for session: ClaudeHandoffSession, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> ClaudeHandoffDraft {
        guard UserDefaults.standard.bool(forKey: optInKey) else { throw HandoffError.optInRequired }
        let transcriptURL = findTranscript(session: session, homeDirectory: homeDirectory)
        guard let transcriptURL else { throw HandoffError.transcriptUnavailable }
        let latestRequest = try readLatestUserRequest(from: transcriptURL)
        guard !latestRequest.isEmpty else { throw HandoffError.noRecentRequest }

        let repository = URL(fileURLWithPath: session.cwd, isDirectory: true)
        let statusResult = try? run(URL(fileURLWithPath: "/usr/bin/git"), arguments: ["-C", repository.path, "status", "--short", "--untracked-files=all"], timeout: 10)
        let workingDiff = try? run(URL(fileURLWithPath: "/usr/bin/git"), arguments: ["-C", repository.path, "-c", "core.pager=cat", "diff", "--no-ext-diff", "--no-color", "--unified=2"], timeout: 20)
        let stagedDiff = try? run(URL(fileURLWithPath: "/usr/bin/git"), arguments: ["-C", repository.path, "-c", "core.pager=cat", "diff", "--cached", "--no-ext-diff", "--no-color", "--unified=2"], timeout: 20)
        var warnings: [String] = []
        let status = statusResult?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if statusResult == nil { warnings.append("Git status could not be read; the selected folder may not be a Git repository.") }
        let combinedDiff = [stagedDiff, workingDiff].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let maxDiffCharacters = 60_000
        let diff = String(combinedDiff.prefix(maxDiffCharacters))
        if combinedDiff.count > maxDiffCharacters { warnings.append("The diff is large; only its first 60,000 characters are included.") }
        let todos = extractTodos(from: latestRequest, diff: diff)
        let prompt = buildPrompt(session: session, latestRequest: latestRequest, gitStatus: status, gitDiff: diff, todos: todos, warnings: warnings)
        return ClaudeHandoffDraft(session: session, latestRequest: latestRequest, gitStatus: status, gitDiff: diff, todos: todos, prompt: prompt, warnings: warnings)
    }

    static func openNewSession(with draft: ClaudeHandoffDraft, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let executable = findClaude(homeDirectory: homeDirectory)
        guard let executable else { throw HandoffError.claudeNotFound }
        let temp = FileManager.default.temporaryDirectory
        let nonce = UUID().uuidString
        let promptURL = temp.appendingPathComponent("ai-usage-handoff-\(nonce).txt")
        let scriptURL = temp.appendingPathComponent("ai-usage-handoff-\(nonce).command")
        do {
            try draft.prompt.write(to: promptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: promptURL.path)
            let script = """
            #!/bin/zsh
            PROMPT="$(/bin/cat \(shellQuote(promptURL.path)))" || exit 1
            /bin/rm -f \(shellQuote(promptURL.path)) "$0"
            cd \(shellQuote(draft.session.cwd)) || exit 1
            exec \(shellQuote(executable.path)) "$PROMPT"
            """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            guard NSWorkspace.shared.open(scriptURL) else { throw HandoffError.terminalOpenFailed }
        } catch {
            try? FileManager.default.removeItem(at: promptURL)
            try? FileManager.default.removeItem(at: scriptURL)
            throw error
        }
    }

    private static func findTranscript(session: ClaudeHandoffSession, homeDirectory: URL) -> URL? {
        let projects = homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
        let filename = "\(session.sessionID).jsonl"
        let encodedCWD = session.cwd.replacingOccurrences(of: "/", with: "-")
        let expected = projects.appendingPathComponent(encodedCWD, isDirectory: true).appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: expected.path) { return expected }
        guard let directories = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        for directory in directories {
            guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true else { continue }
            let candidate = directory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func readLatestUserRequest(from url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        let tailSize: UInt64 = 1_048_576
        try handle.seek(toOffset: end > tailSize ? end - tailSize : 0)
        var text = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        if end > tailSize, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  row["type"] as? String == "user",
                  row["isMeta"] as? Bool != true,
                  row["isSidechain"] as? Bool != true,
                  let message = row["message"] as? [String: Any],
                  let content = message["content"] else { continue }
            let value: String
            if let string = content as? String {
                value = string
            } else if let blocks = content as? [[String: Any]] {
                value = blocks.compactMap { block -> String? in
                    guard block["type"] as? String == "text" else { return nil }
                    return block["text"] as? String
                }.joined(separator: "\n")
            } else {
                continue
            }
            let request = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !request.isEmpty { return request }
        }
        return ""
    }

    private static func extractTodos(from request: String, diff: String) -> [String] {
        var result: [String] = []
        let requestLines = request.split(whereSeparator: \.isNewline).map(String.init)
        result += requestLines.filter { line in
            line.range(of: #"\bTODO\b|^\s*[-*+]\s+\[ \]"#, options: [.regularExpression, .caseInsensitive]) != nil
        }.map { "Request: \($0.trimmingCharacters(in: .whitespacesAndNewlines))" }
        let diffLines = diff.split(whereSeparator: \.isNewline).map(String.init)
        result += diffLines.filter { line in
            line.hasPrefix("+") && !line.hasPrefix("+++")
                && line.range(of: #"\b(TODO|FIXME|XXX)\b"#, options: .regularExpression) != nil
        }.map { "Changed code: \($0.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines))" }
        return Array(result.prefix(80))
    }

    private static func buildPrompt(session: ClaudeHandoffSession, latestRequest: String, gitStatus: String, gitDiff: String, todos: [String], warnings: [String]) -> String {
        var sections = [
            "Continue the work from the previous Claude Code session. Treat this hand-off as context, inspect the current project state, and preserve existing user changes. Do not assume any changes are committed.",
            "## Latest user request\n\(latestRequest)",
            "## Uncommitted file status\n\(gitStatus.isEmpty ? "No tracked or untracked changes reported." : gitStatus)",
            "## Staged and unstaged diff\n\(gitDiff.isEmpty ? "No staged or unstaged tracked diff was available. Untracked file contents were not read." : gitDiff)",
            "## TODOs\n\(todos.isEmpty ? "No explicit TODO/checklist items were found in the latest request or added diff lines." : todos.map { "- \($0)" }.joined(separator: "\n"))",
        ]
        if !warnings.isEmpty { sections.append("## Hand-off collection notes\n" + warnings.map { "- \($0)" }.joined(separator: "\n")) }
        sections.append("Source session: \(session.sessionID) · \(session.cwd)")
        return sections.joined(separator: "\n\n")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func findClaude(homeDirectory: URL) -> URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = paths.map { URL(fileURLWithPath: $0).appendingPathComponent("claude") } + [
            homeDirectory.appendingPathComponent(".local/bin/claude"),
            homeDirectory.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func run(_ executable: URL, arguments: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let token = UUID().uuidString
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("ai-usage-handoff-output-\(token)")
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("ai-usage-handoff-error-\(token)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: outputURL),
              let errors = try? FileHandle(forWritingTo: errorURL) else {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
            throw HandoffError.gitCommandFailed("Could not prepare temporary output files.")
        }
        defer {
            try? output.close()
            try? errors.close()
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        process.standardOutput = output
        process.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { throw HandoffError.gitCommandFailed(error.localizedDescription) }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            throw HandoffError.gitCommandFailed("Command timed out: \(executable.lastPathComponent)")
        }
        try? output.close()
        try? errors.close()
        let stdout = String(decoding: (try? Data(contentsOf: outputURL)) ?? Data(), as: UTF8.self)
        let stderr = String(decoding: (try? Data(contentsOf: errorURL)) ?? Data(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw HandoffError.gitCommandFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return stdout
    }
}

struct ClaudeProgressHandoffSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [ClaudeHandoffSession] = []
    @State private var selectedSessionID: String?
    @State private var draft: ClaudeHandoffDraft?
    @State private var errorMessage: String?
    @State private var working = false

    private var selectedSession: ClaudeHandoffSession? {
        sessions.first(where: { $0.sessionID == selectedSessionID }) ?? sessions.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Progress hand-off")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Review exactly what will be sent to the new Claude Code session.")
                        .font(.system(size: 12))
                        .foregroundStyle(UsageTheme.secondaryText)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if let draft {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Local data read for this preview", systemImage: "lock.shield")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(UsageTheme.secondaryText)
                    Text("Latest request from \(URL(fileURLWithPath: draft.session.cwd).lastPathComponent), Git status/diff, and explicit TODO markers. This content is passed to Claude only after you choose Open New Session.")
                        .font(.system(size: 11))
                        .foregroundStyle(UsageTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ScrollView {
                    Text(draft.prompt)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(UsageTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(UsageTheme.separator, lineWidth: 0.7))
                HStack {
                    Button("Back") { self.draft = nil }
                        .buttonStyle(.bordered)
                        .disabled(working)
                    Spacer()
                    Button(working ? "Opening…" : "Open New Session") { openSession() }
                        .buttonStyle(.borderedProminent)
                        .disabled(working)
                }
            } else {
                Text("Choose a live Claude Code session. Only when you prepare the preview will the app read its latest user request and Git changes.")
                    .font(.system(size: 12))
                    .foregroundStyle(UsageTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if sessions.isEmpty {
                    ProgressView("Finding live sessions…")
                        .frame(maxWidth: .infinity, minHeight: 130)
                } else {
                    Picker("Session", selection: $selectedSessionID) {
                        ForEach(sessions) { session in
                            Text(session.displayName).tag(Optional(session.sessionID))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let selectedSession {
                        Text(selectedSession.cwd)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(UsageTheme.secondaryText)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    HStack {
                        Spacer()
                        Button(working ? "Preparing…" : "Prepare Preview") { preparePreview() }
                            .buttonStyle(.borderedProminent)
                            .disabled(working || selectedSession == nil)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(UsageTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .task { loadSessions() }
    }

    private func loadSessions() {
        Task.detached(priority: .utility) {
            do {
                let found = try ClaudeProgressHandoff.liveSessions()
                await MainActor.run {
                    sessions = found
                    selectedSessionID = found.first?.sessionID
                    errorMessage = nil
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    private func preparePreview() {
        guard let selectedSession else { return }
        working = true
        errorMessage = nil
        Task.detached(priority: .utility) {
            do {
                let prepared = try ClaudeProgressHandoff.makeDraft(for: selectedSession)
                await MainActor.run {
                    draft = prepared
                    working = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    working = false
                }
            }
        }
    }

    private func openSession() {
        guard let draft else { return }
        working = true
        errorMessage = nil
        Task.detached(priority: .utility) {
            do {
                try ClaudeProgressHandoff.openNewSession(with: draft)
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    working = false
                }
            }
        }
    }
}
