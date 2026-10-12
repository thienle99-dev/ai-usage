import Foundation

enum ClaudeResponseModeSettings {
    private struct Modes: Codable {
        let tokenSaver: Bool
        let beginner: Bool
    }

    static func write(tokenSaver: Bool, beginner: Bool, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let directory = homeDirectory.appendingPathComponent("Library/Application Support/AIUsage/ClaudePane", isDirectory: true)
        let file = directory.appendingPathComponent("response-modes.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Modes(tokenSaver: tokenSaver, beginner: beginner))
        try data.write(to: file, options: .atomic)
    }
}
