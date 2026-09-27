import SwiftUI
import AppKit
import CoreImage

/// The monthly share card — the weekly card's big sibling. v3 (locked
/// 2026-07-17): the 24-week heatmap is gone (owner's cut — it competed with
/// the model table and duplicated the panel's own year view); the month
/// reads hero → faction duel → TOP-5 models → rank. Same no-upload rules:
/// rendered from local logs only.
struct MonthlyReportData {
    let monthText: String          // "2026年7月" / "July 2026"
    let totalTokens: Int           // calendar month to date, wire
    let totalDollars: Double
    let claudeShare: Double
    let topModels: [WeeklyReportData.ModelShare]
    let lifetimeText: String
    let tierEmoji: String?
    let tierName: String?

    @MainActor
    static func current() -> MonthlyReportData {
        let cost = CostStore.shared
        let mode = TokenCountModeStore.shared.mode
        let today = Calendar.current.startOfDay(for: Date())
        let zh = L10n.locale.identifier.hasPrefix("zh")

        var claudeTokens = mode == .all ? cost.claude.month.tokens : cost.claude.month.billableTokens
        var codexTokens = mode == .all ? cost.codex.month.tokens : cost.codex.month.billableTokens
        var claudeRows = cost.claude.monthByModel
        var codexRows = cost.codex.monthByModel
        var monthDate = today
        let cal = Calendar.current
        // A custom month rebuilds every figure from the daily history.
        if let picked = ReportRangeStore.shared.month,
           let start = cal.date(from: cal.dateComponents([.year, .month], from: picked)),
           let end = cal.date(byAdding: .month, value: 1, to: start) {
            func sum(_ buckets: [DailyTokenBucket]) -> Int {
                buckets.filter { $0.dayStart >= start && $0.dayStart < end }
                    .reduce(0) { $0 + (mode == .all ? $1.tokens : $1.billableTokens) }
            }
            claudeTokens = sum(cost.claude.dailyTokens)
            codexTokens = sum(cost.codex.dailyTokens)
            claudeRows = CostSummary.modelRows(daily: cost.claude.dailyByModel, from: start, to: end)
            codexRows = CostSummary.modelRows(daily: cost.codex.dailyByModel, from: start, to: end)
            monthDate = start
        }
        let totalTokens = claudeTokens + codexTokens
        let totalDollars = ReportRangeStore.shared.month == nil
            ? cost.claude.month.dollars + cost.codex.month.dollars
            : (claudeRows + codexRows).reduce(0.0) { $0 + $1.dollars }
        let claudeShare = totalTokens > 0 ? Double(claudeTokens) / Double(totalTokens) : 0

        let models = WeeklyReportData.rankedModels(
            claudeRows: claudeRows,
            codexRows: codexRows,
            limit: 5,
            mode: mode
        )

        let df = DateFormatter()
        df.locale = zh ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US_POSIX")
        df.dateFormat = zh ? "yyyy年M月" : "MMMM yyyy"

        let lifetime = (cost.claude.dailyTokens + cost.codex.dailyTokens)
            .reduce(0) { $0 + $1.tokens }
        let tier = MilestoneLadder.tokenTier(lifetime: lifetime)

        return MonthlyReportData(
            monthText: df.string(from: monthDate),
            totalTokens: totalTokens,
            totalDollars: totalDollars,
            claudeShare: claudeShare,
            topModels: models,
            lifetimeText: WeeklyReportCard.compactString(lifetime, zh: zh),
            tierEmoji: tier?.emoji,
            tierName: tier?.nameKey
        )
    }
}

struct MonthlyReportCard: View {
    let data: MonthlyReportData
    var rounded: Bool = true

    static let size = CGSize(width: 420, height: 560)

    var body: some View {
        ZStack {
            background

            VStack(alignment: .leading, spacing: 0) {
                ReportCardHeader(kind: "MONTHLY", periodText: data.monthText)
                Spacer(minLength: 18)
                hero
                Spacer(minLength: 18)
                ReportDuel(claudeShare: data.claudeShare)
                Spacer(minLength: 22)
                ReportModelTable(models: data.topModels)
                Spacer(minLength: 22)
                ReportRankBlock(lifetimeText: data.lifetimeText,
                                tierEmoji: data.tierEmoji, tierName: data.tierName)
            }
            .padding(28)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: rounded ? CardWindow.cornerRadius : 0, style: .continuous))
    }

    private var background: some View {
        ZStack {
            RoundedRectangle(cornerRadius: rounded ? CardWindow.cornerRadius : 0, style: .continuous)
                .fill(WeeklyReportCard.baseCoat)
            RoundedRectangle(cornerRadius: rounded ? CardWindow.cornerRadius : 0, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        }
    }

    private var hero: some View {
        let zh = L10n.locale.identifier.hasPrefix("zh")
        let parts = WeeklyReportCard.compactParts(data.totalTokens, zh: zh)
        return VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("tokens this month"))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .tracking(0.3)
                .foregroundStyle(.white.opacity(0.5))
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(parts.0)
                        .font(.system(size: 50, weight: .heavy))
                    if !parts.1.isEmpty {
                        Text(parts.1)
                            .font(.system(size: zh ? 24 : 50, weight: .heavy))
                    }
                }
                .foregroundStyle(Color(red: 0.95, green: 0.96, blue: 0.97))
                // The number NEVER wraps or truncates — it wins the row,
                // and the money line shrinks instead (420pt card, zh money
                // string is long; unguarded this wrapped mid-number).
                .fixedSize()
                .layoutPriority(2)
                if data.totalDollars >= 1 {
                    Text(L10n.tr("≈ $%@ API value", WeeklyReportCard.money(data.totalDollars)))
                        .font(.system(size: 12.5, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(IslandColor.brandTeal)
                }
            }
        }
    }
}

