import Foundation

// A single rate-limit window reported by Anthropic.
struct LimitWindow {
    let utilization: Double      // percent, 0...100
    let resetsAt: Date?
}

// The official usage snapshot, mirroring what Claude Code's /usage shows.
struct UsageSnapshot {
    var fiveHour: LimitWindow?
    var sevenDay: LimitWindow?
    var sevenDayOpus: LimitWindow?
    var sevenDaySonnet: LimitWindow?
}

enum UsageError: Error, LocalizedError {
    case noToken
    case unauthorized
    case rateLimited(Double?)   // optional Retry-After seconds
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noToken: return "No Claude login found"
        case .unauthorized: return "Login expired — run Claude Code"
        case .rateLimited: return "Rate limited — backing off"
        case .http(let c): return "Request failed (\(c))"
        case .badResponse: return "Unexpected response"
        }
    }
}

// Lightweight append-only log so we can see exactly how often we hit the network.
// Tail it with:  tail -f ~/Library/Logs/ClaudeUsageBar.log
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ClaudeUsageBar.log")

    static func write(_ message: String) {
        let line = ISO8601DateFormatter().string(from: Date()) + "  " + message + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

// The OAuth credential stored by Claude Code in the Keychain.
// Read-only: this app never writes to the Keychain and never refreshes the token.
// Claude Code owns the token lifecycle — the stored item is large (it also holds MCP
// logins) and a refresh whose write-back fails leaves Claude Code logged out.
struct Credential {
    let accessToken: String
    let expiresAt: Double            // epoch milliseconds
}

enum UsageClient {
    static let keychainService = "Claude Code-credentials"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let expirySkew: Double = 30    // treat tokens this close to expiry as expired

    // MARK: Keychain (read-only, via /usr/bin/security — the store Claude Code uses)

    private static func runSecurity(_ args: [String]) -> (Int32, Data) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return (-1, Data()) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, data)
    }

    static func readCredential() -> Credential? {
        let (status, data) = runSecurity(["find-generic-password", "-s", keychainService, "-w"])
        guard status == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String
        else { return nil }
        let exp = (oauth["expiresAt"] as? Double) ?? (oauth["expiresAt"] as? Int).map(Double.init) ?? 0
        return Credential(accessToken: access, expiresAt: exp)
    }

    private static func isExpired(_ cred: Credential) -> Bool {
        cred.expiresAt / 1000 - Date().timeIntervalSince1970 < expirySkew
    }

    // MARK: Usage

    // Uses whatever token Claude Code has stored. If it's expired or rejected we do not
    // refresh it ourselves: we re-read once (Claude Code may have just refreshed it) and
    // otherwise report "login expired" until Claude Code is used again.
    static func fetchUsage() async throws -> UsageSnapshot {
        guard let cred = readCredential() else { throw UsageError.noToken }
        guard !isExpired(cred) else { throw UsageError.unauthorized }
        do {
            return try await requestUsage(token: cred.accessToken)
        } catch UsageError.unauthorized {
            guard let fresh = readCredential(), fresh.accessToken != cred.accessToken, !isExpired(fresh)
            else { throw UsageError.unauthorized }
            return try await requestUsage(token: fresh.accessToken)
        }
    }

    private static func requestUsage(token: String) async throws -> UsageSnapshot {
        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("claude-usage-bar/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw UsageError.badResponse }
        Log.write("GET /api/oauth/usage -> \(http.statusCode)")
        if http.statusCode == 429 { throw UsageError.rateLimited(retryAfter(http)) }
        if http.statusCode == 401 || http.statusCode == 403 { throw UsageError.unauthorized }
        guard http.statusCode == 200 else { throw UsageError.http(http.statusCode) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.badResponse
        }

        func parse(_ key: String) -> LimitWindow? {
            guard let d = obj[key] as? [String: Any],
                  let util = (d["utilization"] as? Double) ?? (d["utilization"] as? Int).map(Double.init)
            else { return nil }
            let reset = (d["resets_at"] as? String).flatMap(parseDate)
            return LimitWindow(utilization: util, resetsAt: reset)
        }

        return UsageSnapshot(
            fiveHour: parse("five_hour"),
            sevenDay: parse("seven_day"),
            sevenDayOpus: parse("seven_day_opus"),
            sevenDaySonnet: parse("seven_day_sonnet")
        )
    }

    private static func retryAfter(_ http: HTTPURLResponse) -> Double? {
        guard let v = http.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return Double(v.trimmingCharacters(in: .whitespaces))
    }

    // Handles ISO-8601 with microsecond fractional seconds + offset.
    static func parseDate(_ s: String) -> Date? {
        var str = s
        if let dot = str.firstIndex(of: ".") {
            var end = str.index(after: dot)
            while end < str.endIndex, str[end].isNumber { end = str.index(after: end) }
            str.removeSubrange(dot..<end)
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: str)
    }
}
