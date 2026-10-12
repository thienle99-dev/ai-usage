import Foundation

enum RTKClaudeManager {
    enum State: Sendable, Equatable {
        case rtkNotFound
        case notInstalled(version: String)
        case installed(version: String)
        case unmanagedInstallation(version: String)
        case unavailable(String)
    }

    enum ManagerError: LocalizedError {
        case rtkNotFound
        case invalidClaudeSettings
        case existingInstallation
        case existingRTKInstructions
        case notManaged
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .rtkNotFound:
                "RTK was not found. Install the RTK CLI first, then retry."
            case .invalidClaudeSettings:
                "Claude Code settings.json is not a valid JSON object. It was left unchanged."
            case .existingInstallation:
                "An RTK hook is already configured for Claude Code outside this app. It was left unchanged."
            case .existingRTKInstructions:
                "Claude Code already has an RTK.md file. It was left unchanged."
            case .notManaged:
                "This RTK integration is not managed by AI Usage Monitor."
            case .commandFailed(let message): message
            }
        }
    }

    private struct Ownership: Codable {
        let executablePath: String
        let version: String
    }

    private static let instructionsFileName = "RTK.md"

    static func state(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> State {
        let owner = loadOwnership(homeDirectory: homeDirectory)
        guard let executable = findRTK(homeDirectory: homeDirectory, preferredPath: owner?.executablePath) else {
            return .rtkNotFound
        }

        do {
            let version = try run(executable, arguments: ["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let settings = try loadClaudeSettings(homeDirectory: homeDirectory)
            let hasHook = containsRTKClaudeHook(settings)
            if hasHook {
                return owner?.executablePath == executable.path
                    ? .installed(version: version)
                    : .unmanagedInstallation(version: version)
            }
            if FileManager.default.fileExists(atPath: instructionsURL(homeDirectory: homeDirectory).path) {
                return .unmanagedInstallation(version: version)
            }
            return .notInstalled(version: version)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    static func install(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard let executable = findRTK(homeDirectory: homeDirectory, preferredPath: nil) else {
            throw ManagerError.rtkNotFound
        }
        let settings = try loadClaudeSettings(homeDirectory: homeDirectory)
        guard !containsRTKClaudeHook(settings) else { throw ManagerError.existingInstallation }
        guard !FileManager.default.fileExists(atPath: instructionsURL(homeDirectory: homeDirectory).path) else {
            throw ManagerError.existingRTKInstructions
        }

        let version = try run(executable, arguments: ["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Hook-only avoids adding a separate RTK.md instruction file to the user's Claude setup.
        _ = try run(executable, arguments: ["init", "-g", "--hook-only", "--auto-patch"])

        let updatedSettings = try loadClaudeSettings(homeDirectory: homeDirectory)
        guard containsRTKClaudeHook(updatedSettings) else {
            throw ManagerError.commandFailed("RTK completed setup, but its Claude Code hook could not be verified.")
        }
        do {
            try saveOwnership(Ownership(executablePath: executable.path, version: version), homeDirectory: homeDirectory)
        } catch {
            // The hook was just installed into a clean Claude setup. Roll it back if ownership cannot be recorded.
            _ = try? run(executable, arguments: ["init", "-g", "--uninstall"])
            throw error
        }
    }

    static func uninstall(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard let owner = loadOwnership(homeDirectory: homeDirectory),
              let executable = findRTK(homeDirectory: homeDirectory, preferredPath: owner.executablePath) else {
            throw ManagerError.notManaged
        }
        let settings = try loadClaudeSettings(homeDirectory: homeDirectory)
        guard containsRTKClaudeHook(settings) else { throw ManagerError.notManaged }
        // The official uninstaller also removes RTK.md. Preserve any file created since installation.
        guard !FileManager.default.fileExists(atPath: instructionsURL(homeDirectory: homeDirectory).path) else {
            throw ManagerError.existingRTKInstructions
        }

        _ = try run(executable, arguments: ["init", "-g", "--uninstall"])
        let updatedSettings = try loadClaudeSettings(homeDirectory: homeDirectory)
        guard !containsRTKClaudeHook(updatedSettings) else {
            throw ManagerError.commandFailed("RTK uninstall finished, but its Claude Code hook is still present.")
        }
        try? FileManager.default.removeItem(at: ownershipURL(homeDirectory: homeDirectory))
    }

    private static func claudeSettingsURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".claude/settings.json")
    }

    private static func instructionsURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".claude/\(instructionsFileName)")
    }

    private static func ownershipURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/AIUsage/rtk-claude-ownership.json")
    }

    private static func loadClaudeSettings(homeDirectory: URL) throws -> [String: Any] {
        let url = claudeSettingsURL(homeDirectory: homeDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ManagerError.invalidClaudeSettings
        }
        return settings
    }

    static func containsRTKClaudeHook(_ value: Any) -> Bool {
        if let string = value as? String {
            let normalized = string.lowercased()
            return normalized.contains("rtk") && normalized.contains("hook") && normalized.contains("claude")
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains(where: containsRTKClaudeHook)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsRTKClaudeHook)
        }
        return false
    }

    private static func findRTK(homeDirectory: URL, preferredPath: String?) -> URL? {
        let fileManager = FileManager.default
        var candidates = [URL]()
        if let preferredPath {
            candidates.append(URL(fileURLWithPath: preferredPath))
        }
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

    private static func loadOwnership(homeDirectory: URL) -> Ownership? {
        guard let data = try? Data(contentsOf: ownershipURL(homeDirectory: homeDirectory)) else { return nil }
        return try? JSONDecoder().decode(Ownership.self, from: data)
    }

    private static func saveOwnership(_ ownership: Ownership, homeDirectory: URL) throws {
        let url = ownershipURL(homeDirectory: homeDirectory)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(ownership)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ManagerError.commandFailed("Could not record RTK ownership: \(error.localizedDescription)")
        }
    }
}