// MARK: - Renderer + window (mirrors the weekly pair)

@MainActor
enum MonthlyReportRenderer {
    private static var cachedImage: NSImage?
    private static var cachedPNG: Data?

    static func invalidateCache() {
        cachedImage = nil
        cachedPNG = nil
    }

    static func warmCache() {
        _ = pngData()
    }

    static func image() -> NSImage? {
        if let cachedImage { return cachedImage }
        let renderer = ImageRenderer(content: MonthlyReportCard(data: .current(), rounded: false))
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

    static func writePNG(to path: String) {
        guard let data = pngData() else {
            NSLog("AgentIsland monthly report: render failed")
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

private final class MonthlyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class MonthlyReportWindowController: NSWindowController, NSWindowDelegate {
    static let shared = MonthlyReportWindowController()

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        MonthlyReportRenderer.invalidateCache()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MonthlyReportRenderer.warmCache()
        }
        if window == nil {
            let panel = MonthlyPanel(
                contentRect: NSRect(origin: .zero, size: NSSize(width: 472, height: 708)),
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.delegate = self
            window = panel
        }
        // Rebuilt EVERY show — a cached SwiftUI tree kept serving stale data
        // and the pre-switch language (the "English UI, Chinese poster" bug).
        window?.contentView = NSHostingView(rootView: MonthlyReportSheet())
        mountCloseButton()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func mountCloseButton() {
        guard let contentView = window?.contentView,
              let close = NSWindow.standardWindowButton(.closeButton, for: [.titled, .closable])
        else { return }
        close.target = window
        close.action = #selector(NSWindow.close)
        contentView.addSubview(close)
        let inset: CGFloat = 12
        let yFromTop: CGFloat = 22 + inset
        let y = contentView.isFlipped
            ? yFromTop
            : contentView.bounds.height - yFromTop - close.frame.height
        close.setFrameOrigin(NSPoint(x: 26 + inset, y: y))
    }
}

@MainActor
private struct MonthlyReportSheet: View {
    // Same live-store treatment as the weekly sheet: kick a rescan on open,
    // re-render when it commits, never freeze a stale launch snapshot.
    @ObservedObject private var cost = CostStore.shared
    @ObservedObject private var tokenMode = TokenCountModeStore.shared
    @ObservedObject private var reportRange = ReportRangeStore.shared
    @State private var copied = false
    @State private var coach: String?
    @State private var shareAnchor: NSView?
    @State private var pickerHolder = MonthlyPickerHolder()

    var body: some View {
        VStack(spacing: 14) {
            MonthlyReportCard(data: .current())
                .shadow(color: .black.opacity(0.30), radius: 10, y: 4)

            ReportRangeBar(kind: .monthly)

            HStack(spacing: 10) {
                pill(copied ? L10n.tr("Copied") : L10n.tr("Copy image")) {
                    if let image = MonthlyReportRenderer.image() {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                        copied = true
                        showCoach(L10n.tr("Copied! Post it and bring a friend to the island 🏝️ Thanks for spreading the word"))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                    }
                }
                pill(L10n.tr("Share…")) {
                    showCoach(L10n.tr("Tip: AirDrop it to your iPhone — it lands in Photos, ready to post 📲"))
                    openSharePicker()
                }
                .background(
                    MonthlyShareAnchorView { shareAnchor = $0 }
                        .frame(width: 1, height: 1)
                )
            }

            Text(coach ?? " ")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(IslandColor.liveTeal)
                .lineLimit(1)
                .opacity(coach == nil ? 0 : 1)
                .animation(.easeOut(duration: 0.2), value: coach == nil)
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 12)
        .onAppear {
            CostStore.shared.refresh()
        }
        .onReceive(cost.objectWillChange) { _ in
            MonthlyReportRenderer.invalidateCache()
            DispatchQueue.main.async { MonthlyReportRenderer.warmCache() }
        }
        .onReceive(tokenMode.objectWillChange) { _ in
            MonthlyReportRenderer.invalidateCache()
            DispatchQueue.main.async { MonthlyReportRenderer.warmCache() }
        }
        .onReceive(reportRange.objectWillChange) { _ in
            MonthlyReportRenderer.invalidateCache()
            DispatchQueue.main.async { MonthlyReportRenderer.warmCache() }
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
        guard let image = MonthlyReportRenderer.image(), let anchor = shareAnchor else { return }
        let picker = NSSharingServicePicker(items: [image])
        pickerHolder.picker = picker
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 16)
                .frame(height: 30)
                .background(Capsule().fill(Color.white))
        }
        .buttonStyle(.plain)
    }
}

private struct MonthlyShareAnchorView: NSViewRepresentable {
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
private final class MonthlyPickerHolder {
    var picker: NSSharingServicePicker?
}
