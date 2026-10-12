import Foundation

enum RTKAgent: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        }
    }

    var hookCommand: String { "rtk hook \(rawValue)" }
}

enum RTKAgentManager {
    enum State: Sendable, Equatable {
        case rtkNotFound
        case notInstalled(version: String)
        case installed(version: String)
        case unmanagedInstallation(version: String, reason: String)
        case unavailable(String)
    }

    enum ManagerError: LocalizedError {
        case rtkNotFound
        case invalidSettings(String)
        case existingInstallation(String)
        case existingGeminiHooks
        case existingCodexInstructions
        case notManaged
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .rtkNotFound:
                "RTK was not found. Install the RTK CLI first, then retry."
            case .invalidSettings(let path):
                "Could not read valid JSON from \(path). The file was left unchanged."
            case .existingInstallation(let agent):
                "An RTK hook for \(agent) is already configured outside this app. It was left unchanged."
            case .existingGeminiHooks:
                "Gemini CLI already has BeforeTool hooks. To preserve them safely, configure RTK manually with `rtk init --global --gemini`."
            case .existingCodexInstructions:
                "Codex already has RTK.md instructions. They were left unchanged."
            case .notManaged:
                "This RTK integration is not managed by AI Usage Monitor."
            case .commandFailed(let message): message
            }
        }
    }

    private struct Ownership: Codable {
        let agent: RTKAgent
        let executablePath: String
        let version: String
        let geminiHookFingerprint: String?
    }

    static func state(
        for agent: RTKAgent,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> State {
        let owner = loadOwnership(for: agent, homeDirectory: homeDirectory)
        guard let executable = findRTK(homeDirectory: homeDirectory, preferredPath: owner?.executablePath) else {
            return .rtkNotFound
        }
        do {
            let version = try run(executable, arguments: ["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let settings = try loadSettings(for: agent, homeDirectory: homeDirectory)
            if containsHook(settings, for: agent) {
                guard owner?.executablePath == executable.path else {
                    return .unmanagedInstallation(version: version, reason: "An RTK hook already exists.")
                }
                if agent == .gemini,
                   owner?.geminiHookFingerprint != geminiHookFingerprint(settings) {
                    return .unmanagedInstallation(version: version, reason: "The Gemini RTK hook group changed after installation.")
                }
                return .installed(version: version)
            }
            if agent == .gemini, hasGeminiHookScript(homeDirectory: homeDirectory) {
                return .unmanagedInstallation(version: version, reason: "An RTK Gemini hook file already exists.")
            }
            if agent == .codex, FileManager.default.fileExists(atPath: codexRTKInstructionsURL(homeDirectory: homeDirectory).path) {
                return .unmanagedInstallation(version: version, reason: "Codex RTK.md already exists.")
            }
            return .notInstalled(version: version)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    static func install(
        _ agent: RTKAgent,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        guard let executable = findRTK(homeDirectory: homeDirectory, preferredPath: nil) else {
            throw ManagerError.rtkNotFound
        }
        let settings = try loadSettings(for: agent, homeDirectory: homeDirectory)
        guard !containsHook(settings, for: agent) else {
            throw ManagerError.existingInstallation(agent.displayName)
        }

        let arguments: [String]
        switch agent {
        case .codex:
            guard !FileManager.default.fileExists(atPath: codexRTKInstructionsURL(homeDirectory: homeDirectory).path) else {
                throw ManagerError.existingCodexInstructions
            }
            arguments = ["init", "--global", "--codex", "--auto-patch"]
        case .gemini:
            // RTK's Gemini installer currently groups hooks by matcher. Avoid running it
            // over existing BeforeTool groups so its uninstall cannot remove user hooks.
            guard !hasGeminiBeforeToolHooks(settings) else { throw ManagerError.existingGeminiHooks }
            guard !hasGeminiHookScript(homeDirectory: homeDirectory) else {
                throw ManagerError.existingInstallation(agent.displayName)
            }
            arguments = ["init", "--global", "--gemini", "--auto-patch"]
        }

        let version = try run(executable, arguments: ["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try run(executable, arguments: arguments)
        let updatedSettings = try loadSettings(for: agent, homeDirectory: homeDirectory)
        guard containsHook(updatedSettings, for: agent) else {
            throw ManagerError.commandFailed("RTK setup completed, but the \(agent.displayName) hook could not be verified.")
        }
        do {
            try saveOwnership(
                Ownership(
                    agent: agent,
                    executablePath: executable.path,
                    version: version,
                    geminiHookFingerprint: agent == .gemini ? geminiHookFingerprint(updatedSettings) : nil
                ),
                for: agent,
                homeDirectory: homeDirectory
            )
        } catch {
            // Roll back only the just-installed agent integration if ownership cannot be recorded.
            _ = try? run(executable, arguments: uninstallArguments(for: agent))
            throw error
        }
    }

    static func uninstall(
        _ agent: RTKAgent,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        guard let owner = loadOwnership(for: agent, homeDirectory: homeDirectory),
              let executable = findRTK(homeDirectory: homeDirectory, preferredPath: owner.executablePath) else {
            throw ManagerError.notManaged
        }
        let settings = try loadSettings(for: agent, homeDirectory: homeDirectory)
        guard containsHook(settings, for: agent) else { throw ManagerError.notManaged }
        if agent == .gemini {
            // RTK's Gemini uninstaller removes the matcher group containing its hook.
            // Refuse if that group changed after installation, so co-located user hooks survive.
            guard geminiHookFingerprint(settings) == owner.geminiHookFingerprint else {
                throw ManagerError.commandFailed("Gemini's RTK hook group changed since installation. It was left untouched; review it and remove the RTK hook manually if needed.")
            }
        }

        _ = try run(executable, arguments: uninstallArguments(for: agent))
        let updatedSettings = try loadSettings(for: agent, homeDirectory: homeDirectory)
        guard !containsHook(updatedSettings, for: agent) else {
            throw ManagerError.commandFailed("RTK uninstall finished, but the \(agent.displayName) hook is still present.")
        }
        try? FileManager.default.removeItem(at: ownershipURL(for: agent, homeDirectory: homeDirectory))
    }

    private static func uninstallArguments(for agent: RTKAgent) -> [String] {
        switch agent {
        case .codex: ["init", "--global", "--codex", "--uninstall"]
        case .gemini: ["init", "--global", "--gemini", "--uninstall"]
        }
    }

    private static func loadSettings(for agent: RTKAgent, homeDirectory: URL) throws -> [String: Any] {
        let url = settingsURL(for: agent, homeDirectory: homeDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ManagerError.invalidSettings(url.path)
        }
        return value
    }

    private static func settingsURL(for agent: RTKAgent, homeDirectory: URL) -> URL {
        switch agent {
        case .codex:
            let configured = ProcessInfo.processInfo.environment["CODEX_HOME"]
            let directory = configured.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
            return directory.appendingPathComponent("hooks.json")
        case .gemini:
            return homeDirectory.appendingPathComponent(".gemini/settings.json")
        }
    }

    private static func codexRTKInstructionsURL(homeDirectory: URL) -> URL {
        let configured = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let directory = configured.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        return directory.appendingPathComponent("RTK.md")
    }

    private static func hasGeminiHookScript(homeDirectory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: homeDirectory.appendingPathComponent(".gemini/hooks/rtk-hook-gemini.sh").path
        )
    }

    static func containsHook(_ value: Any, for agent: RTKAgent) -> Bool {
        if let string = value as? String {
            return string.localizedCaseInsensitiveContains(agent.hookCommand)
                || (agent == .gemini && string.localizedCaseInsensitiveContains("rtk-hook-gemini.sh"))
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains { containsHook($0, for: agent) }
        }
        if let array = value as? [Any] {
            return array.contains { containsHook($0, for: agent) }
        }
        return false
    }

    static func hasGeminiBeforeToolHooks(_ settings: [String: Any]) -> Bool {
        guard let hooksValue = settings["hooks"] else { return false }
        guard let hooks = hooksValue as? [String: Any], let beforeTool = hooks["BeforeTool"] else {
            return !(hooksValue is [String: Any])
        }
        guard let groups = beforeTool as? [Any] else { return true }
        return !groups.isEmpty
    }

    private static func geminiHookFingerprint(_ settings: [String: Any]) -> String? {
        guard let hooks = settings["hooks"] as? [String: Any],
              let beforeTool = hooks["BeforeTool"] as? [Any] else { return nil }
        let managedGroups = beforeTool.filter { containsHook($0, for: .gemini) }
        guard !managedGroups.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: managedGroups, options: [.sortedKeys]) else { return nil }
        return data.base64EncodedString()
    }

    private static func findRTK(homeDirectory: URL, preferredPath: String?) -> URL? {
        let fileManager = FileManager.default
        var candidates = [URL]()
        if let preferredPath { candidates.append(URL(fileURLWithPath: preferredPath)) }
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        candidates += pathEntries.map { URL(fileURLWithPath: $0).appendingPathComponent("rtk") }
        candidates += [
            homeDirectory.appendingPathComponent(".cargo/bin/rtk"),
            homeDirectory.appendingPathComponent(".local/bin/rtk"),
            URL(fileURLWithPath: "/opt/homebrew/bin/rtk"),
            URL(fileURLWithPath: "/usr/local/bin/rtk"),
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func run(_ executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw ManagerError.commandFailed("Could not start RTK: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let detail = result.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ManagerError.commandFailed(detail.isEmpty
                ? "RTK exited with status \(process.terminationStatus)."
                : detail)
        }
        return result
    }

    private static func ownershipURL(for agent: RTKAgent, homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/AIUsage/rtk-\(agent.rawValue)-ownership.json")
    }

    private static func loadOwnership(for agent: RTKAgent, homeDirectory: URL) -> Ownership? {
        guard let data = try? Data(contentsOf: ownershipURL(for: agent, homeDirectory: homeDirectory)) else { return nil }
        return try? JSONDecoder().decode(Ownership.self, from: data)
    }

    private static func saveOwnership(_ ownership: Ownership, for agent: RTKAgent, homeDirectory: URL) throws {
        let url = ownershipURL(for: agent, homeDirectory: homeDirectory)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(ownership).write(to: url, options: .atomic)
        } catch {
            throw ManagerError.commandFailed("Could not record RTK ownership: \(error.localizedDescription)")
        }
    }
}
