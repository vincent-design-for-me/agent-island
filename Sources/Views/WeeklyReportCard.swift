import SwiftUI
import AppKit
import CoreImage

/// The shareable weekly report — a fixed-size portrait card rendered from
/// LOCAL data only (CostStore's log scan + UsageStore quota). Users copy or
/// save it as a PNG and post it themselves; nothing is ever uploaded, which
/// is what lets this exist at all under the no-telemetry promise.
///
/// v3 (locked 2026-07-17): flat near-black coat — NO gradients (external
/// design review: 底色渐变删掉, and gradients band badly under social-app
/// compression) — app logo joins the wordmark up top, the API-value line
/// rides beside the hero number, the faction duel replaces the bare split
/// bar, models cut to TOP 3, and the rank block closes the card.
struct WeeklyReportData {
    struct ModelShare: Identifiable {
        let id = UUID()
        let name: String
        let tokens: Int       // wire or billable per TokenCountMode
        let dollars: Double   // API value this week
        let percent: Double   // 0...1 of the combined week's dollars
        let isClaude: Bool
        let color: Color
    }

    let rangeText: String
    let totalTokens: Int
    let totalDollars: Double
    let claudeShare: Double   // 0...1 of weekly tokens
    let dailyTokens: [Int]    // oldest → today, exactly 7
    let dayLetters: [String]
    let topModels: [ModelShare]
    let lifetimeText: String
    let tierEmoji: String?
    let tierName: String?

    /// Assembles the last 7 calendar days from CostStore. All local.
    @MainActor
    static func current() -> WeeklyReportData {
        let cost = CostStore.shared
        let cal = Calendar.current
        let mode = TokenCountModeStore.shared.mode
        // Anchor the 7-day window to the freshest SCANNED day, not the wall
        // clock. Right after launch (or during a long first scan) the store
        // can still hold yesterday's snapshot; a wall-clock window then
        // shears against weekByModel — whose window is scan-anchored — and
        // a single model row can exceed the hero total (field report: a
        // 125亿 row on a 114亿 card). Anchoring every series to the
        // snapshot's own day keeps the whole card on one window.
        let today = cal.startOfDay(for: Date())
        let scanAnchor = max(
            cost.claude.dailyTokens.last?.dayStart ?? .distantPast,
            cost.codex.dailyTokens.last?.dayStart ?? .distantPast
        )
        let customStart = ReportRangeStore.shared.weekStart.map { cal.startOfDay(for: $0) }
        let anchor = customStart.flatMap { cal.date(byAdding: .day, value: 6, to: $0) }
            ?? (scanAnchor > .distantPast ? min(scanAnchor, today) : today)
        let days: [Date] = (0..<7).reversed().compactMap {
            cal.date(byAdding: .day, value: -$0, to: anchor)
        }

        func bucketTotal(_ buckets: [DailyTokenBucket], _ day: Date) -> Int {
            guard let b = buckets.first(where: { cal.isDate($0.dayStart, inSameDayAs: day) }) else { return 0 }
            return mode == .all ? b.tokens : b.billableTokens
        }
        let claudeDaily = days.map { bucketTotal(cost.claude.dailyTokens, $0) }
        let codexDaily = days.map { bucketTotal(cost.codex.dailyTokens, $0) }
        let daily = zip(claudeDaily, codexDaily).map(+)

        let claudeWeek = claudeDaily.reduce(0, +)
        let codexWeek = codexDaily.reduce(0, +)
        let total = claudeWeek + codexWeek

        // A custom window rebuilds its rows from the daily history; the
        // default keeps the scan's own week slice.
        var claudeRows = cost.claude.weekByModel
        var codexRows = cost.codex.weekByModel
        if customStart != nil, let first = days.first,
           let end = cal.date(byAdding: .day, value: 1, to: anchor) {
            claudeRows = CostSummary.modelRows(daily: cost.claude.dailyByModel, from: first, to: end)
            codexRows = CostSummary.modelRows(daily: cost.codex.dailyByModel, from: first, to: end)
        }
        let dollars = (claudeRows + codexRows).reduce(0.0) { $0 + $1.dollars }

        let zh = L10n.locale.identifier.hasPrefix("zh")
        let models = Self.rankedModels(
            claudeRows: claudeRows,
            codexRows: codexRows,
            limit: 3,
            mode: mode
        )

        let df = DateFormatter()
        df.locale = zh ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US_POSIX")
        df.dateFormat = zh ? "M月d日" : "MMM d"
        let range = "\(df.string(from: days.first ?? anchor)) – \(df.string(from: anchor))"

        let letters: [String]
        if zh {
            let zhDays = ["日", "一", "二", "三", "四", "五", "六"]
            letters = days.map { zhDays[cal.component(.weekday, from: $0) - 1] }
        } else {
            let letterFmt = DateFormatter()
            letterFmt.locale = Locale(identifier: "en_US_POSIX")
            letterFmt.dateFormat = "EEEEE"
            letters = days.map { letterFmt.string(from: $0) }
        }

        // Lifetime rank — recognition rides the card itself.
        let lifetime = (cost.claude.dailyTokens + cost.codex.dailyTokens)
            .reduce(0) { $0 + $1.tokens }
        let tier = MilestoneLadder.tokenTier(lifetime: lifetime)

        return WeeklyReportData(
            rangeText: range,
            totalTokens: total,
            totalDollars: dollars,
            claudeShare: total > 0 ? Double(claudeWeek) / Double(total) : 0,
            dailyTokens: daily,
            dayLetters: letters,
            topModels: models,
            lifetimeText: WeeklyReportCard.compactString(lifetime, zh: zh),
            tierEmoji: tier?.emoji,
            tierName: tier?.nameKey
        )
    }

