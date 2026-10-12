import Foundation
import Darwin
import CryptoKit
import Security
import CSQLite3

protocol UsageProvider: Sendable {
    var provider: Provider { get }
    func fetch() async throws -> UsageSnapshot
}

protocol HTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionDataLoader: HTTPDataLoading {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

enum ClaudeRetryPolicy {
    static func delay(for header: String?, now: Date = .now) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty else { return nil }
        if let seconds = Double(header), seconds.isFinite { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: header).map { max(0, $0.timeIntervalSince(now)) }
    }
}

struct ClaudeProvider: UsageProvider {
    let provider = Provider.claude
    private let loader: any HTTPDataLoading
    private let fetchProfile: Bool
    private let tokenProvider: @Sendable () throws -> String

    init(
        loader: any HTTPDataLoading = URLSessionDataLoader(),
        fetchProfile: Bool = true,
        tokenProvider: @escaping @Sendable () throws -> String = { try ClaudeCredentials.accessToken() }
    ) {
        self.loader = loader
        self.fetchProfile = fetchProfile
        self.tokenProvider = tokenProvider
    }

    func fetch() async throws -> UsageSnapshot {
        let token = try tokenProvider()
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 20

        for attempt in 0...2 {
            let data: Data
            let response: URLResponse
            do { (data, response) = try await loader.data(for: request) }
            catch { throw ProviderFailure.network("Could not reach Claude. Check your network and try again.") }
            guard let http = response as? HTTPURLResponse else {
                throw ProviderFailure.invalidResponse("No HTTP response from Claude.")
            }
            if http.statusCode == 429 {
                guard attempt < 2,
                      let delay = ClaudeRetryPolicy.delay(for: http.value(forHTTPHeaderField: "Retry-After")),
                      delay > 0 else { throw ProviderFailure.http(429) }
                try await Task.sleep(for: .seconds(min(delay, 30)))
                continue
            }
            guard http.statusCode == 200 else { throw ProviderFailure.http(http.statusCode) }
            let windows = try UsageParsing.claude(data)
            let account = fetchProfile ? await ClaudeAccountLookup.shared.account(for: token, using: loader) : nil
            return UsageSnapshot(provider: .claude, windows: windows, account: account, lastSuccess: .now)
        }
        throw ProviderFailure.http(429)
    }
}

private actor ClaudeAccountLookup {
    static let shared = ClaudeAccountLookup()
    private var cached: (fingerprint: String, value: String, expiresAt: Date)?

    func account(for token: String, using loader: any HTTPDataLoading) async -> String? {
        let fingerprint = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        if let cached, cached.fingerprint == fingerprint, cached.expiresAt > .now { return cached.value }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 8
        guard let (data, response) = try? await loader.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let value = UsageParsing.claudeAccount(data) else { return nil }
        cached = (fingerprint, value, .now.addingTimeInterval(6 * 60 * 60))
        return value
    }
}

enum ClaudeCredentials {
    static func accessToken() throws -> String {
        if let raw = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"] {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { return token }
        }
        let configDirectory = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        let path = configDirectory.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: path),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = object["claudeAiOauth"] as? [String: Any],
           let raw = oauth["accessToken"] as? String {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { return token }
        }
        // Keychain access is read-only. Try the service names used by Claude Code
        // versions without printing the security tool's stdout or stderr.
        for service in ["Claude Code-credentials", "Claude Code"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", service, "-w"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { continue }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0,
               let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                if let json = raw.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                   let oauth = object["claudeAiOauth"] as? [String: Any],
                   let token = oauth["accessToken"] as? String { return token }
                return raw
            }
        }
        throw ProviderFailure.credentials("Sign in to Claude Code, or set CLAUDE_CODE_OAUTH_TOKEN.")
    }
}

protocol CodexAppServerDataSource: Sendable {
    func read() async throws -> Data
}

struct CodexProvider: UsageProvider {
    let provider = Provider.codex
    private let source: any CodexAppServerDataSource

    init(source: any CodexAppServerDataSource = LocalCodexAppServerDataSource()) {
        self.source = source
    }

    func fetch() async throws -> UsageSnapshot {
        let parsed = try UsageParsing.codex(await source.read())
        return UsageSnapshot(provider: .codex, windows: parsed.windows, account: parsed.account, lastSuccess: .now)
    }
}

struct CursorSession: Sendable {
    let cookieHeader: String
    let accountHint: String?
}

/// Reads Cursor.app's existing access token without modifying its database.
struct CursorAppAuthStore: Sendable {
    private let databaseURL: URL

