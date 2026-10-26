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
struct Credential {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Double            // epoch milliseconds
    var root: [String: Any]          // entire Keychain JSON, so write-back preserves every key
}

enum UsageClient {
    static let keychainService = "Claude Code-credentials"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let tokenURL = URL(string: "https://api.anthropic.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"   // public Claude Code OAuth client
    static let expirySkew: Double = 30    // treat tokens this close to expiry as expired

    // A refreshed credential whose Keychain write failed. Refresh tokens rotate, so
    // we must not lose it — retry the write before doing anything else.
    nonisolated(unsafe) private static var unsaved: Credential?
    nonisolated(unsafe) private static var unsavedBase: String?   // Keychain access token it replaced

    // MARK: Keychain (via /usr/bin/security, same store Claude Code uses)

    private static func runSecurity(_ args: [String], stdin input: String? = nil) -> (Int32, Data) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        let inPipe = Pipe()
        if input != nil { proc.standardInput = inPipe }
        do { try proc.run() } catch { return (-1, Data()) }
        if let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
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
        let refresh = oauth["refreshToken"] as? String ?? ""
        let exp = (oauth["expiresAt"] as? Double) ?? (oauth["expiresAt"] as? Int).map(Double.init) ?? 0
        return Credential(accessToken: access, refreshToken: refresh, expiresAt: exp, root: obj)
    }

    // The macOS account ("acct") on the Keychain item, needed to update it in place.
    private static func keychainAccount() -> String? {
        let (status, data) = runSecurity(["find-generic-password", "-s", keychainService])
        guard status == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.contains("\"acct\"") {
            if let r = line.range(of: "=\"") {
                let tail = line[r.upperBound...]
                if let end = tail.firstIndex(of: "\"") { return String(tail[..<end]) }
            }
        }
        return nil
    }

    private static func shellQuote(_ v: String) -> String {
        "'" + v.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // Updates the existing item in place (-U, never creates a second one), keeping
    // every top-level key, then re-reads to verify. Returns false if it didn't stick.
    private static func writeCredential(_ cred: Credential) -> Bool {
        guard let acct = keychainAccount() else { return false }
        var oauth = (cred.root["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauth["accessToken"] = cred.accessToken
        oauth["refreshToken"] = cred.refreshToken
        oauth["expiresAt"] = cred.expiresAt
        var root = cred.root
        root["claudeAiOauth"] = oauth
        guard let json = try? JSONSerialization.data(withJSONObject: root) else { return false }
        // Sent on stdin to `security -i` (hex-encoded) so the tokens never appear in
        // the process arguments, where `ps` could see them. The re-read below is the
        // real success check — `security -i` can exit 0 even if a command failed.
        let hex = json.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -s \(keychainService) -a \(shellQuote(acct)) -X \(hex)\n"
        let (status, _) = runSecurity(["-i"], stdin: command)
        guard status == 0, let back = readCredential() else { return false }
        return back.accessToken == cred.accessToken && back.refreshToken == cred.refreshToken
    }

    // MARK: Token refresh

    private static func exchange(_ cred: Credential) async throws -> Credential {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": cred.refreshToken,
            "client_id": clientID,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw UsageError.badResponse }
        Log.write("POST /v1/oauth/token -> \(http.statusCode) (token refresh)")
        if http.statusCode == 429 { throw UsageError.rateLimited(retryAfter(http)) }
        if http.statusCode == 400 || http.statusCode == 401 { throw UsageError.unauthorized }
        guard http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String
        else { throw UsageError.http(http.statusCode) }

        var updated = cred
        updated.accessToken = access
        updated.refreshToken = obj["refresh_token"] as? String ?? cred.refreshToken
        let expiresIn = (obj["expires_in"] as? Double) ?? (obj["expires_in"] as? Int).map(Double.init) ?? 3600
        updated.expiresAt = Date().timeIntervalSince1970 * 1000 + expiresIn * 1000
        return updated
    }

    // Drops held-in-memory tokens if the Keychain moved on without us (e.g. you logged
    // in again via Claude Code, or our write actually landed) so we never overwrite a
    // newer login with older tokens.
    private static func reconcileUnsaved() {
        guard let pending = unsaved, let current = readCredential() else { return }
        if current.accessToken == pending.accessToken {
            unsaved = nil; unsavedBase = nil
            Log.write("held tokens already in Keychain — cleared")
        } else if current.accessToken != unsavedBase {
            unsaved = nil; unsavedBase = nil
            Log.write("Keychain changed since failed write — discarding held tokens")
        }
    }

    // Refreshes only when `stale` is truly unusable. Re-reads the Keychain first so we
    // never spend a refresh token Claude Code has already rotated.
    private static func refreshedCredential(replacing stale: Credential) async throws -> Credential {
        if let pending = unsaved {
            if writeCredential(pending) { unsaved = nil; unsavedBase = nil; Log.write("retried Keychain write ok") }
            return pending
        }
        guard let current = readCredential() else { throw UsageError.noToken }
        if current.accessToken != stale.accessToken, !isExpired(current) {
            Log.write("Claude Code already refreshed the token — using it")
            return current
        }
        guard !current.refreshToken.isEmpty, keychainAccount() != nil else { throw UsageError.unauthorized }
        let updated = try await exchange(current)
        if writeCredential(updated) {
            Log.write("token refreshed, Keychain updated")
        } else {
            unsaved = updated
            unsavedBase = current.accessToken
            Log.write("token refreshed but Keychain write FAILED — holding in memory, will retry")
        }
        return updated
    }

    // MARK: Usage

    static func fetchUsage() async throws -> UsageSnapshot {
        reconcileUnsaved()
        guard var cred = unsaved ?? readCredential() else { throw UsageError.noToken }
        if isExpired(cred) { cred = try await refreshedCredential(replacing: cred) }
        do {
            return try await requestUsage(token: cred.accessToken)
        } catch UsageError.unauthorized {
            // Rejected despite looking valid — one forced refresh, then give up.
            let fresh = try await refreshedCredential(replacing: cred)
            return try await requestUsage(token: fresh.accessToken)
        }
    }

    private static func isExpired(_ cred: Credential) -> Bool {
        cred.expiresAt / 1000 - Date().timeIntervalSince1970 < expirySkew
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
