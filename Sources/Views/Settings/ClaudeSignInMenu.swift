import SwiftUI

/// Arrow menu beside Claude's Re-authenticate button: pick which browser or
/// profile the sign-in opens in (picking one also starts it), or fall back
/// to copying the link or pasting a code.
struct ClaudeSignInMenu: View {
    @ObservedObject var usage: UsageStore

    var body: some View {
        Menu {
            if usage.claudeReauthInProgress {
                Button(L10n.tr("Cancel sign-in")) { usage.cancelClaudeSignIn() }
            } else {
                Section(L10n.tr("Choose where the sign-in opens")) {
                    choice(.systemDefault, title: defaultTitle)
                    ForEach(ClaudeSignInBrowser.profiles()) { profile in
                        choice(
                            .profile(profile.browser, directory: profile.directory),
                            title: "\(profile.browser.name) · \(profile.name)"
                        )
                    }
                    ForEach(ClaudeSignInBrowser.installed, id: \.id) { browser in
                        choice(.incognito(browser), title: L10n.tr("Incognito window (%@)", browser.name))
                    }
                }
                Divider()
                Button(L10n.tr("Copy login link")) { usage.reauthenticateClaude(.copyLink) }
                Button(L10n.tr("Sign in with a code")) { usage.reauthenticateClaude(.code) }
                Divider()
                Text(L10n.tr("Account not in any browser? Incognito gives it a clean sign-in"))
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.tr("Opens the Claude sign-in page with your saved browser choice"))
    }

    private var defaultTitle: String {
        let base = L10n.tr("Default browser")
        return ClaudeSignInBrowser.defaultBrowserName.map { "\(base) · \($0)" } ?? base
    }

    private func choice(_ browser: ClaudeSignInBrowser, title: String) -> some View {
        Button {
            ClaudeSignInBrowser.current = browser
            usage.reauthenticateClaude(.browser)
        } label: {
            if ClaudeSignInBrowser.current == browser {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}
