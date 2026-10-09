import SwiftUI
import AppKit

/// Bottom footer for the Settings window. GitHub / License as dotted-
/// underline links, Quit pill flush right. Version lives in the brand
/// header at the top of the window.
struct SettingsFooter: View {
    @State private var quitHovered = false

    private static let githubURL = URL(string: "https://github.com/vincent-design-for-me/agent-island")!

    var body: some View {
        // GitHub + Quit on the left, the two share CTAs flush right
        // (owner's layout, 2026-07-14; License link dropped).
        HStack(alignment: .center, spacing: 14) {
            link("GitHub", url: Self.githubURL)
            DottedLink(title: L10n.tr("What's new")) {
                WhatsNewWindowController.shared.show()
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                Text(L10n.tr("Quit"))
                    .font(Typography.label)
                    .fixedSize()
                    .foregroundStyle(.white.opacity(quitHovered ? 0.92 : 0.55))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white.opacity(quitHovered ? 0.06 : 0.03))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
                            }
                    }
            }
            .buttonStyle(.plain)
            .onHover { quitHovered = $0 }
            .help(L10n.tr("Quit AgentIsland"))
            .animation(.strongEaseOut, value: quitHovered)

            Spacer()

            // Short labels — the full 'Share weekly report' pair overflowed
            // the 480pt window in English and crushed Quit into a vertical
            // letter-stack. Hover help carries the full wording.
            sharePill(L10n.tr("Weekly"), help: L10n.tr("Share weekly report")) {
                WeeklyReportWindowController.shared.show()
            }
            sharePill(L10n.tr("Monthly"), help: L10n.tr("Share monthly report")) {
                MonthlyReportWindowController.shared.show()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func sharePill(_ title: String, help: String,
                           action: @escaping () -> Void) -> some View {
        SharePillButton(title: title, help: help, action: action)
    }

    @ViewBuilder
    private func link(_ title: String, url: URL) -> some View {
        DottedLink(title: title) {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct SharePillButton: View {
    let title: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 9.5, weight: .bold))
                Text(title)
                    .font(Typography.label.weight(.bold))
                    .lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(hovered ? 1.0 : 0.92))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .animation(.strongEaseOut, value: hovered)
    }
}

private struct DottedLink: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(L10n.tr(title))
                    .font(Typography.label)
                    .foregroundStyle(.white.opacity(hovered ? 0.92 : 0.55))
                Text("↗")
                    .font(Typography.micro)
                    .foregroundStyle(.white.opacity(hovered ? 0.6 : 0.3))
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.white.opacity(hovered ? 0.32 : 0.18))
                    .frame(height: 0.5)
                    .offset(y: 1)
                    .mask(
                        // Dotted via repeating gradient
                        LinearGradient(
                            colors: [.black, .clear, .black, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
            .padding(.bottom, 2)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.10), value: hovered)
    }
}
