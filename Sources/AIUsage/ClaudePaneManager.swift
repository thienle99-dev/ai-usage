import Foundation

enum ClaudePaneManager {
    enum State: Sendable {
        case installed
        case notInstalled
        case unmanagedInstallation
        case unavailable(String)
    }

    enum ManagerError: LocalizedError {
        case claudeNotFound
        case unsupportedVersion(String)
        case existingMarketplace
        case existingPlugin
        case resourceMissing
        case managedPathOccupied
        case commandFailed(String)
        case notManaged

        var errorDescription: String? {
            switch self {
            case .claudeNotFound: "Claude Code CLI was not found. Install Claude Code or add `claude` to PATH."
            case .unsupportedVersion(let version): "Claude Code \(version) is too old for managed plugin installation. Update to v2.1.292 or later."
            case .existingMarketplace: "The AI Usage Monitor marketplace name is already registered outside this app. It was left untouched."
            case .existingPlugin: "The AI Usage Monitor pane is already installed outside this app. It was left untouched."
            case .resourceMissing: "The bundled Claude Code pane files are missing. Reinstall AI Usage Monitor."
            case .managedPathOccupied: "The Claude pane install folder exists but is not owned by AI Usage Monitor. It was left untouched."
            case .commandFailed(let message): message
            case .notManaged: "This Claude Code pane installation is not managed by AI Usage Monitor."
            }
        }
    }

    private struct Ownership: Codable {
        var marketplace: String
        var plugin: String
        var marketplacePath: String
        var marketplaceOwned: Bool
        var sourceOwned: Bool
    }

    private static let marketplaceName = "ai-usage-monitor-local"
    private static let pluginName = "usage-side-pane"
    private static var pluginID: String { "\(pluginName)@\(marketplaceName)" }

    static func state(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> State {
        guard let executable = findClaude(homeDirectory: homeDirectory) else { return .unavailable(ManagerError.claudeNotFound.localizedDescription) }
        do {
            let output = try run(executable, arguments: ["plugin", "list"])
            let isListed = output.contains(pluginID)
            let owner = loadOwnership(homeDirectory: homeDirectory)
            if isListed { return owner == nil ? .unmanagedInstallation : .installed }
            return .notInstalled
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    static func installOrUpdate(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard let claude = findClaude(homeDirectory: homeDirectory) else { throw ManagerError.claudeNotFound }
        try requireSupportedVersion(claude)
        let owner = loadOwnership(homeDirectory: homeDirectory)
        let destination = marketplaceURL(homeDirectory: homeDirectory)
        let supportDirectory = destination.deletingLastPathComponent()
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: destination.path), owner == nil {
            throw ManagerError.managedPathOccupied
        }
        guard let bundled = Bundle.module.resourceURL?.appendingPathComponent("ClaudePaneMarketplace", isDirectory: true),
              fileManager.fileExists(atPath: bundled.appendingPathComponent(".claude-plugin/marketplace.json").path) else {
            throw ManagerError.resourceMissing
        }

        let marketplaceList = try run(claude, arguments: ["plugin", "marketplace", "list"])
        let marketplaceExists = marketplaceList.split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "❯ ")) == marketplaceName }
        if marketplaceExists && owner == nil { throw ManagerError.existingMarketplace }

        let pluginList = try run(claude, arguments: ["plugin", "list"])
        let pluginExists = pluginList.contains(pluginID)
        if pluginExists && owner == nil { throw ManagerError.existingPlugin }

        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let staging = supportDirectory.appendingPathComponent("marketplace-new-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.copyItem(at: bundled, to: staging)
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw ManagerError.commandFailed("Could not prepare the local Claude Code pane: \(error.localizedDescription)")
        }

