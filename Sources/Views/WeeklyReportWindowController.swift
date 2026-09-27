import AppKit
import SwiftUI

/// Renders the weekly report card to a crisp PNG (3x) and hosts the share
/// window. Sharing is always the USER posting an image — nothing leaves
/// the machine on its own.
@MainActor
enum WeeklyReportRenderer {
    /// The EXPORT version is the card itself, full-bleed with SQUARE outer
    /// corners and no backdrop margin: social apps flatten transparency to
    /// white (ugly corner nicks) and a margin frame read as a gray box
    /// around the card. Edge-to-edge card = clean everywhere.
    private static func exportView() -> some View {
        WeeklyReportCard(data: .current(), rounded: false)
    }

    // The 3x render of the full card (QR included) costs seconds — doing it
    // on every click made copy/share feel broken. Render once per window
    // open, serve every action from the cache.
    private static var cachedImage: NSImage?
    private static var cachedPNG: Data?

    static func invalidateCache() {
        cachedImage = nil
        cachedPNG = nil
    }

    /// Pre-render off the click path (fired right after the window shows).
    static func warmCache() {
        _ = pngData()
    }

    static func image() -> NSImage? {
        if let cachedImage { return cachedImage }
        let renderer = ImageRenderer(content: exportView())
        renderer.scale = 3
        renderer.isOpaque = true
        cachedImage = renderer.nsImage
        return cachedImage
    }

    static func pngData() -> Data? {
        if let cachedPNG { return cachedPNG }
        guard let image = image(),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        cachedPNG = rep.representation(using: .png, properties: [:])
        return cachedPNG
    }

