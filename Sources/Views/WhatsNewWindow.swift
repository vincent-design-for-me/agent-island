import AppKit
import SwiftUI

/// One-time "what's new" pages after an update. Shown once per version that
/// is newer than the last one seen (same key 2.x used, so upgrading from
/// 2.1.1 still counts as an update); the settings footer can reopen it.
@MainActor
final class WhatsNewWindowController: NSWindowController, NSWindowDelegate {
    static let shared = WhatsNewWindowController()

    private static let seenKey = "AgentIsland.whatsNewSeenVersion"

    private init() { super.init(window: nil) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Called at launch. `AGENTISLAND_WHATSNEW=1` forces it for checks.
    func showIfUpdated() {
        let forced = ProcessInfo.processInfo.environment["AGENTISLAND_WHATSNEW"] == "1"
        let seen = UserDefaults.standard.string(forKey: Self.seenKey)
        // A fresh install has nothing to compare against — no tour of
        // "changes" the user never saw the before of.
        guard forced || (seen.map { Self.isNewer(Self.currentVersion, than: $0) } ?? false) else {
            if seen == nil { UserDefaults.standard.set(Self.currentVersion, forKey: Self.seenKey) }
            return
        }
        show()
    }

    func show() {
        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: NSSize(width: 520, height: 440)),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            // Panels hide on deactivate by default; with no Dock icon the
            // tour would vanish for good the moment the user clicks away.
            panel.hidesOnDeactivate = false
            panel.backgroundColor = NSColor(calibratedRed: 0.043, green: 0.047, blue: 0.055, alpha: 1)
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.delegate = self
            window = panel
        }
        window?.contentView = NSHostingView(rootView: WhatsNewView { [weak self] in self?.close() })
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(Self.currentVersion, forKey: Self.seenKey)
    }

    /// Component-wise numeric compare ("2.2.0" > "2.1.1"), the same rule
    /// Sparkle applies to CFBundleVersion.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let lhs = a.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

private struct WhatsNewPage {
    let symbol: String
    let title: String
    let body: String
}

private struct WhatsNewView: View {
    let onDone: () -> Void
    @State private var index = 0

    private let pages: [WhatsNewPage] = [
        WhatsNewPage(symbol: "sparkles", title: "What's new in this version",
                     body: "Claude sign-in works again, new models are priced, and three new providers join the island."),
        WhatsNewPage(symbol: "key.horizontal", title: "Sign-in that lands right",
                     body: "Pick the browser or Chrome profile the Claude sign-in opens in, use an incognito window, copy the link, or paste a code."),
        WhatsNewPage(symbol: "person.2", title: "Codex account switching",
                     body: "Save each Codex login under a name and switch in one click. Optionally rotate to the next account when one runs out."),
        WhatsNewPage(symbol: "square.grid.2x2", title: "Cursor and Grok, any two on the notch",
                     body: "Cursor's billing period and Grok's weekly pool show under Claude and Codex. Choose any two providers for the notch."),
        WhatsNewPage(symbol: "calendar", title: "Reports for any date",
                     body: "Pick a start date for the weekly card or step back through months. Opus 5, Opus 5.5 and Fable 5.1 are now priced."),
    ]

    var body: some View {
        let page = pages[index]
        VStack(spacing: 0) {
            Spacer(minLength: 36)
            Image(systemName: page.symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(IslandColor.liveTeal)
                .frame(width: 76, height: 76)
                .background(Circle().fill(IslandColor.liveTeal.opacity(0.10)))
                .overlay(Circle().strokeBorder(IslandColor.liveTeal.opacity(0.3), lineWidth: 0.5))
                .id(index)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            Text(L10n.tr(page.title))
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
                .multilineTextAlignment(.center)
                .padding(.top, 24)
            Text(L10n.tr(page.body))
                .font(.system(size: 13.5))
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 380)
                .padding(.top, 10)
            Spacer()
            HStack {
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == index ? IslandColor.liveTeal : .white.opacity(0.18))
                            .frame(width: i == index ? 18 : 6, height: 6)
                    }
                }
                Spacer()
                if index > 0 {
                    Button(L10n.tr("Back")) { withAnimation(.easeOut(duration: 0.2)) { index -= 1 } }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.trailing, 14)
                }
                Button {
                    if index == pages.count - 1 { onDone() } else {
                        withAnimation(.easeOut(duration: 0.2)) { index += 1 }
                    }
                } label: {
                    Text(L10n.tr(index == pages.count - 1 ? "Got it" : "Next"))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20)
                        .frame(height: 34)
                        .background(Capsule().fill(IslandColor.liveTeal))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .frame(width: 520, height: 440)
        .preferredColorScheme(.dark)
    }
}
