import AppKit

/// Where the Claude sign-in page opens. The default browser is often signed
/// in to the wrong claude.ai account, so the user can pin a specific
/// Chromium profile, or an incognito window for a clean sign-in. The choice
/// persists; `open(_:)` falls back to the default browser if the pinned one
/// has since been removed.
enum ClaudeSignInBrowser: Equatable {
    case systemDefault
    case profile(Chromium, directory: String)
    case incognito(Chromium)

    struct Chromium: Equatable {
        let id: String
        let name: String
        let bundleID: String
        /// Folder under ~/Library/Application Support holding `Local State`.
        let supportPath: String
    }

    struct ProfileChoice: Identifiable {
        let browser: Chromium
        let directory: String
        let name: String
        var id: String { "\(browser.id)/\(directory)" }
    }

    static let chromiumBrowsers = [
        Chromium(id: "chrome", name: "Chrome", bundleID: "com.google.Chrome", supportPath: "Google/Chrome"),
        Chromium(id: "edge", name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", supportPath: "Microsoft Edge"),
        Chromium(id: "brave", name: "Brave", bundleID: "com.brave.Browser", supportPath: "BraveSoftware/Brave-Browser"),
    ]

    private static let key = "AgentIsland.claudeSignInBrowser"

    static var current: ClaudeSignInBrowser {
        get { UserDefaults.standard.string(forKey: key).flatMap(ClaudeSignInBrowser.init(rawValue:)) ?? .systemDefault }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    // MARK: - Discovery

    static var installed: [Chromium] {
        chromiumBrowsers.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    /// Profiles listed in each installed browser's `Local State`, in the
    /// browser's own order, with the names the user gave them.
    static func profiles() -> [ProfileChoice] {
        installed.flatMap { browser -> [ProfileChoice] in
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/\(browser.supportPath)/Local State")
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let profile = root["profile"] as? [String: Any],
                  let cache = profile["info_cache"] as? [String: [String: Any]] else { return [] }
            let order = (profile["profiles_order"] as? [String]) ?? cache.keys.sorted()
            return order.compactMap { dir in
                guard let info = cache[dir] else { return nil }
                return ProfileChoice(browser: browser, directory: dir, name: (info["name"] as? String) ?? dir)
            }
        }
    }

    static var defaultBrowserName: String? {
        guard let probe = URL(string: "https://claude.ai"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: - Opening

    func open(_ url: URL) {
        switch self {
        case .systemDefault:
            NSWorkspace.shared.open(url)
        case .profile(let browser, let directory):
            Self.launch(browser, arguments: ["--profile-directory=\(directory)"], url: url)
        case .incognito(let browser):
            Self.launch(browser, arguments: ["--incognito"], url: url)
        }
    }

    private static func launch(_ browser: Chromium, arguments: [String], url: URL) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else {
            NSWorkspace.shared.open(url)
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-na", app.path, "--args"] + arguments + [url.absoluteString]
        do {
            try task.run()
        } catch {
            NSLog("AgentIsland: could not open %@: %@", browser.name, error.localizedDescription)
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Persistence

    var rawValue: String {
        switch self {
        case .systemDefault: "default"
        case .profile(let browser, let directory): "profile:\(browser.id):\(directory)"
        case .incognito(let browser): "incognito:\(browser.id)"
        }
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 2).map(String.init)
        let browser = parts.count > 1 ? Self.chromiumBrowsers.first { $0.id == parts[1] } : nil
        switch (parts.first, browser) {
        case ("default", _): self = .systemDefault
        case ("profile", let browser?) where parts.count == 3: self = .profile(browser, directory: parts[2])
        case ("incognito", let browser?): self = .incognito(browser)
        default: return nil
        }
    }
}