    /// Rank models by DOLLARS, not billable tokens: the card's story is
    /// "what my week was worth", and token-ranking buried expensive models.
    /// TOP-N only — no "Others" row; the donut's uncovered arc reads as the
    /// long tail on its own (v3, 2026-07-17). Colors are a RANKED
    /// categorical palette — provider-shaded hues made neighboring segments
    /// indistinguishable (owner, 2026-07-14).
    static func rankedModels(
        claudeRows: [ModelUsageRow],
        codexRows: [ModelUsageRow],
        limit: Int,
        mode: TokenCountMode = .all
    ) -> [ModelShare] {
        let dollarUniverse = max(0.01, (claudeRows + codexRows).reduce(0.0) { $0 + $1.dollars })
        let claude = claudeRows.map {
            ModelShare(name: $0.displayName, tokens: mode == .all ? $0.wireTokens : $0.tokens, dollars: $0.dollars,
                       percent: $0.dollars / dollarUniverse, isClaude: true,
                       color: IslandColor.claude)
        }
        let codex = codexRows.map {
            ModelShare(name: $0.displayName, tokens: mode == .all ? $0.wireTokens : $0.tokens, dollars: $0.dollars,
                       percent: $0.dollars / dollarUniverse, isClaude: false,
                       color: IslandColor.codex)
        }
        let palette: [Color] = [
            Color(red: 90/255, green: 168/255, blue: 240/255),   // blue
            Color(red: 204/255, green: 120/255, blue: 92/255),   // coral
            Color(red: 232/255, green: 194/255, blue: 104/255),  // amber
            Color(red: 91/255, green: 200/255, blue: 175/255),   // teal
            Color(red: 167/255, green: 139/255, blue: 250/255),  // violet
        ]
        return Array((claude + codex)
            .sorted { $0.percent > $1.percent }
            .filter { $0.percent >= 0.005 }
            .prefix(limit))
            .enumerated().map { i, m in
                ModelShare(name: m.name, tokens: m.tokens, dollars: m.dollars,
                           percent: m.percent, isClaude: m.isClaude,
                           color: palette[min(i, palette.count - 1)])
            }
    }
}

struct WeeklyReportCard: View {
    let data: WeeklyReportData
    /// The in-window card is rounded; the EXPORTED card is square-cornered
    /// and full-bleed — social apps flatten transparency to white, so any
    /// rounded transparent corner pastes as ugly white nicks.
    var rounded: Bool = true

    static let size = CGSize(width: 420, height: 560)

    /// v3 base coat — one flat near-black. Deliberately NOT a gradient.
    static let baseCoat = Color(red: 0.051, green: 0.059, blue: 0.075)

    var body: some View {
        ZStack {
            background

            VStack(alignment: .leading, spacing: 0) {
                ReportCardHeader(kind: "WEEKLY", periodText: data.rangeText)
                Spacer(minLength: 14)
                hero
                Spacer(minLength: 12)
                ReportDuel(claudeShare: data.claudeShare)
                Spacer(minLength: 14)
                weekBars
                Spacer(minLength: 14)
                ReportModelTable(models: data.topModels)
                Spacer(minLength: 14)
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
                .fill(Self.baseCoat)
            RoundedRectangle(cornerRadius: rounded ? CardWindow.cornerRadius : 0, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        }
    }

    private var hero: some View {
        let zh = L10n.locale.identifier.hasPrefix("zh")
        let parts = Self.compactParts(data.totalTokens, zh: zh)
        return VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("tokens this week"))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .tracking(0.3)
                .foregroundStyle(.white.opacity(0.5))
            // Money line RIDES the number's baseline (owner, 2026-07-17) —
            // the freed height goes to the duel above the beam.
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
                    Text(L10n.tr("≈ $%@ API value", Self.money(data.totalDollars)))
                        .font(.system(size: 12.5, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(IslandColor.brandTeal)
                }
            }
        }
    }

