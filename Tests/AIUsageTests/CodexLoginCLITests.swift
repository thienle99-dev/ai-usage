import Foundation
import XCTest
@testable import AIUsage

final class CodexLoginCLITests: XCTestCase {
    func testSuccessfulLoginUsesAndRegistersDedicatedHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let managedRoot = root.appendingPathComponent(".ai-usage/accounts/codex", isDirectory: true)
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let activePath = managedRoot.appendingPathComponent("existing-account").path
        let defaultPath = managedRoot.appendingPathComponent("default-home", isDirectory: true).path
        defaults.set(try JSONEncoder().encode([CodexHome(path: defaultPath)]), forKey: "codexHomes")
        defaults.set(activePath, forKey: "activeCodexHomePath")

        let resultURL = root.appendingPathComponent("process-result.txt")
        let executable = try makeCodexStub(at: root, script: "printf '%s\\n%s' \"$CODEX_HOME\" \"$1\" > \"$TEST_RESULT\"\nprintf '{}' > \"$CODEX_HOME/auth.json\"\nexit 0\n")
        let exitCode = CodexLoginCLI.run(
            arguments: ["login"],
            defaults: defaults,
            homeDirectory: root,
            environment: ["TEST_RESULT": resultURL.path],
            fileManager: .default,
            resolveExecutable: { _ in executable }
        )

        XCTAssertEqual(exitCode, 0)
        let result = try String(contentsOf: resultURL, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[1], "login")
        let newHomePath = try XCTUnwrap(result.first)
        XCTAssertTrue(newHomePath.hasPrefix(managedRoot.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: newHomePath).appendingPathComponent("auth.json").path))

        let homes = try XCTUnwrap(defaults.data(forKey: "codexHomes")).decodedCodexHomes()
        XCTAssertEqual(homes.map(\.path), [defaultPath, newHomePath])
        XCTAssertEqual(defaults.string(forKey: "activeCodexHomePath"), activePath)
    }

    func testFailedLoginDoesNotRegisterNewHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let managedRoot = root.appendingPathComponent(".ai-usage/accounts/codex", isDirectory: true)
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let defaultPath = managedRoot.appendingPathComponent("default-home", isDirectory: true).path
        defaults.set(try JSONEncoder().encode([CodexHome(path: defaultPath)]), forKey: "codexHomes")

        let executable = try makeCodexStub(at: root, script: "exit 7\n")
        let exitCode = CodexLoginCLI.run(
            arguments: ["login"],
            defaults: defaults,
            homeDirectory: root,
            environment: [:],
            fileManager: .default,
            resolveExecutable: { _ in executable }
        )

        XCTAssertEqual(exitCode, 7)
        XCTAssertEqual(try XCTUnwrap(defaults.data(forKey: "codexHomes")).decodedCodexHomes().map(\.path), [defaultPath])
    }

    func testLoginRequiresCodexAccountManagementSetup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let exitCode = CodexLoginCLI.run(
            arguments: ["login"],
            defaults: defaults,
            homeDirectory: root,
            environment: [:],
            fileManager: .default,
            resolveExecutable: { _ in XCTFail("Must not launch Codex before account management is initialized"); return nil }
        )

        XCTAssertEqual(exitCode, 78)
    }

    func testUnknownSubcommandReturnsUsageError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let exitCode = CodexLoginCLI.run(
            arguments: ["switch"],
            defaults: defaults,
            homeDirectory: root,
            environment: [:],
            fileManager: .default,
            resolveExecutable: { _ in nil }
        )

        XCTAssertEqual(exitCode, 64)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "CodexLoginCLITests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "CodexLoginCLITests", code: 1)
        }
        return (defaults, suiteName)
    }

    private func makeCodexStub(at root: URL, script: String) throws -> URL {
        let executable = root.appendingPathComponent("codex-stub")
        try Data(("#!/bin/sh\n" + script).utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}

private extension Data {
    func decodedCodexHomes() throws -> [CodexHome] {
        try JSONDecoder().decode([CodexHome].self, from: self)
    }
}
