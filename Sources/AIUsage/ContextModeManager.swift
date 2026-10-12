import Foundation

/// Manages the official Context Mode Claude Code plugin without bundling its source.
enum ContextModeManager {
    enum State: Sendable, Equatable {
        case installed
        case notInstalled
        case unmanagedInstallation
        case unavailable(String)
    }

    enum ManagerError: LocalizedError {
        case claudeNotFound
        case unsupportedClaudeVersion(String)
        case nodeNotFound
        case unsupportedNodeVersion(String)
        case existingPlugin
        case commandFailed(String)
        case notManaged

        var errorDescription: String? {
            switch self {
            case .claudeNotFound:
                "Claude Code CLI was not found. Install Claude Code or add `claude` to PATH."
            case .unsupportedClaudeVersion(let version):
                "Claude Code \(version) is too old for plugin management. Update to v1.0.33 or later."
            case .nodeNotFound:
                "Node.js 22.5 or later was not found. Install Node.js separately, then retry."
            case .unsupportedNodeVersion(let version):
                "Node.js \(version) is too old for Context Mode. Version 22.5 or later is required."
            case .existingPlugin:
                "Context Mode is already installed outside AI Usage Monitor. It was left untouched."
            case .commandFailed(let message): message
            case .notManaged:
                "This Context Mode installation is not managed by AI Usage Monitor."
            }
        }
    }

    private struct Ownership: Codable {
        let pluginID: String
        let marketplaceName: String
        let marketplaceOwned: Bool
    }

    static let pluginID = "context-mode@context-mode"
    static let marketplaceName = "context-mode"

    static func state(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> State {
        guard let claude = findClaude(homeDirectory: homeDirectory) else {
            return .unavailable(ManagerError.claudeNotFound.localizedDescription)
        }
        do {
            let pluginOutput = try run(claude, arguments: ["plugin", "list"])
            guard containsPlugin(pluginOutput, pluginID: pluginID) else {
                do {
                    try requireSupportedClaudeVersion(claude)
                    try requireSupportedNode(homeDirectory: homeDirectory)
                    return .notInstalled
                } catch {
                    return .unavailable(error.localizedDescription)
                }
            }
            guard let owner = loadOwnership(homeDirectory: homeDirectory),
                  owner.pluginID == pluginID,
                  owner.marketplaceName == marketplaceName else {
                return .unmanagedInstallation
            }
            return .installed
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    static func install(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard let claude = findClaude(homeDirectory: homeDirectory) else { throw ManagerError.claudeNotFound }
        try requireSupportedClaudeVersion(claude)
        try requireSupportedNode(homeDirectory: homeDirectory)

        let existingPlugins = try run(claude, arguments: ["plugin", "list"])
        guard !containsPlugin(existingPlugins, pluginID: pluginID) else { throw ManagerError.existingPlugin }

        let marketplaces = try run(claude, arguments: ["plugin", "marketplace", "list"])
        let marketplaceExists = containsMarketplace(marketplaces, name: marketplaceName)
        var marketplaceOwned = false
        if !marketplaceExists {
            _ = try run(claude, arguments: ["plugin", "marketplace", "add", "mksglu/context-mode"])
            marketplaceOwned = true
        }

        do {
            try saveOwnership(
                Ownership(pluginID: pluginID, marketplaceName: marketplaceName, marketplaceOwned: marketplaceOwned),
                homeDirectory: homeDirectory
            )
            _ = try run(claude, arguments: ["plugin", "install", pluginID, "--scope", "user"])
            let installed = try run(claude, arguments: ["plugin", "list"])
            guard containsPlugin(installed, pluginID: pluginID) else {
                throw ManagerError.commandFailed("Claude Code completed installation, but Context Mode could not be verified.")
            }
        } catch {
            if marketplaceOwned { _ = try? run(claude, arguments: ["plugin", "marketplace", "remove", marketplaceName]) }
            try? FileManager.default.removeItem(at: ownershipURL(homeDirectory: homeDirectory))
            throw error
        }
    }

    static func uninstall(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard let owner = loadOwnership(homeDirectory: homeDirectory),
              owner.pluginID == pluginID,
              owner.marketplaceName == marketplaceName,
              let claude = findClaude(homeDirectory: homeDirectory) else {
            throw ManagerError.notManaged
        }

        let plugins = try run(claude, arguments: ["plugin", "list"])
        if containsPlugin(plugins, pluginID: pluginID) {
            _ = try run(claude, arguments: ["plugin", "uninstall", pluginID, "--scope", "user"])
        }

        if owner.marketplaceOwned {
            let remaining = try run(claude, arguments: ["plugin", "list"])
            if !hasOtherPlugins(remaining, using: marketplaceName, excluding: pluginID) {
                _ = try run(claude, arguments: ["plugin", "marketplace", "remove", marketplaceName])
            }
        }
        try? FileManager.default.removeItem(at: ownershipURL(homeDirectory: homeDirectory))
    }

    static func containsPlugin(_ output: String, pluginID: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "❯ "))
            return value == pluginID || value.hasPrefix(pluginID + " ") || value.hasPrefix(pluginID + "(")
        }
    }