        var marketplaceOwned = owner?.marketplaceOwned ?? false
        do {
            if !marketplaceExists {
                _ = try run(claude, arguments: ["plugin", "marketplace", "add", destination.path])
                marketplaceOwned = true
            }
            let newOwner = Ownership(
                marketplace: marketplaceName,
                plugin: pluginName,
                marketplacePath: destination.path,
                marketplaceOwned: marketplaceOwned,
                sourceOwned: true
            )
            try saveOwnership(newOwner, homeDirectory: homeDirectory)

            if pluginExists {
                _ = try run(claude, arguments: ["plugin", "marketplace", "update", marketplaceName])
                _ = try run(claude, arguments: ["plugin", "update", pluginID])
            } else {
                _ = try run(claude, arguments: ["plugin", "install", pluginID, "--scope", "user"])
            }
        } catch {
            if owner == nil {
                try? fileManager.removeItem(at: ownershipURL(homeDirectory: homeDirectory))
                if marketplaceOwned { _ = try? run(claude, arguments: ["plugin", "marketplace", "remove", marketplaceName]) }
                try? fileManager.removeItem(at: destination)
            }
            throw error
        }
    }

    static func uninstall(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard let owner = loadOwnership(homeDirectory: homeDirectory),
              owner.plugin == pluginName,
              owner.marketplace == marketplaceName,
              let claude = findClaude(homeDirectory: homeDirectory) else { throw ManagerError.notManaged }

        let pluginList = try run(claude, arguments: ["plugin", "list"])
        if pluginList.contains(pluginID) {
            _ = try run(claude, arguments: ["plugin", "uninstall", pluginID, "--scope", "user"])
        }

        if owner.marketplaceOwned {
            let remaining = try run(claude, arguments: ["plugin", "list"])
            let otherPluginsUseMarketplace = remaining.split(whereSeparator: \.isNewline).contains { line in
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.contains("@\(marketplaceName)") && !value.contains(pluginID)
            }
            if !otherPluginsUseMarketplace {
                _ = try run(claude, arguments: ["plugin", "marketplace", "remove", marketplaceName])
                if owner.sourceOwned { try? FileManager.default.removeItem(atPath: owner.marketplacePath) }
                try? FileManager.default.removeItem(at: ownershipURL(homeDirectory: homeDirectory))
            } else {
                var retained = owner
                retained.sourceOwned = false
                try saveOwnership(retained, homeDirectory: homeDirectory)
            }
        } else {
            try? FileManager.default.removeItem(at: ownershipURL(homeDirectory: homeDirectory))
        }
    }

    private static func requireSupportedVersion(_ executable: URL) throws {
        let output = try run(executable, arguments: ["--version"])
        guard let match = output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else {
            throw ManagerError.unsupportedVersion(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let version = output[match].split(separator: ".").compactMap { Int($0) }
        guard version.count == 3 else {
            throw ManagerError.unsupportedVersion(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let required = [2, 1, 292]
        if version.lexicographicallyPrecedes(required) {
            throw ManagerError.unsupportedVersion("\(version.map(String.init).joined(separator: ".")) (requires 2.1.292+)")
        }
    }

    private static func findClaude(homeDirectory: URL) -> URL? {
        let fileManager = FileManager.default
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = pathEntries.map { URL(fileURLWithPath: $0).appendingPathComponent("claude") } + [
            homeDirectory.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func run(_ executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do { try process.run() }
        catch { throw ManagerError.commandFailed("Could not start Claude Code CLI: \(error.localizedDescription)") }
        process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let detail = (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ManagerError.commandFailed(detail.isEmpty ? "Claude Code CLI exited with status \(process.terminationStatus)." : detail)
        }
        return stdout
    }

    private static func marketplaceURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/AIUsage/ClaudePane/marketplace", isDirectory: true)
    }

    private static func ownershipURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/AIUsage/ClaudePane/ownership.json")
    }

    private static func loadOwnership(homeDirectory: URL) -> Ownership? {
        guard let data = try? Data(contentsOf: ownershipURL(homeDirectory: homeDirectory)) else { return nil }
        return try? JSONDecoder().decode(Ownership.self, from: data)
    }

    private static func saveOwnership(_ owner: Ownership, homeDirectory: URL) throws {
        let url = ownershipURL(homeDirectory: homeDirectory)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(owner).write(to: url, options: .atomic)
        } catch {
            throw ManagerError.commandFailed("Could not record the app-managed Claude pane installation: \(error.localizedDescription)")
        }
    }
}
