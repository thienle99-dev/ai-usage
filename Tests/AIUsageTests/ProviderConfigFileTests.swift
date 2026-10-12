import Foundation
import XCTest
@testable import AIUsage

final class ProviderConfigFileTests: XCTestCase {
    func testDefaultConfigPathsForCLIBasedProviders() {
        let home = URL(fileURLWithPath: "/test/home", isDirectory: true)

        XCTAssertEqual(
            ProviderConfigFile.url(for: .claude, homeDirectory: home, environment: [:])?.path,
            "/test/home/.claude/settings.json"
        )
        XCTAssertEqual(
            ProviderConfigFile.url(for: .codex, homeDirectory: home, environment: [:])?.path,
            "/test/home/.codex/config.toml"
        )
        XCTAssertEqual(
            ProviderConfigFile.url(for: .gemini, homeDirectory: home, environment: [:])?.path,
            "/test/home/.gemini/settings.json"
        )
    }

    func testClaudeAndCodexConfigPathsHonorEnvironmentOverrides() {
        let home = URL(fileURLWithPath: "/test/home", isDirectory: true)
        let environment = [
            "CLAUDE_CONFIG_DIR": "/custom/claude",
            "CODEX_HOME": "/custom/codex"
        ]

        XCTAssertEqual(
            ProviderConfigFile.url(for: .claude, homeDirectory: home, environment: environment)?.path,
            "/custom/claude/settings.json"
        )
        XCTAssertEqual(
            ProviderConfigFile.url(for: .codex, homeDirectory: home, environment: environment)?.path,
            "/custom/codex/config.toml"
        )
    }

    func testUnsupportedProvidersHaveNoConfigFileAction() {
        XCTAssertNil(ProviderConfigFile.url(for: .copilot, homeDirectory: URL(fileURLWithPath: "/test/home"), environment: [:]))
        XCTAssertNil(ProviderConfigFile.url(for: .cursor, homeDirectory: URL(fileURLWithPath: "/test/home"), environment: [:]))
        XCTAssertNil(ProviderConfigFile.url(for: .antigravity, homeDirectory: URL(fileURLWithPath: "/test/home"), environment: [:]))
        XCTAssertNil(ProviderConfigFile.url(for: .grok, homeDirectory: URL(fileURLWithPath: "/test/home"), environment: [:]))
        XCTAssertNil(ProviderConfigFile.url(for: .openCode, homeDirectory: URL(fileURLWithPath: "/test/home"), environment: [:]))
    }

    func testOnlyExistingFilesAreOpenableAndMissingConfigIsNotCreated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent(".codex/config.toml")

        XCTAssertFalse(ProviderConfigFile.exists(config))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))

        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model = \"example\"\n".utf8).write(to: config)
        XCTAssertTrue(ProviderConfigFile.exists(config))

        let directory = root.appendingPathComponent(".codex/directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertFalse(ProviderConfigFile.exists(directory))
    }
}
