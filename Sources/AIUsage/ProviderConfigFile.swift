import Foundation

enum ProviderConfigFile {
    static func url(
        for provider: Provider,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        switch provider {
        case .claude:
            let configDirectory: URL
            if let configured = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !configured.isEmpty {
                configDirectory = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
            } else {
                configDirectory = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
            }
            return configDirectory.appendingPathComponent("settings.json", isDirectory: false)

        case .codex:
            let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let configDirectory: URL
            if let codexHome, !codexHome.isEmpty {
                configDirectory = URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath, isDirectory: true)
            } else {
                configDirectory = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
            }
            return configDirectory.appendingPathComponent("config.toml", isDirectory: false)

        case .gemini:
            return homeDirectory
                .appendingPathComponent(".gemini", isDirectory: true)
                .appendingPathComponent("settings.json", isDirectory: false)

        default:
            return nil
        }
    }

    static func exists(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
