import Foundation
import SQLite3
import SwiftUI

/// Quota-only providers shown beside Claude and Codex. They have no local
/// session logs here, so they appear on the usage surfaces only — never in
/// cost, overview, or the report cards.
enum ExtraProvider: String, CaseIterable, Codable, Identifiable {
    case cursor
    case grok

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cursor: "Cursor"
        case .grok: "Grok"
        }
    }

    var color: Color {
        switch self {
        case .cursor: Color(red: 0.86, green: 0.86, blue: 0.88)
        case .grok: Color(red: 0.72, green: 0.74, blue: 0.80)
        }
    }

    var logo: NSImage? {
        switch self {
        case .cursor: ProviderLogos.cursor
        case .grok: ProviderLogos.grok
        }
    }

    /// Local footprint of the provider's own app/CLI login.
    var isDetected: Bool {
        switch self {
        case .cursor: FileManager.default.fileExists(atPath: CursorUsage.databaseURL.path)
        case .grok: FileManager.default.fileExists(atPath: GrokUsage.authURL.path)
        }
    }

    func fetch() async -> AppUsage {
        switch self {
        case .cursor: await CursorUsage.fetch()
        case .grok: await GrokUsage.fetch()
        }
    }
}

private func singleWindow(
    _ percent: Double, resetAt: Date?, period: TimeInterval?, plan: String?, detail: String? = nil
) -> AppUsage {
    AppUsage(
        fiveHour: WindowUsage(usedPercent: min(1, max(0, percent)), resetAt: resetAt, error: nil,
                              periodSeconds: period),
        weekly: .unknown,
        plan: plan,
        detail: detail
    )
}

private func errorUsage(_ message: String) -> AppUsage {
    let window = WindowUsage(usedPercent: 0, resetAt: nil, error: message)
    return AppUsage(fiveHour: window, weekly: window)
}

private func number(_ value: Any?) -> Double? {
    switch value {
    case let n as NSNumber: n.doubleValue
    case let s as String: Double(s)
    default: nil
    }
}

