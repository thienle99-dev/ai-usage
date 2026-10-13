import Foundation
import Darwin

enum QuotaAwarePreflight {
    enum Decision {
        case notLarge
        case clear
        case lowQuota(window: String, used: Int, threshold: Int)
        case unavailable(String)
    }

    static let defaultLargeTaskTokenThreshold = 4_000
    static let maximumSnapshotAge: TimeInterval = 15 * 60

    static func evaluate(
        provider: Provider,
        estimatedTokens: Int,
        snapshots: [UsageSnapshot],
        warningThreshold: Double,
        now: Date = .now
    ) -> Decision {
        guard estimatedTokens >= defaultLargeTaskTokenThreshold else { return .notLarge }
        guard let snapshot = snapshots.first(where: { $0.provider == provider }) else {
            return .unavailable("No cached usage snapshot is available for \(provider.displayName).")
        }
        guard !snapshot.isStale,
              snapshot.lastSuccess != .distantPast,
              now.timeIntervalSince(snapshot.lastSuccess) <= maximumSnapshotAge else {
            return .unavailable("Cached usage for \(provider.displayName) is stale or has a local fetch error.")
        }
        guard let window = snapshot.validWindows.max(by: { ($0.validUtilization ?? 0) < ($1.validUtilization ?? 0) }),
              let used = window.validUtilization else {
            return .unavailable("No valid quota percentage is cached for \(provider.displayName).")
        }
        guard used >= warningThreshold else { return .clear }
        return .lowQuota(window: window.label, used: Int(used.rounded()), threshold: Int(warningThreshold.rounded()))
    }
}

enum QuotaAwareCLI {
    private enum Mode: String { case preflight, run }

    static func run(arguments: [String]) -> Int32 {
        if arguments.first == "codex" {
            return CodexLoginCLI.run(arguments: Array(arguments.dropFirst()))
        }
        if arguments.first == "statusline" {
            return CLIStatusLine.run(arguments: Array(arguments.dropFirst()))
        }
        if ["quota", "report", "waste"].contains(arguments.first) {
            return UsageQueryCLI.run(arguments: arguments)
        }
        guard let modeName = arguments.first, let mode = Mode(rawValue: modeName) else {
            writeError("Usage: ai-usage <preflight|run> --provider <name> --estimated-tokens <count> [-- command arguments…]\n       ai-usage quota [--provider <name>] [--format text|json]\n       ai-usage report [--group day|provider|model|project|session] [--range 7d|30d|all] [--format text|json]\n       ai-usage waste [--range 7d|30d] [--format text|json]\n       ai-usage statusline [--provider <name>]\n       ai-usage codex login\n")
            return 64
        }
        do {
            let request = try parse(Array(arguments.dropFirst()), mode: mode)
            let result = preflight(provider: request.provider, estimatedTokens: request.estimatedTokens)
            switch result {
            case .notLarge:
                print("Task estimate is below the large-task threshold (\(QuotaAwarePreflight.defaultLargeTaskTokenThreshold) tokens).")
                if mode == .preflight { return 0 }
            case .clear:
                print("Quota preflight is clear for \(request.provider.displayName).")
                if mode == .preflight { return 0 }
            case .lowQuota(let window, let used, let threshold):
                let remaining = max(0, 100 - used)
                let message = "\(request.provider.displayName) quota is low before this large task: \(window) is \(used)% used (\(remaining)% remains; warning threshold \(threshold)%)."
                if mode == .preflight {
                    writeError("Warning: \(message)\n")
                    return 2
                }
                guard confirm(message) else { return 2 }
            case .unavailable(let message):
                print("Quota preflight unavailable: \(message) Continuing without a quota warning.")
                if mode == .preflight { return 3 }
            }
            guard mode == .run else { return 0 }
            return launch(request.command)
        } catch {
            writeError("ai-usage: \(error.localizedDescription)\n")
            return 64
        }
    }

    private struct Request {
        let provider: Provider
        let estimatedTokens: Int
        let command: [String]
    }

    private enum CLIError: LocalizedError {
        case missingValue(String)
        case invalidProvider(String)
        case invalidTokenEstimate
        case missingCommand
        case unexpectedArgument(String)

        var errorDescription: String? {
            switch self {
            case .missingValue(let option): "Missing value for \(option)."
            case .invalidProvider(let name): "Unknown provider '\(name)'."
            case .invalidTokenEstimate: "Estimated tokens must be a positive integer."
            case .missingCommand: "The run command requires '-- <program> [arguments…]'."
            case .unexpectedArgument(let argument): "Unexpected argument '\(argument)'."
            }
        }
    }

    private static func parse(_ arguments: [String], mode: Mode) throws -> Request {
        var provider: Provider?
        var estimatedTokens: Int?
        var command: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                command = Array(arguments.dropFirst(index + 1))
                break
            }
            guard index + 1 < arguments.count else { throw CLIError.missingValue(argument) }
            let value = arguments[index + 1]
            switch argument {
            case "--provider":
                provider = Provider.supported.first { $0.rawValue.lowercased() == value.lowercased() || $0.shortName.lowercased() == value.lowercased() }
                if provider == nil { throw CLIError.invalidProvider(value) }
            case "--estimated-tokens":
                guard let parsed = Int(value), parsed > 0 else { throw CLIError.invalidTokenEstimate }
                estimatedTokens = parsed
            default: throw CLIError.unexpectedArgument(argument)
            }
            index += 2
        }
        guard let provider else { throw CLIError.missingValue("--provider") }
        guard let estimatedTokens else { throw CLIError.missingValue("--estimated-tokens") }
        if mode == .run, command.isEmpty { throw CLIError.missingCommand }
        return Request(provider: provider, estimatedTokens: estimatedTokens, command: command)
    }

    private static func preflight(provider: Provider, estimatedTokens: Int) -> QuotaAwarePreflight.Decision {
        let cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIUsage/snapshots.json")
        guard let data = try? Data(contentsOf: cacheURL),
              let snapshots = try? JSONDecoder().decode([UsageSnapshot].self, from: data) else {
            return .unavailable("No readable local usage cache is available.")
        }
        let warningThreshold = UserDefaults.standard.object(forKey: "warningThreshold") == nil
            ? 70.0 : UserDefaults.standard.double(forKey: "warningThreshold")
        return QuotaAwarePreflight.evaluate(
            provider: provider,
            estimatedTokens: estimatedTokens,
            snapshots: snapshots,
            warningThreshold: warningThreshold
        )
    }

    private static func confirm(_ message: String) -> Bool {
        writeError("Warning: \(message)\nProceed? [y/N] ")
        guard isatty(STDIN_FILENO) == 1, let answer = readLine() else {
            writeError("Cancelled: confirmation requires an interactive terminal.\n")
            return false
        }
        return ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func launch(_ command: [String]) -> Int32 {
        guard let program = command.first, let executable = resolve(program) else {
            writeError("ai-usage: command not found or not executable: \(command.first ?? "")\n")
            return 127
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = Array(command.dropFirst())
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationReason == .uncaughtSignal { return 128 + process.terminationStatus }
            return process.terminationStatus
        } catch {
            writeError("ai-usage: could not start command: \(error.localizedDescription)\n")
            return 126
        }
    }

    private static func resolve(_ program: String) -> URL? {
        if program.contains("/") {
            let url = URL(fileURLWithPath: (program as NSString).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        return paths.lazy
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(program) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}