    /// Headless snapshot for tooling/screenshots:
    /// AGENTISLAND_REPORT_SNAPSHOT=/path.png renders and exits.
    static func writePNG(to path: String) {
        guard let data = pngData() else {
            NSLog("AgentIsland report: render failed")
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

/// The window IS the card — fully borderless, because on macOS 26 a titled
/// window brings a liquid-glass slab behind the content (the "虚无缥缈的
/// 背景"). The genuine traffic-light close button is mounted manually
/// instead: NSWindow.standardWindowButton(...) gives the real AppKit
/// control (hover ✕ included), placed on the card's top-left corner.
/// Esc also closes; drag anywhere to move.
private final class ReportPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class WeeklyReportWindowController: NSWindowController, NSWindowDelegate {
    static let shared = WeeklyReportWindowController()

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        // Fresh data per open; the warm render below makes every button
        // instant afterwards.
        WeeklyReportRenderer.invalidateCache()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            WeeklyReportRenderer.warmCache()
        }
        if window == nil {
            let panel = ReportPanel(
                // Hugs the content exactly (card 420 + 26pt margins; buttons
                // below) — a window wider than its content reads as a ghost
                // slab around the card.
                contentRect: NSRect(origin: .zero, size: NSSize(width: 472, height: 708)),
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false // the card paints its own shadow
            panel.isMovableByWindowBackground = true
            // Screenshot tools (⇧⌘4/5) deactivate the app; panels hide on
            // deactivate by default, which made the card "jump away" the
            // moment the user tried to capture it.
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.delegate = self
            window = panel
        }
        // Rebuilt EVERY show — a cached SwiftUI tree kept serving stale data
        // and the pre-switch language ("English UI, Chinese poster").
        window?.contentView = NSHostingView(rootView: WeeklyReportSheet())
        mountCloseButton()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The REAL red traffic light (hover ✕ and all), mounted onto the card's
    /// top-left like a normal window — without the titled style that drags
    /// the macOS 26 glass slab along. Re-mounted whenever contentView is
    /// replaced (the old button dies with the old view).
    private func mountCloseButton() {
        guard let contentView = window?.contentView,
              let close = NSWindow.standardWindowButton(.closeButton, for: [.titled, .closable])
        else { return }
        close.target = window
        close.action = #selector(NSWindow.close)
        contentView.addSubview(close)
        // Card sits at (26, 22) from the top-left of the content; native
        // windows inset the light ~12pt into the corner. NSHostingView is
        // FLIPPED (y grows downward) — measuring from the bottom edge parked
        // the light at the bottom.
        let inset: CGFloat = 12
        let yFromTop: CGFloat = 22 + inset
        let y = contentView.isFlipped
            ? yFromTop
            : contentView.bounds.height - yFromTop - close.frame.height
        close.setFrameOrigin(NSPoint(x: 26 + inset, y: y))
    }
}

@MainActor
private struct WeeklyReportSheet: View {
    // Observing the store keeps the card live: opening the window kicks a
    // rescan, and when it commits the card re-renders on the fresh window
    // instead of freezing whatever snapshot launch restored (the "one model
    // row bigger than the weekly total" screenshots were day-old snapshots).
    @ObservedObject private var cost = CostStore.shared
    @ObservedObject private var tokenMode = TokenCountModeStore.shared
    @ObservedObject private var reportRange = ReportRangeStore.shared
    @State private var copied = false
    @State private var coach: String?
    @State private var shareAnchor: NSView?
    // NSSharingServicePicker dies if released while on screen — park it.
    @State private var pickerHolder = PickerHolder()

    var body: some View {
        VStack(spacing: 14) {
            WeeklyReportCard(data: .current())
                // A tight, grounded shadow — the old radius-34/0.6 halo was
                // the "floating on fog" feel, not any system glass.
                .shadow(color: .black.opacity(0.30), radius: 10, y: 4)

            // Two actions, identical pills, both instant (renders come from
            // the warm cache). Copy → paste anywhere; Share → the system
            // share picker (AirDrop / Messages / installed extensions).
            ReportRangeBar(kind: .weekly)

            HStack(spacing: 10) {
                actionButton(copied ? L10n.tr("Copied") : L10n.tr("Copy image"), prominent: true) {
                    if copyImage() {
                        copied = true
                        showCoach(L10n.tr("Copied! Post it and bring a friend to the island 🏝️ Thanks for spreading the word"))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                    }
                }
                actionButton(L10n.tr("Share…"), prominent: true) {
                    showCoach(L10n.tr("Tip: AirDrop it to your iPhone — it lands in Photos, ready to post 📲"))
                    openSharePicker()
                }
                .background(
                    // Invisible AppKit anchor the picker popover attaches
                    // to — keeps the visible control a pixel-identical
                    // SwiftUI pill (a real NSButton never matched).
                    ShareAnchorView { shareAnchor = $0 }
                        .frame(width: 1, height: 1)
                )
            }

            // Fixed one-line slot so the window never reflows.
            Text(coach ?? " ")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 0.62))
                .lineLimit(1)
                .opacity(coach == nil ? 0 : 1)
                .animation(.easeOut(duration: 0.2), value: coach == nil)
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 12)
        .onAppear {
            // A fresh scan self-heals a stale launch snapshot within seconds;
            // the observed store re-renders the card when it commits.
            CostStore.shared.refresh()
        }
        .onReceive(cost.objectWillChange) { _ in
            WeeklyReportRenderer.invalidateCache()
            // Re-warm off the click path once the new values have landed.
            DispatchQueue.main.async { WeeklyReportRenderer.warmCache() }
        }
        .onReceive(tokenMode.objectWillChange) { _ in
            WeeklyReportRenderer.invalidateCache()
            DispatchQueue.main.async { WeeklyReportRenderer.warmCache() }
        }
        .onReceive(reportRange.objectWillChange) { _ in
            WeeklyReportRenderer.invalidateCache()
            DispatchQueue.main.async { WeeklyReportRenderer.warmCache() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandDemoCommand)) { note in
            // Recording rig: replay the copy interaction on cue.
            if (note.userInfo?["cmd"] as? String) == "report:copy", copyImage() {
                copied = true
                showCoach(L10n.tr("Copied! Post it and bring a friend to the island 🏝️ Thanks for spreading the word"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
            }
        }
    }

    private func showCoach(_ text: String) {
        coach = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if coach == text { coach = nil }
        }
    }

    @MainActor
    private func openSharePicker() {
        guard let image = WeeklyReportRenderer.image(), let anchor = shareAnchor else { return }
        let picker = NSSharingServicePicker(items: [image])
        pickerHolder.picker = picker
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    @discardableResult
    private func copyImage() -> Bool {
        guard let image = WeeklyReportRenderer.image() else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        return true
    }

    private func actionButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(prominent ? .black : .white.opacity(0.85))
                .padding(.horizontal, 16)
                .frame(height: 30)
                .background(
                    Capsule().fill(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.12)))
                )
        }
        .buttonStyle(.plain)
    }
}

/// Zero-size AppKit view used purely as the NSSharingServicePicker anchor.
private struct ShareAnchorView: NSViewRepresentable {
    let onReady: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onReady(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// Plain retain box (no actor isolation): @MainActor here broke CI —
// a @State default value is initialized in a nonisolated context, and
// newer compilers reject the implicit hop. The picker itself is only
// ever touched from the view body (main thread) anyway.
private final class PickerHolder {
    var picker: NSSharingServicePicker?
}