    init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    func session() throws -> CursorSession? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        guard let token = try accessToken(), !token.isEmpty else { return nil }
        let claims = try CursorJWT(token: token)
        guard claims.expiresAt.timeIntervalSinceNow > 60 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard claims.userID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ProviderFailure.credentials("Cursor.app session contains an invalid user ID. Sign in to Cursor again.")
        }
        return CursorSession(cookieHeader: "WorkosCursorSessionToken=\(claims.userID)%3A%3A\(token)", accountHint: claims.email)
    }

    private func accessToken() throws -> String? {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ProviderFailure.credentials("Could not read Cursor.app's local session. Try a session cookie in Settings.")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ProviderFailure.credentials("Cursor.app local session was not found. Sign in to Cursor or add a session cookie in Settings.")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, "cursorAuth/accessToken", -1, cursorSQLiteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let type = sqlite3_column_type(statement, 0)
        if type == SQLITE_TEXT, let pointer = sqlite3_column_text(statement, 0) {
            return String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if type == SQLITE_BLOB, let pointer = sqlite3_column_blob(statement, 0) {
            let data = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? String(data: data, encoding: .utf16LittleEndian)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}

private let cursorSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct CursorJWT {
    let userID: String
    let email: String?
    let expiresAt: Date

    init(token: String) throws {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { throw ProviderFailure.credentials("Cursor.app returned an invalid session. Sign in to Cursor again.") }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = claims["sub"] as? String,
              let rawID = subject.split(separator: "|", omittingEmptySubsequences: true).last,
              let expiration = claims["exp"] as? NSNumber else {
            throw ProviderFailure.credentials("Cursor.app session is missing identity or expiry. Sign in to Cursor again.")
        }
        userID = String(rawID)
        email = (claims["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        expiresAt = Date(timeIntervalSince1970: expiration.doubleValue)
    }
}

/// Cursor usage is read from the same session-backed web API used by CodexBar.
struct CursorProvider: UsageProvider {
    let provider = Provider.cursor
    private let loader: any HTTPDataLoading
    private let sessionProvider: @Sendable () throws -> CursorSession

    init(
        loader: any HTTPDataLoading = URLSessionDataLoader(),
        sessionProvider: @escaping @Sendable () throws -> CursorSession = { try CursorCredentialVault.session() }
    ) {
        self.loader = loader
        self.sessionProvider = sessionProvider
    }

    func fetch() async throws -> UsageSnapshot {
        let session = try sessionProvider()
        var request = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do { (data, response) = try await loader.data(for: request) }
        catch { throw ProviderFailure.network("Could not reach Cursor. Check your network and try again.") }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderFailure.invalidResponse("No HTTP response from Cursor.")
        }
        guard http.statusCode == 200 else { throw ProviderFailure.http(http.statusCode) }
        let profile = await fetchAccount(using: session.cookieHeader, with: loader)
        let identity = profile ?? session.accountHint
        let plan = UsageParsing.cursorPlan(data)
        let account = [identity, plan].compactMap { $0 }.joined(separator: " · ")
        let windows = try UsageParsing.cursor(data)
        return UsageSnapshot(provider: .cursor, windows: windows, account: account.isEmpty ? nil : account, lastSuccess: .now)
    }

    private func fetchAccount(using cookie: String, with loader: any HTTPDataLoading) async -> String? {
        var request = URLRequest(url: URL(string: "https://cursor.com/api/auth/me")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 8
        guard let (data, response) = try? await loader.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return UsageParsing.cursorAccount(data) ?? nil
    }
}

enum CursorCredentialVault {
    private static let service = "com.aiusagemonitor.cursor-session"
    private static let keyAccount = "manual-cookie-header"

    static var hasStoredCookie: Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: keyAccount,
                                    kSecReturnData as String: false,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func save(cookieHeader: String) throws {
        let value = cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.contains("=") else { throw ProviderFailure.credentials("Enter a valid Cursor session cookie header.") }
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: keyAccount]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ProviderFailure.credentials("Could not save the Cursor cookie in Keychain.") }
        } else if status != errSecSuccess {
            throw ProviderFailure.credentials("Could not update the Cursor cookie in Keychain.")
        }
    }

    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: keyAccount]
        SecItemDelete(query as CFDictionary)
    }

    static func session() throws -> CursorSession {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: keyAccount,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data,
           let cookie = String(data: data, encoding: .utf8), !cookie.isEmpty {
            return CursorSession(cookieHeader: cookie, accountHint: nil)
        }
        if let session = try CursorAppAuthStore().session() { return session }
        throw ProviderFailure.credentials("Sign in to Cursor.app or add a session cookie in Settings → Providers.")
    }
}

struct LocalCodexAppServerDataSource: CodexAppServerDataSource {
    func read() async throws -> Data {
        guard let executable = Self.findCodex() else {
            throw ProviderFailure.process("Codex CLI was not found. Install Codex or add it to PATH.")
        }
        return try await Task.detached(priority: .utility) { try Self.query(executable: executable) }.value
    }

    private static func findCodex() -> URL? {
        var candidates = [ProcessInfo.processInfo.environment["CODEX_BINARY_PATH"],
                          "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                          "/Applications/ChatGPT.app/Contents/Resources/codex",
                          "/Applications/ChatGPT.app/Contents/SharedSupport/codex",
                          "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex"]
        candidates += [".local/bin", ".npm-global/bin", ".volta/bin", ".cargo/bin", "bin"]
            .map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0).appendingPathComponent("codex").path }
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        return candidates.compactMap { $0 }.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func query(executable: URL) throws -> Data {
        let deadline = Date().addingTimeInterval(12)
        var lastError: Error = ProviderFailure.process("Could not start Codex app-server.")
        for arguments in [["app-server", "--stdio"], ["app-server"], ["app-server", "--listen", "stdio://"]] {
            guard deadline > .now else { break }
            do { return try query(executable: executable, arguments: arguments, deadline: deadline) }
            catch { lastError = error }
        }
        throw lastError
    }

    private static func query(executable: URL, arguments: [String], deadline: Date) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw ProviderFailure.process("Could not start Codex app-server.") }
        let inputHandle = input.fileHandleForWriting
        let outputHandle = output.fileHandleForReading
        defer {
            try? inputHandle.close()
            try? outputHandle.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        var buffer = Data()
        try send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"ai-usage-monitor","title":"AI Usage Monitor","version":"1.0"}}}"#, to: inputHandle)
        _ = try response(id: 1, from: outputHandle, buffer: &buffer, deadline: deadline)
        try send(#"{"jsonrpc":"2.0","method":"initialized","params":{}}"#, to: inputHandle)
        Thread.sleep(forTimeInterval: 0.15)
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