private func jsonObject(_ data: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

// MARK: - Cursor

/// Cursor's own usage bar reads `GetCurrentPeriodUsage` on its dashboard
/// RPC; the legacy cursor.com/api/usage reports a retired per-request
/// counter. The access token comes from the editor's state database,
/// read-only — Cursor owns its refresh.
enum CursorUsage {
    static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    private static let rpcBase = "https://api2.cursor.sh/aiserver.v1.DashboardService/"

    static func fetch() async -> AppUsage {
        guard let token = readItem("cursorAuth/accessToken"), !token.isEmpty else {
            return errorUsage(L10n.tr("sign in to Cursor"))
        }
        let (status, body) = await post("GetCurrentPeriodUsage", token: token)
        switch status {
        case 200: break
        case 401, 403: return errorUsage(L10n.tr("sign in to Cursor"))
        case 0: return errorUsage(L10n.tr("network drop"))
        default: return errorUsage("http \(status)")
        }
        guard let root = jsonObject(body), let usage = root["planUsage"] as? [String: Any] else {
            return errorUsage(L10n.tr("parse error"))
        }
        // totalPercentUsed covers the whole included allowance; when absent
        // the larger half is the better "how close am I" signal.
        let percent = number(usage["totalPercentUsed"])
            ?? max(number(usage["autoPercentUsed"]) ?? 0, number(usage["apiPercentUsed"]) ?? 0)
        let start = number(root["billingCycleStart"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        let end = number(root["billingCycleEnd"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        let period = zip2(start, end).map { $1.timeIntervalSince($0) }

        var plan = readItem("cursorAuth/stripeMembershipType")
        let (planStatus, planBody) = await post("GetPlanInfo", token: token)
        if planStatus == 200, let info = jsonObject(planBody)?["planInfo"] as? [String: Any],
           let name = info["planName"] as? String, !name.isEmpty {
            plan = name
        }
        return singleWindow(percent / 100, resetAt: end, period: period, plan: plan?.lowercased())
    }

    private static func zip2(_ a: Date?, _ b: Date?) -> (Date, Date)? {
        guard let a, let b else { return nil }
        return (a, b)
    }

    private static func post(_ method: String, token: String) async -> (Int, Data) {
        guard let url = URL(string: rpcBase + method) else { return (0, Data()) }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Connect refuses a request that doesn't state its protocol version.
        req.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        req.setValue("connect-es/1.6.1", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            return (0, Data())
        }
    }

    /// Opens read-only WITH the WAL, so a token Cursor refreshed moments ago
    /// is visible; immutable mode is only the fallback when that open fails.
    static func readItem(_ key: String) -> String? {
        let path = databaseURL.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        for uri in ["file:\(path)?mode=ro", "file:\(path)?mode=ro&immutable=1"] {
            var db: OpaquePointer?
            defer { sqlite3_close(db) }
            guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { continue }
            sqlite3_busy_timeout(db, 500)
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { continue }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, key, -1, transient)
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) {
                return String(cString: text)
            }
            if step == SQLITE_DONE { return nil }
        }
        return nil
    }
}

// MARK: - Grok

/// The Grok CLI's own billing proxy: the weekly credit pool plus the monthly
/// dollar budget. Strictly read-only on `~/.grok/auth.json` — refreshing
/// would rotate the refresh token out from under the CLI, and a third-party
/// writeback is what produced the `auth.json.corrupt.*` files seen in the
/// wild. An expired token simply waits for the CLI's next run.
enum GrokUsage {
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok", isDirectory: true)
    }
    static var authURL: URL { home.appendingPathComponent("auth.json") }

    private static let billingURL = "https://cli-chat-proxy.grok.com/v1/billing"
    static let expiredMessage = "run grok to refresh"

    static func fetch() async -> AppUsage {
        guard let data = try? Data(contentsOf: authURL), let root = jsonObject(data),
              let entry = root.values.compactMap({ $0 as? [String: Any] }).first,
              let token = entry["key"] as? String, !token.isEmpty else {
            return errorUsage(L10n.tr("sign in to Grok"))
        }
        if let expiry = expiryDate(entry["expires_at"]), expiry < Date() {
            return errorUsage(L10n.tr(expiredMessage))
        }
        let version = cliVersion()
        async let weeklyCall = get(billingURL + "?format=credits", token: token, version: version)
        async let monthlyCall = get(billingURL, token: token, version: version)
        let (status, body) = await weeklyCall
        let (monthlyStatus, monthlyBody) = await monthlyCall
        switch status {
        case 200: break
        case 401, 403: return errorUsage(L10n.tr(expiredMessage))
        case 0: return errorUsage(L10n.tr("network drop"))
        default: return errorUsage("http \(status)")
        }
        guard let config = jsonObject(body)?["config"] as? [String: Any] else {
            return errorUsage(L10n.tr("parse error"))
        }
        // The weekly payload omits creditUsagePercent at zero usage —
        // absence is data, not an error.
        let percent = number(config["creditUsagePercent"]) ?? 0
        let period = config["currentPeriod"] as? [String: Any]
        let start = timestamp(period?["start"])
        let end = timestamp(period?["end"]) ?? timestamp(config["billingPeriodEnd"])
        let length = (start != nil && end != nil) ? end!.timeIntervalSince(start!) : 7 * 86400

        var detail: String?
        if monthlyStatus == 200, let monthly = jsonObject(monthlyBody)?["config"] as? [String: Any],
           let limit = number((monthly["monthlyLimit"] as? [String: Any])?["val"]), limit > 0 {
            let used = number((monthly["used"] as? [String: Any])?["val"]) ?? 0
            detail = L10n.tr("%@ / %@ monthly", dollars(used), dollars(limit))
        }
        return singleWindow(percent / 100, resetAt: end, period: length, plan: nil, detail: detail)
    }

    private static func dollars(_ cents: Double) -> String {
        let value = max(0, cents) / 100
        return value.rounded() == value ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    private static func cliVersion() -> String {
        let url = home.appendingPathComponent("version.json")
        return (try? Data(contentsOf: url)).flatMap(jsonObject)?["version"] as? String ?? "1.0.5"
    }

    private static func get(_ url: String, token: String, version: String) async -> (Int, Data) {
        guard let url = URL(string: url) else { return (0, Data()) }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        req.setValue(version, forHTTPHeaderField: "x-grok-client-version")
        req.setValue("grok-pager/\(version) grok-shell/\(version) (macos; aarch64)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            return (0, Data())
        }
    }

    /// The CLI writes an ISO string; tolerate epoch seconds/millis too.
    private static func expiryDate(_ raw: Any?) -> Date? {
        if let seconds = number(raw), !(raw is String) {
            return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds)
        }
        return timestamp(raw)
    }

    /// Grok stamps 6-digit fractional seconds, which ISO8601DateFormatter
    /// rejects; trim the fraction to milliseconds first.
    private static func timestamp(_ raw: Any?) -> Date? {
        guard var text = raw as? String, !text.isEmpty else { return nil }
        if let dot = text.firstIndex(of: "."),
           let tail = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let fraction = text[text.index(after: dot)..<tail].prefix(3)
            text = String(text[..<dot]) + "." + fraction + String(text[tail...])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
