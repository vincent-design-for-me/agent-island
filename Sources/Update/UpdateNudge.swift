import AppKit

/// "A new version is out" nudge backed by the GitHub Releases API.
///
/// Sparkle stays wired for the day an appcast feed exists, but today
/// `SUFeedURL` is empty — Sparkle finds nothing, and users sit on old
/// versions forever (owner's call, 2026-07-16: the prompt must appear).
/// This checks the latest release at launch and every 6 hours; when a newer
/// version exists it puts up a two-button alert — "Update" opens the release
/// page, "I know" snoozes that version for 7 days. A release newer than the
/// snoozed one prompts again immediately.
@MainActor
final class UpdateNudge {
    static let shared = UpdateNudge()

    private static let snoozeVersionKey = "AgentIsland.updateNudgeVersion"
    private static let snoozeUntilKey = "AgentIsland.updateNudgeUntil"
    private static let latestAPI = URL(string: "https://api.github.com/repos/vincent-design-for-me/agent-island/releases/latest")!

    private var timer: Timer?
    private var alertShowing = false

    private init() {}

    func start() {
        // First check rides 20s behind launch: the usage warm-up and the
        // weekly-report moment (10s) get the stage first.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            await self.checkQuietly()
        }
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await UpdateNudge.shared.checkQuietly() }
        }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Background cadence: silent unless a fresh, un-snoozed version exists.
    /// Respects the Settings "Check for updates automatically" switch.
    func checkQuietly() async {
        guard UpdaterController.shared.automaticallyChecks else { return }
        guard let latest = await Self.fetchLatest() else { return }
        guard Self.isNewer(latest.version, than: Self.currentVersion),
              !isSnoozed(latest.version) else { return }
        present(latest)
    }

    /// Settings "Check now": always answers — new version, up to date, or
    /// the check failed.
    func checkNow() async {
        guard let latest = await Self.fetchLatest() else {
            inform(L10n.tr("Couldn't check for updates"))
            return
        }
        if Self.isNewer(latest.version, than: Self.currentVersion) {
            present(latest)
        } else {
            inform(L10n.tr("You're up to date"))
        }
    }

    // MARK: - Release lookup

    struct Release {
        let version: String
        let pageURL: URL
    }

    static func fetchLatest() async -> Release? {
        var request = URLRequest(url: latestAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/vincent-design-for-me/agent-island/releases/latest")!
        return Release(version: version, pageURL: page)
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Numeric dotted compare; unequal lengths pad with zeros ("1.6.2" >
    /// "1.6", "1.10.0" > "1.9.9"). Non-numeric parts compare as 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Presentation

    private func present(_ release: Release) {
        guard !alertShowing else { return }
        alertShowing = true
        defer { alertShowing = false }

        let alert = NSAlert()
        alert.messageText = L10n.tr("Update available")
        alert.informativeText = L10n.tr(
            "Agent Island %@ is out — you're on %@",
            release.version, Self.currentVersion
        )
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: L10n.tr("Update"))
        alert.addButton(withTitle: L10n.tr("I know"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.pageURL)
        } else {
            snooze(release.version)
        }
    }

    private func inform(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: L10n.tr("OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Snooze

    private func isSnoozed(_ version: String) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.snoozeVersionKey) == version,
              let until = defaults.object(forKey: Self.snoozeUntilKey) as? Date
        else { return false }
        return Date() < until
    }

    private func snooze(_ version: String) {
        let defaults = UserDefaults.standard
        defaults.set(version, forKey: Self.snoozeVersionKey)
        defaults.set(Date().addingTimeInterval(7 * 86400), forKey: Self.snoozeUntilKey)
    }
}
