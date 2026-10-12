import Foundation

enum CLIStatusLine {
    static let managedMarker = "--managed-by-ai-usage-monitor"
    private static let maximumSnapshotAge: TimeInterval = 15 * 60

    static func run(arguments: [String]) -> Int32 {
        var provider = Provider.claude
        var index = 0
        while index < arguments.count {
            if arguments[index] == managedMarker {
                index += 1
                continue
            }
            guard arguments[index] == "--provider", index + 1 < arguments.count,
                  let selected = Provider.supported.first(where: {
                      $0.rawValue.localizedCaseInsensitiveCompare(arguments[index + 1]) == .orderedSame
                          || $0.shortName.localizedCaseInsensitiveCompare(arguments[index + 1]) == .orderedSame
                  }) else {
                FileHandle.standardError.write(Data("Usage: ai-usage statusline [--provider <name>] [--managed-by-ai-usage-monitor]\n".utf8))
                return 64
            }
            provider = selected
            index += 2
        }

        let cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIUsage/snapshots.json")
        guard let data = try? Data(contentsOf: cacheURL),
              let snapshots = try? JSONDecoder().decode([UsageSnapshot].self, from: data),
              let snapshot = snapshots.first(where: { $0.provider == provider }),
              !snapshot.validWindows.isEmpty else {
            print("\(provider.shortName) quota unavailable")
            return 0
        }

        let stale = snapshot.error != nil || snapshot.lastSuccess == .distantPast
            || Date.now.timeIntervalSince(snapshot.lastSuccess) > maximumSnapshotAge
        let metrics = snapshot.validWindows.map { window in
            "\(shortLabel(window.label)) \(Int((window.validUtilization ?? 0).rounded()))%"
        }
        print(([provider.shortName] + metrics + (stale ? ["stale"] : [])).joined(separator: " · "))
        return 0
    }

    private static func shortLabel(_ label: String) -> String {
        let normalized = label.lowercased()
        if normalized.contains("5-hour") || normalized.contains("5 hour") { return "5h" }
        if normalized.contains("weekly") || normalized.contains("7-day") || normalized.contains("7 day") { return "7d" }
        if normalized.contains("monthly") || normalized.contains("30-day") || normalized.contains("30 day") { return "30d" }
        return label
    }
}

enum ClaudeStatusLineManager {
    enum State {
        case notInstalled
        case installed
        case customStatusLine
        case unavailable
    }

    enum ManagerError: LocalizedError {
        case customStatusLine
        case invalidSettings
        case couldNotWrite(String)
        case notManaged

        var errorDescription: String? {
            switch self {
            case .customStatusLine: "Claude Code already has a custom status line. Remove or change it in Claude settings before installing AI Usage Monitor's status line."
            case .invalidSettings: "Claude Code settings.json is not a JSON object."
            case .couldNotWrite(let reason): "Could not update Claude Code settings: \(reason)"
            case .notManaged: "No AI Usage Monitor status line is installed."
            }
        }
    }

    static func settingsURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent(".claude/settings.json")
    }

    static func ownershipURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/AIUsage/claude-statusline.json")
    }

    static func state(settingsURL: URL, ownershipURL: URL) -> State {
        let command = ownedCommand(at: ownershipURL)
        let settings: [String: Any]
        do { settings = try loadSettings(at: settingsURL) }
        catch { return .unavailable }
        guard let current = currentCommand(settings["statusLine"]) else { return .notInstalled }
        guard let command, current == command else { return .customStatusLine }
        return .installed
    }

    static func install(executableURL: URL, settingsURL: URL, ownershipURL: URL) throws {
        var settings = try loadSettings(at: settingsURL)
        let command = "\(shellQuote(executableURL.path)) statusline --provider Claude \(CLIStatusLine.managedMarker)"
        if settings["statusLine"] != nil {
            throw ManagerError.customStatusLine
        }

        settings["statusLine"] = ["type": "command", "command": command, "padding": 0]
        try save(settings, to: settingsURL)
        do {
            try FileManager.default.createDirectory(at: ownershipURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["command": command], options: [.sortedKeys])
                .write(to: ownershipURL, options: .atomic)
        } catch {
            if currentCommand(at: settingsURL) == command {
                settings.removeValue(forKey: "statusLine")
                try? save(settings, to: settingsURL)
            }
            throw ManagerError.couldNotWrite(error.localizedDescription)
        }
    }

    static func uninstall(settingsURL: URL, ownershipURL: URL) throws {
        guard let command = ownedCommand(at: ownershipURL), currentCommand(at: settingsURL) == command else {
            throw ManagerError.notManaged
        }
        var settings = try loadSettings(at: settingsURL)
        settings.removeValue(forKey: "statusLine")
        try save(settings, to: settingsURL)
        try? FileManager.default.removeItem(at: ownershipURL)
    }

    private static func loadSettings(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ManagerError.invalidSettings
        }
        return settings
    }

    private static func save(_ settings: [String: Any], to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            throw ManagerError.couldNotWrite(error.localizedDescription)
        }
    }

    private static func ownedCommand(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["command"] as? String
    }

    private static func currentCommand(at url: URL) -> String? {
        guard let settings = try? loadSettings(at: url) else { return nil }
        return currentCommand(settings["statusLine"])
    }

    private static func currentCommand(_ value: Any?) -> String? {
        (value as? [String: Any])?["command"] as? String
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