    private var weekBars: some View {
        let zh = L10n.locale.identifier.hasPrefix("zh")
        let peak = max(data.dailyTokens.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 10) {
            ForEach(Array(data.dailyTokens.enumerated()), id: \.offset) { i, tokens in
                let isPeak = tokens == peak && tokens > 0
                VStack(spacing: 5) {
                    Text(isPeak ? Self.compactString(tokens, zh: zh) : " ")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(IslandColor.brandTeal)
                        .opacity(isPeak ? 1 : 0)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isPeak
                              ? AnyShapeStyle(IslandColor.brandTeal)
                              : AnyShapeStyle(Color.white.opacity(tokens > 0 ? 0.16 : 0.07)))
                        .frame(height: max(5, 58 * CGFloat(tokens) / CGFloat(peak)))
                    Text(data.dayLetters.indices.contains(i) ? data.dayLetters[i] : "")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(isPeak ? IslandColor.brandTeal : .white.opacity(0.32))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 88, alignment: .bottom)
    }

    // MARK: - Formatting

    static func compactString(_ n: Int, zh: Bool) -> String {
        let parts = compactParts(n, zh: zh)
        return parts.0 + parts.1
    }

    /// (value, unit). Chinese counts in 亿/万 — the way the number is
    /// actually said — English in B/M/K.
    static func compactParts(_ n: Int, zh: Bool) -> (String, String) {
        let v = Double(n)
        if zh {
            if v >= 100_000_000 { return (trim(v / 100_000_000), "亿") }
            if v >= 10_000 { return (trim(v / 10_000), "万") }
            return ("\(n)", "")
        }
        switch v {
        case 1_000_000_000...: return (trim(v / 1_000_000_000), "B")
        case 1_000_000...:     return (trim(v / 1_000_000), "M")
        case 1_000...:         return (trim(v / 1_000), "K")
        default:               return ("\(n)", "")
        }
    }

    private static func trim(_ v: Double) -> String {
        // No trailing zeros — "99.5亿", never "99.50亿".
        var s = v >= 100 ? String(format: "%.0f", v) : String(format: "%.2f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    static func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? String(format: "%.0f", v)
    }
}

// MARK: - v3 shared sections (weekly + monthly)

/// App mark + wordmark left, period right — the logo moved up here from the
/// old footer strip (owner, 2026-07-17), so the card closes on the rank.
struct ReportCardHeader: View {
    let kind: String        // "WEEKLY" / "MONTHLY"
    let periodText: String

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            if let icon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
            }
            (Text("GAUGE ")
                .foregroundColor(.white.opacity(0.88))
             + Text(kind)
                .foregroundColor(IslandColor.brandTeal))
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(3.0)
            Spacer()
            Text(periodText)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.42))
        }
    }
}

/// Donut + rows, TOP-N. Every model carries all three numbers (tokens,
/// dollars, share); the donut's uncovered arc is the long tail.
struct ReportModelTable: View {
    let models: [WeeklyReportData.ModelShare]

    var body: some View {
        let zh = L10n.locale.identifier.hasPrefix("zh")
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.07), lineWidth: 13)
                ForEach(segments, id: \.0.id) { row, from, to in
                    Circle()
                        .trim(from: CGFloat(from), to: CGFloat(to))
                        .stroke(row.color, style: StrokeStyle(lineWidth: 13, lineCap: .butt))
                }
            }
            .rotationEffect(.degrees(-90))
            .overlay {
                Text("TOP \(models.count)")
                    .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: 88, height: 88)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(models) { row in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(row.color)
                            .frame(width: 7, height: 7)
                        Text(row.name)
                            .font(.system(size: 11.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(WeeklyReportCard.compactString(row.tokens, zh: zh))
                            .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.5))
                        Text("$\(WeeklyReportCard.money(row.dollars))")
                            .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 0.62).opacity(0.9))
                        Text("\(Int((row.percent * 100).rounded()))%")
                            .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(1)
                            .fixedSize()
                            .frame(minWidth: 30, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// Cumulative (row, from, to) sweep per model, with a hairline gap
    /// between segments so same-hue neighbors stay separable.
    private var segments: [(WeeklyReportData.ModelShare, Double, Double)] {
        var cum = 0.0
        return models.map { row in
            let start = cum
            cum += row.percent
            let gap = row.percent > 0.03 ? 0.006 : 0.0
            return (row, start + gap, max(start + gap, cum - gap))
        }
    }
}
