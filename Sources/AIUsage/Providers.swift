import Foundation
import Darwin
import CryptoKit

protocol UsageProvider: Sendable {
    var provider: Provider { get }
    func fetch() async throws -> UsageSnapshot
}

struct ClaudeProvider: UsageProvider {
    let provider = Provider.claude
    func fetch() async throws -> UsageSnapshot {
        let token = try ClaudeCredentials.accessToken()
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 20
        for attempt in 0...2 {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ProviderFailure.invalidResponse("No HTTP response from Claude.") }
            if http.statusCode == 429, attempt < 2 {
                try await Task.sleep(for: .seconds(retryDelay(header: http.value(forHTTPHeaderField: "Retry-After"), attempt: attempt)))
                continue
            }
            guard http.statusCode == 200 else { throw ProviderFailure.http(http.statusCode) }
            let windows = try UsageParsing.claude(data)
            let account = await ClaudeAccountLookup.shared.account(for: token)
            return UsageSnapshot(provider: .claude, windows: windows, account: account, lastSuccess: .now)
        }
        throw ProviderFailure.http(429)
    }

    private func retryDelay(header: String?, attempt: Int) -> Double {
        let fallback = attempt == 0 ? 1.0 : 3.0
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty else { return fallback }
        if let seconds = Double(header) { return min(30, max(1, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        if let date = formatter.date(from: header) { return min(30, max(1, date.timeIntervalSinceNow)) }
        return fallback
    }
}

private actor ClaudeAccountLookup {
    static let shared = ClaudeAccountLookup()
    private var cached: (fingerprint: String, value: String, expiresAt: Date)?

    func account(for token: String) async -> String? {
        let fingerprint = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        if let cached, cached.fingerprint == fingerprint, cached.expiresAt > .now { return cached.value }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let value = UsageParsing.claudeAccount(data) else { return nil }
        cached = (fingerprint, value, .now.addingTimeInterval(6 * 60 * 60))
        return value
    }
}

enum ClaudeCredentials {
    static func accessToken() throws -> String {
        if let token = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty { return token }
        let configDirectory = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        let path = configDirectory.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: path), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = object["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String, !token.isEmpty { return token }
        // Claude Code stores its credential in the user's login keychain. Query read-only and never print stdout.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe(); process.standardOutput = output; process.standardError = Pipe()
        do { try process.run() } catch { throw ProviderFailure.credentials("Could not read Claude Code credentials.") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 0, let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            if let json = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
               let oauth = object["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String { return token }
            return raw
        }
        throw ProviderFailure.credentials("Sign in to Claude Code, or set CLAUDE_CODE_OAUTH_TOKEN.")
    }
}

struct CodexProvider: UsageProvider {
    let provider = Provider.codex
    func fetch() async throws -> UsageSnapshot {
        let executable = Self.findCodex()
        guard let executable else { throw ProviderFailure.process("Codex CLI was not found. Install Codex or add it to PATH.") }
        let output = try await Task.detached(priority: .utility) { try Self.query(executable: executable) }.value
        let parsed = try UsageParsing.codex(output)
        return UsageSnapshot(provider: .codex, windows: parsed.windows, account: parsed.account, lastSuccess: .now)
    }

    private static func findCodex() -> URL? {
        var candidates = [ProcessInfo.processInfo.environment["CODEX_BINARY_PATH"],
                          "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                          "/Applications/ChatGPT.app/Contents/Resources/codex",
                          "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex"]
        candidates += [".local/bin", ".npm-global/bin", ".volta/bin"].map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0).appendingPathComponent("codex").path }
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        return candidates.compactMap { $0 }.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func query(executable: URL) throws -> Data {
        let process = Process(); process.executableURL = executable; process.arguments = ["app-server"]
        let input = Pipe(), output = Pipe(); process.standardInput = input; process.standardOutput = output; process.standardError = Pipe()
        do { try process.run() } catch { throw ProviderFailure.process("Could not start Codex app-server.") }
        let inputHandle = input.fileHandleForWriting
        let outputHandle = output.fileHandleForReading
        defer {
            try? inputHandle.close()
            try? outputHandle.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        var buffer = Data()
        let deadline = Date().addingTimeInterval(12)
        try send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"ai-usage","title":"AI Usage","version":"1.0"}}}"#, to: inputHandle)
        _ = try response(id: 1, from: outputHandle, buffer: &buffer, deadline: deadline)
        try send(#"{"jsonrpc":"2.0","method":"initialized","params":{}}"#, to: inputHandle)
        try send(#"{"jsonrpc":"2.0","id":2,"method":"account/read","params":{"refreshToken":false}}"#, to: inputHandle)
        let account = try response(id: 2, from: outputHandle, buffer: &buffer, deadline: deadline)
        try send(#"{"jsonrpc":"2.0","id":3,"method":"account/rateLimits/read","params":{}}"#, to: inputHandle)
        let limits = try response(id: 3, from: outputHandle, buffer: &buffer, deadline: deadline)
        guard var combined = try JSONSerialization.jsonObject(with: limits) as? [String: Any],
              var result = combined["result"] as? [String: Any] else {
            throw ProviderFailure.invalidResponse("Codex app-server returned an invalid rate-limit response.")
        }
        if let accountResult = (try? JSONSerialization.jsonObject(with: account)) as? [String: Any],
           let accountValue = accountResult["result"] as? [String: Any] {
            for (key, value) in accountValue where result[key] == nil { result[key] = value }
        }
        combined["result"] = result
        return try JSONSerialization.data(withJSONObject: combined)
    }

    private static func send(_ line: String, to handle: FileHandle) throws {
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private static func response(id: Int, from handle: FileHandle, buffer: inout Data, deadline: Date) throws -> Data {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw ProviderFailure.invalidResponse("Could not read Codex app-server output.")
        }
        while Date() < deadline {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                guard (object["id"] as? Int) == id else { continue }
                if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                    throw ProviderFailure.process("Codex app-server: \(message)")
                }
                return line
            }
            var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = Darwin.poll(&descriptorState, 1, 250)
            if ready < 0, errno != EINTR { break }
            if ready > 0 {
                var bytes = [UInt8](repeating: 0, count: 16_384)
                let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 { buffer.append(contentsOf: bytes.prefix(count)) }
                else if count == 0 { break }
                else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { break }
            }
        }
        throw ProviderFailure.process("Timed out waiting for Codex app-server response \(id).")
    }
}