    static func containsMarketplace(_ output: String, name: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "❯ "))
            return value == name || value.hasPrefix(name + " ")
        }
    }

    static func hasOtherPlugins(_ output: String, using marketplace: String, excluding pluginID: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.contains("@\(marketplace)") && !value.hasPrefix(pluginID)
        }
    }

    static func supportsNodeVersion(_ output: String) -> Bool {
        guard let range = output.range(of: #"v?\d+\.\d+\.\d+"#, options: .regularExpression) else { return false }
        let components = output[range].drop(while: { $0 == "v" }).split(separator: ".").compactMap { Int($0) }
        guard components.count == 3 else { return false }
        return !components.lexicographicallyPrecedes([22, 5, 0])
    }

    private static func requireSupportedClaudeVersion(_ executable: URL) throws {
        let output = try run(executable, arguments: ["--version"])
        guard let range = output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else {
            throw ManagerError.unsupportedClaudeVersion(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let components = output[range].split(separator: ".").compactMap { Int($0) }
        guard components.count == 3, !components.lexicographicallyPrecedes([1, 0, 33]) else {
            throw ManagerError.unsupportedClaudeVersion(output[range].description)
        }
    }

    private static func requireSupportedNode(homeDirectory: URL) throws {
        guard let node = findNode(homeDirectory: homeDirectory) else { throw ManagerError.nodeNotFound }
        let version = try run(node, arguments: ["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard supportsNodeVersion(version) else { throw ManagerError.unsupportedNodeVersion(version) }
    }

    private static func findClaude(homeDirectory: URL) -> URL? {
        findExecutable(named: "claude", homeDirectory: homeDirectory, additionalDirectories: [".local/bin"])
    }

    private static func findNode(homeDirectory: URL) -> URL? {
        let managerDirectories: [URL] = [".nvm/versions/node", ".volta/tools/image/node", ".fnm/node-versions"]
            .map { homeDirectory.appendingPathComponent($0, isDirectory: true) }
        let managed = managerDirectories.flatMap { root -> [URL] in
            guard let versions = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
            return versions.map { $0.appendingPathComponent("bin/node") }
        }
        return findExecutable(named: "node", homeDirectory: homeDirectory, additionalDirectories: [".volta/bin", ".local/bin"], extraCandidates: managed)
    }

    private static func findExecutable(
        named name: String,
        homeDirectory: URL,
        additionalDirectories: [String],
        extraCandidates: [URL] = []
    ) -> URL? {
        let fileManager = FileManager.default
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = pathEntries.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            + additionalDirectories.map { homeDirectory.appendingPathComponent($0).appendingPathComponent(name) }
            + [URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"), URL(fileURLWithPath: "/usr/local/bin/\(name)")]
            + extraCandidates
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func run(_ executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() }
        catch { throw ManagerError.commandFailed("Could not start \(executable.lastPathComponent): \(error.localizedDescription)") }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ManagerError.commandFailed(detail.isEmpty ? "\(executable.lastPathComponent) exited with status \(process.terminationStatus)." : detail)
        }
        return output
    }

    private static func ownershipURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/AIUsage/ContextMode/ownership.json")
    }

    private static func loadOwnership(homeDirectory: URL) -> Ownership? {
        guard let data = try? Data(contentsOf: ownershipURL(homeDirectory: homeDirectory)) else { return nil }
        return try? JSONDecoder().decode(Ownership.self, from: data)
    }

    private static func saveOwnership(_ ownership: Ownership, homeDirectory: URL) throws {
        let url = ownershipURL(homeDirectory: homeDirectory)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(ownership).write(to: url, options: .atomic)
        } catch {
            throw ManagerError.commandFailed("Could not record the app-managed Context Mode installation: \(error.localizedDescription)")
        }
    }
}
