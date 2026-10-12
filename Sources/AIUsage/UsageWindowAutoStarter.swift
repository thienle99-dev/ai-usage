import Foundation
import Darwin

protocol UsageWindowStartCommandRunning: Sendable {
    func run(provider: Provider) async
}

/// Decides when a real, minimal CLI request can start a fresh five-hour window.
/// Providers without a known reset signal are intentionally excluded.
enum UsageWindowAutoStartPolicy {
    static let resetGrace: TimeInterval = 120

    static func shouldStart(snapshot: UsageSnapshot, now: Date, lastStartedAt: Date?) -> Bool {
        guard !snapshot.isStale,
              lastStartedAt.map({ now.timeIntervalSince($0) >= cooldown(for: snapshot.provider) }) ?? true else { return false }

        switch snapshot.provider {
        case .claude, .codex:
            guard let window = snapshot.windows.first(where: { $0.label == "5-hour limit" }),
                  window.validUtilization != nil,
                  let reset = window.resetsAt else { return false }
            return now.timeIntervalSince(reset) >= resetGrace
        case .antigravity:
            // Antigravity reports a sliding reset placeholder while fully unused.
            return snapshot.windows.contains { $0.label == "Gemini 5-hour" && $0.validUtilization == 0 }
        default:
            return false
        }
    }

    static func cooldown(for provider: Provider) -> TimeInterval {
        provider == .antigravity ? 5 * 60 * 60 : 5 * 60 * 60 + 5 * 60
    }
}

/// Sends the provider's cheapest supported CLI prompt. It never calls a quota
/// API to alter limits; the request only starts a new window after a reset.
struct LocalUsageWindowStartCommandRunner: UsageWindowStartCommandRunning {
    func run(provider: Provider) async {
        await Task.detached(priority: .utility) {
            Self.runSynchronously(provider: provider)
        }.value
    }

    private static func runSynchronously(provider: Provider) {
        let command: (name: String, arguments: [String], fallbacks: [String])
        switch provider {
        case .claude:
            command = ("claude", ["-p", "ok", "--model", "haiku"], [
                "~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"
            ])
        case .codex:
            command = ("codex", ["exec", "-m", "gpt-5.6-luna", "--skip-git-repo-check", "ok"], [
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                "/Applications/ChatGPT.app/Contents/SharedSupport/codex",
                "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.local/bin/codex"
            ])
        case .antigravity:
            command = ("agy", ["-p", "ok", "--model", "gemini-3.8-flash-low"], [
                "~/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"
            ])
        default:
            return
        }

        guard let executable = resolve(command.name, fallbacks: command.fallbacks) else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = command.arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return }
        if finished.wait(timeout: .now() + 180) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private static func resolve(_ name: String, fallbacks: [String]) -> URL? {
        let paths = fallbacks + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/\(name)" }
        return paths.map { path in
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
