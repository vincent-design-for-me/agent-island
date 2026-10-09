import AppKit
import SwiftUI

/// Person-icon menu on the Codex provider row: switch between parked
/// logins, save the current one under a name, forget one, and opt in to
/// rotating automatically when the live account runs out.
struct CodexAccountMenu: View {
    @ObservedObject var usage: UsageStore

    var body: some View {
        Menu {
            Section(L10n.tr("Switch Codex account")) {
                if usage.codexAccounts.isEmpty {
                    Text(L10n.tr("No saved accounts yet"))
                }
                ForEach(usage.codexAccounts) { account in
                    Button {
                        usage.switchCodexAccount(account)
                    } label: {
                        if account.label == usage.activeCodexAccountLabel {
                            Label(title(for: account), systemImage: "checkmark")
                        } else {
                            Text(title(for: account))
                        }
                    }
                }
            }
            Divider()
            Button(L10n.tr("Save current account…")) { promptSave() }
            if !usage.codexAccounts.isEmpty {
                Menu(L10n.tr("Remove saved account")) {
                    ForEach(usage.codexAccounts) { account in
                        Button(title(for: account)) { usage.forgetCodexAccount(account) }
                    }
                }
            }
            Divider()
            Toggle(L10n.tr("Auto-switch when exhausted"), isOn: $usage.codexAutoSwitch)
            if CodexCredentials.canPromptReauth() {
                Divider()
                Button(L10n.tr(usage.codexReauthInProgress ? "waiting for login…" : "Re-authenticate")) {
                    usage.reauthenticateCodex()
                }
                .disabled(usage.codexReauthInProgress)
            }
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help(L10n.tr("Codex account switching"))
        .onAppear { usage.reloadCodexAccounts() }
    }

    private func title(for account: CodexAccountSwitcher.Account) -> String {
        guard let email = account.email, email != account.label else { return account.label }
        return "\(account.label) · \(email)"
    }

    private func promptSave() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Save current account…")
        alert.informativeText = L10n.tr("Give this login a name so you can switch back to it later")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = L10n.tr("e.g. Work")
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.tr("Save"))
        alert.addButton(withTitle: L10n.tr("Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let label = CodexAccountSwitcher.sanitize(field.stringValue)
        guard !label.isEmpty else { return }
        usage.saveCurrentCodexAccount(label: label)
    }
}
