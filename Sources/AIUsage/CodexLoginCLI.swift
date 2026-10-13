import Foundation

enum CodexLoginCLI {
    private static let usage = "Usage: ai-usage codex login\n"
    private static let appPreferencesDomain = "com.local.aiusage"

    static func run(arguments: [String]) -> Int32 {
        run(
            arguments: arguments,
            defaults: UserDefaults(suiteName: appPreferencesDomain) ?? .standard,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment,
            fileManager: .default,
            resolveExecutable: resolve
        )
    }

    static func run(
        arguments: [String],
        defaults: UserDefaults,
        homeDirectory: URL,
        environment: [String: String],
        fileManager: FileManager,
        resolveExecutable: (String) -> URL?
    ) -> Int32 {
        guard arguments == ["login"] else {
            writeError(usage)
            return 64
        }

        let rootURL = homeDirectory
            .appendingPathComponent(".ai-usage/accounts/codex", isDirectory: true)
            .standardizedFileURL
        let defaultHomePath = rootURL
            .appendingPathComponent("default-home", isDirectory: true)
            .standardizedFileURL.path

        guard let data = defaults.data(forKey: "codexHomes"),
              let homes = try? JSONDecoder().decode([CodexHome].self, from: data),
              homes.contains(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == defaultHomePath }) else {
            writeError("ai-usage: initialize Codex account management in Settings → Providers → Codex homes before adding an account.\n")
            return 78
        }

        guard let executable = resolveExecutable("codex") else {
            writeError("ai-usage: could not find the Codex CLI (`codex`) in PATH.\n")
            return 127
        }

        let accountURL = rootURL
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            .standardizedFileURL
        do {
            try fileManager.createDirectory(at: accountURL, withIntermediateDirectories: false)
        } catch {
            writeError("ai-usage: could not create a new Codex home: \(error.localizedDescription)\n")
            return 1
        }

        var childEnvironment = environment
        childEnvironment["CODEX_HOME"] = accountURL.path
        let process = Process()
        process.executableURL = executable
        process.arguments = ["login"]
        process.environment = childEnvironment
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            writeError("ai-usage: could not start Codex CLI: \(error.localizedDescription)\n")
            writeError("The new home was left at \(accountURL.path).\n")
            return 126
        }

        let exitCode = process.terminationReason == .uncaughtSignal
            ? 128 + process.terminationStatus
            : process.terminationStatus
        guard exitCode == 0 else {
            writeError("ai-usage: Codex login did not complete (exit \(exitCode)); the new home was left at \(accountURL.path).\n")
            return exitCode
        }

        let authURL = accountURL.appendingPathComponent("auth.json")
        guard fileManager.fileExists(atPath: authURL.path) else {
            writeError("ai-usage: Codex login exited successfully but created no auth.json; the new home was left at \(accountURL.path).\n")
            return 1
        }

        var updatedHomes = homes
        updatedHomes.append(CodexHome(path: accountURL.path))
        do {
            defaults.set(try JSONEncoder().encode(updatedHomes), forKey: "codexHomes")
            writeError("Codex account home registered. Select it in AI Usage Monitor → Settings → Providers → Codex homes.\n")
            return 0
        } catch {
            writeError("ai-usage: login succeeded, but the home could not be registered: \(error.localizedDescription)\n")
            writeError("The authenticated home was left at \(accountURL.path).\n")
            return 1
        }
    }

    private static func resolve(_ program: String) -> URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        return paths.lazy
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(program) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}
