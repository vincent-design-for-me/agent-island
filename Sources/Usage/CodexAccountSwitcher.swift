import Foundation

/// One-click Codex account switching. Codex keeps exactly one signed-in
/// account in `~/.codex/auth.json`; this parks copies of each login in
/// `~/.codex/agentisland-accounts/<label>.json` (the same store the 2.x
/// builds and the Windows port use) and swaps the live file on demand.
///
/// Accounts are matched by `tokens.account_id`, not by bytes: the Codex CLI
/// rewrites auth.json on every token refresh, so a byte match goes stale
/// within hours and every switch would park yet another duplicate.
enum CodexAccountSwitcher {
    struct Account: Identifiable, Equatable {
        let label: String
        let url: URL
        let accountID: String?
        let email: String?
        var id: String { label }
    }

    private static let autoSwitchKey = "AgentIsland.codexAutoSwitchWhenExhausted"
    private static let maxLabelLength = 40

    /// Off by default: silently swapping logins surprises anyone who did not
    /// ask for it, and a running Codex CLI sees the file change mid-session.
    static var autoSwitchEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoSwitchKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoSwitchKey) }
    }

    private static var codexHome: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    private static var liveURL: URL { codexHome.appendingPathComponent("auth.json") }
    private static var storeURL: URL { codexHome.appendingPathComponent("agentisland-accounts", isDirectory: true) }

    static func accounts() -> [Account] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: storeURL, includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                let identity = identity(of: try? Data(contentsOf: url))
                return Account(
                    label: url.deletingPathExtension().lastPathComponent,
                    url: url,
                    accountID: identity.accountID,
                    email: identity.email
                )
            }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    /// The parked account that is live right now, or nil for a login that
    /// was never saved.
    static func activeAccount() -> Account? {
        guard let live = try? Data(contentsOf: liveURL) else { return nil }
        return match(live, in: accounts())
    }

    /// Park the current login under `label`. An account parked earlier under
    /// a different name is renamed rather than duplicated.
    @discardableResult
    static func parkCurrent(label raw: String) -> Bool {
        let label = sanitize(raw)
        guard !label.isEmpty, let live = try? Data(contentsOf: liveURL) else { return false }
        guard prepareStore() else { return false }
        let target = storeURL.appendingPathComponent(label + ".json")
        guard write(live, to: target) else { return false }
        if let accountID = identity(of: live).accountID {
            for old in accounts() where old.accountID == accountID && old.url != target {
                try? FileManager.default.removeItem(at: old.url)
            }
        }
        return true
    }

    /// Make `account` the live Codex login. The outgoing login is written
    /// back to its parked copy first, so the refresh token Codex rotated
    /// since it was parked is not lost; an unsaved login is parked under a
    /// timestamped name instead of being destroyed.
    @discardableResult
    static func activate(_ account: Account) -> Bool {
        guard let incoming = try? Data(contentsOf: account.url) else { return false }
        if let live = try? Data(contentsOf: liveURL) {
            if let outgoing = match(live, in: accounts()) {
                if outgoing.url == account.url { return true }
                _ = write(live, to: outgoing.url)
            } else {
                parkCurrent(label: "previous-\(Int(Date().timeIntervalSince1970))")
            }
        }
        return write(incoming, to: liveURL)
    }

    @discardableResult
    static func forget(_ account: Account) -> Bool {
        guard account.url.deletingLastPathComponent().standardizedFileURL == storeURL.standardizedFileURL else {
            return false
        }
        return (try? FileManager.default.removeItem(at: account.url)) != nil
    }

    /// The next account worth rotating to: parked, not live, not yet tried
    /// this exhaustion episode. Label order keeps rotation deterministic
    /// instead of ping-ponging between two logins.
    static func rotationCandidate(tried: Set<String>) -> Account? {
        let active = activeAccount()?.label
        return accounts().first { $0.label != active && !tried.contains($0.label) }
    }

    /// Labels become filenames: keep them to safe characters so a stray "/"
    /// or ".." can never escape the store directory.
    static func sanitize(_ raw: String) -> String {
        let kept = raw.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || "-_ ".unicodeScalars.contains($0)
        }
        return String(String.UnicodeScalarView(kept).prefix(maxLabelLength))
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Helpers

    private static func match(_ live: Data, in parked: [Account]) -> Account? {
        if let accountID = identity(of: live).accountID,
           let hit = parked.first(where: { $0.accountID == accountID }) {
            return hit
        }
        return parked.first { (try? Data(contentsOf: $0.url)) == live }
    }

    /// `tokens.account_id` plus the email claim from the id_token. Never
    /// returns or logs the tokens themselves.
    private static func identity(of data: Data?) -> (accountID: String?, email: String?) {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any] else { return (nil, nil) }
        let accountID = tokens["account_id"] as? String
        var email: String?
        if let idToken = tokens["id_token"] as? String {
            let parts = idToken.split(separator: ".")
            if parts.count >= 2, let payload = base64URLDecode(String(parts[1])),
               let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                email = claims["email"] as? String
            }
        }
        return (accountID, email)
    }

    private static func base64URLDecode(_ raw: String) -> Data? {
        var base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    private static func prepareStore() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: storeURL, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return true
        } catch {
            NSLog("AgentIsland: could not create the Codex account store: %@", error.localizedDescription)
            return false
        }
    }

    /// Atomic write, so a crash mid-swap leaves either the old login or the
    /// new one, never a truncated auth.json.
    private static func write(_ data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            NSLog("AgentIsland: could not write Codex credentials: %@", error.localizedDescription)
            return false
        }
    }
}
