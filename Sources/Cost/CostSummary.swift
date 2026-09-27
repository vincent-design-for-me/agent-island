import Foundation

/// Pure aggregation for the cost screen — a single pass over a flat
/// `[TokenEvent]` stream that splits it into today / this-month / rolling-5h /
/// rolling-7d windows, per-model breakdowns, and sparkline buckets.
///
/// Lives as a free `enum` so the detached refresh task in `CostStore` can call
/// it off the main actor without touching `@MainActor` state. `now` is
/// injectable so the window boundaries are testable.
enum CostSummary {
    static func summarize(events: [TokenEvent], now: Date = Date()) -> ProviderCost {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let startOfDay = cal.startOfDay(for: now)
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? startOfDay
        let currentHour = cal.dateComponents([.hour], from: now).hour ?? 0
        let currentDay = (cal.dateComponents([.day], from: now).day ?? 1) - 1
        let historyDays = yearHistoryDays(now: now)
        let historyStart = cal.date(
            byAdding: .day,
            value: -(historyDays - 1),
            to: startOfDay
        ) ?? startOfDay
        // 5h rolling window for the per-model breakdown — approximates the
        // live tile (Anthropic's rate-limit window); "last 5h from now" is
        // the practical proxy.
        let recentStart = now.addingTimeInterval(-5 * 3600)
        // The week slice is CALENDAR-aligned (today + 6 days back, from
        // midnight), not rolling 168h: the weekly report card sums these
        // per-model rows against a calendar-day hero total, and a rolling
        // window made the rows overshoot the headline by most of a day.
        let weekStart = cal.date(byAdding: .day, value: -6, to: startOfDay)
            ?? now.addingTimeInterval(-7 * 24 * 3600)

        var todayDollars = 0.0, todayTokens = 0, todayBillable = 0
        var monthDollars = 0.0, monthTokens = 0, monthBillable = 0
        var hourlyBuckets = Array(repeating: 0.0, count: currentHour + 1)
        var dailyBuckets = Array(repeating: 0.0, count: currentDay + 1)
        var historyTokenBuckets = Array(repeating: 0, count: historyDays)
        var historyBillableBuckets = Array(repeating: 0, count: historyDays)
        // Filtered to non-zero token events so handshake/stub rows don't
        // show up as "unpriced" warnings — the user only cares about
        // models that actually moved tokens.
        var todayUnknown: Set<String> = []
        var monthUnknown: Set<String> = []
        // Per-canonical-model billable tokens + dollars within the recent
        // window. Cache reads excluded from `tokens` (they don't pressure
        // the rate-limit counter), included in `dollars` (they cost real
        // money). Two metrics, two consumers: usage-page shows tokens,
        // cost-page shows dollars.
        var recentTokensByModel: [String: Int] = [:]
        var recentWireByModel: [String: Int] = [:]
        var recentDollarsByModel: [String: Double] = [:]
        // Same shape, weekly window. Two windows in one pass costs an
        // extra `>=` per event — cheap relative to JSON parsing upstream.
        var weekTokensByModel: [String: Int] = [:]
        var weekWireByModel: [String: Int] = [:]
        var weekDollarsByModel: [String: Double] = [:]
        // Calendar month-to-date, for the monthly card's TOP-5 table.
        var monthTokensByModel: [String: Int] = [:]
        var monthWireByModel: [String: Int] = [:]
        var monthDollarsByModel: [String: Double] = [:]
        // Per-day, per-model totals over the whole history window, so a
        // report can be rebuilt for any date range without a rescan.
        var dailyModel: [DailyModelKey: DailyModelUsage] = [:]

        // Drop events older than every window's start. Using `min(...)`
        // matters here because the rolling 7-day window straddles month
        // boundaries: on May 3, weekStart is Apr 26, but `monthStart` is
        // May 1, so a `>= monthStart` guard would silently filter out
        // Apr 26–30 from the weekly slice. The 5h slice never had this
        // problem (5h ⊂ today ⊂ month), but adding weekly broke the
        // assumption — keep the broader guard.
        let earliestStart = min(monthStart, weekStart, historyStart)
        for event in events {
            guard event.timestamp >= earliestStart else { continue }
            let cost = Pricing.cost(for: event)
            // Two parallel running totals: `tokens` is the wire-level sum
            // (ccusage parity); `billable` is input + output only, matching
            // Anthropic's claude.ai stats panel which excludes cache tokens.
            // Persisting both lets the Settings toggle flip the displayed
            // figure instantly without re-scanning session logs.
            let billable = event.inputTokens + event.outputTokens
            let tokens = billable + event.cacheCreationTokens + event.cacheReadTokens
            // "<synthetic>" is Claude Code's placeholder for injected banner/
            // error lines, not a model — it must never count as unpriced
            // spend (it once surfaced as a baffling "1 unpriced" warning).
            let isUnpriced = tokens > 0 && event.model != "<synthetic>" && !Pricing.isKnown(event.model)

            if event.timestamp >= historyStart {
                let eventDay = cal.startOfDay(for: event.timestamp)
                let dayOffset = cal.dateComponents([.day], from: historyStart, to: eventDay).day ?? -1
                if historyTokenBuckets.indices.contains(dayOffset) {
                    historyTokenBuckets[dayOffset] += tokens
                    historyBillableBuckets[dayOffset] += billable
                }
                if tokens > 0 || cost > 0 {
                    let key = DailyModelKey(dayStart: eventDay, model: Pricing.canonicalModelName(event.model))
                    var bucket = dailyModel[key]
                        ?? DailyModelUsage(dayStart: eventDay, model: key.model, tokens: 0, wireTokens: 0, dollars: 0)
                    bucket.tokens += billable
                    bucket.wireTokens += tokens
                    bucket.dollars += cost
                    dailyModel[key] = bucket
                }
            }

            // Month aggregation gated separately now that the outer guard
            // is `min(monthStart, weekStart)` (so previous-month events
            // can reach the weekly slice).
            if event.timestamp >= monthStart {
                monthDollars += cost
                monthTokens += tokens
                monthBillable += billable
                let day = (cal.dateComponents([.day], from: event.timestamp).day ?? 1) - 1
                if day < dailyBuckets.count { dailyBuckets[day] += cost }
                if isUnpriced { monthUnknown.insert(event.model) }
                let canon = Pricing.canonicalModelName(event.model)
                if billable > 0 { monthTokensByModel[canon, default: 0] += billable }
                if tokens > 0 { monthWireByModel[canon, default: 0] += tokens }
                if cost > 0 { monthDollarsByModel[canon, default: 0] += cost }
            }

            // Today is a strict subset of month
            if event.timestamp >= startOfDay {
                todayDollars += cost
                todayTokens += tokens
                todayBillable += billable
                let hour = cal.dateComponents([.hour], from: event.timestamp).hour ?? 0
                if hour < hourlyBuckets.count { hourlyBuckets[hour] += cost }
                if isUnpriced { todayUnknown.insert(event.model) }
            }

            // Weekly rolling window slice — superset of recent, subset of
            // month (when month is short). Compute canonical name once and
            // reuse for the 5h slice to avoid double work.
            if event.timestamp >= weekStart {
                let canon = Pricing.canonicalModelName(event.model)
                if billable > 0 {
                    weekTokensByModel[canon, default: 0] += billable
                }
                // Wire tokens accumulate unconditionally — cache-read-only
                // events have zero billable but real traffic.
                if tokens > 0 {
                    weekWireByModel[canon, default: 0] += tokens
                }
                if cost > 0 {
                    weekDollarsByModel[canon, default: 0] += cost
                }

                // 5h rolling window slice — strict subset of weekly.
                if event.timestamp >= recentStart {
                    if billable > 0 {
                        recentTokensByModel[canon, default: 0] += billable
                    }
                    if tokens > 0 {
                        recentWireByModel[canon, default: 0] += tokens
                    }
                    if cost > 0 {
                        recentDollarsByModel[canon, default: 0] += cost
                    }
                }
            }
        }

        let recentRows = modelRows(
            tokensByModel: recentTokensByModel,
            wireByModel: recentWireByModel,
            dollarsByModel: recentDollarsByModel
        )
        let weekRows = modelRows(
            tokensByModel: weekTokensByModel,
            wireByModel: weekWireByModel,
            dollarsByModel: weekDollarsByModel
        )
        let monthRows = modelRows(
            tokensByModel: monthTokensByModel,
            wireByModel: monthWireByModel,
            dollarsByModel: monthDollarsByModel
        )

        return ProviderCost(
            today: CostWindow(
                dollars: todayDollars,
                tokens: todayTokens,
                billableTokens: todayBillable,
                series: runningSum(hourlyBuckets),
                label: "Today",
                error: nil,
                unknownModels: todayUnknown.sorted()
            ),
            month: CostWindow(
                dollars: monthDollars,
                tokens: monthTokens,
                billableTokens: monthBillable,
                series: runningSum(dailyBuckets),
                label: CostBucketing.currentMonthLabel(),
                error: nil,
                unknownModels: monthUnknown.sorted()
            ),
            recentByModel: recentRows,
            weekByModel: weekRows,
            monthByModel: monthRows,
            dailyTokens: dailyTokenBuckets(
                start: historyStart,
                tokens: historyTokenBuckets,
                billableTokens: historyBillableBuckets,
                calendar: cal
            ),
            dailyByModel: dailyModel.values.sorted {
                $0.dayStart != $1.dayStart ? $0.dayStart < $1.dayStart : $0.model < $1.model
            }
        )
    }

    static func yearHistoryDays(now: Date = Date()) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let today = cal.startOfDay(for: now)
        let yearStart = cal.date(from: cal.dateComponents([.year], from: today)) ?? today
        let yearDays = (cal.dateComponents([.day], from: yearStart, to: today).day ?? 0) + 1
        return max(1, yearDays)
    }

    private static func dailyTokenBuckets(
        start: Date,
        tokens: [Int],
        billableTokens: [Int],
        calendar: Calendar
    ) -> [DailyTokenBucket] {
        tokens.indices.map { index in
            let day = calendar.date(byAdding: .day, value: index, to: start) ?? start
            return DailyTokenBucket(
                dayStart: day,
                tokens: tokens[index],
                billableTokens: billableTokens[index]
            )
        }
    }

    /// Per-model rows for an arbitrary calendar range `[start, end)`, rebuilt
    /// from the daily history — the any-date report path.
    static func modelRows(daily: [DailyModelUsage], from start: Date, to end: Date) -> [ModelUsageRow] {
        var tokens: [String: Int] = [:], wire: [String: Int] = [:], dollars: [String: Double] = [:]
        for bucket in daily where bucket.dayStart >= start && bucket.dayStart < end {
            if bucket.tokens > 0 { tokens[bucket.model, default: 0] += bucket.tokens }
            if bucket.wireTokens > 0 { wire[bucket.model, default: 0] += bucket.wireTokens }
            if bucket.dollars > 0 { dollars[bucket.model, default: 0] += bucket.dollars }
        }
        return modelRows(tokensByModel: tokens, wireByModel: wire, dollarsByModel: dollars)
    }

    /// Build sorted `ModelUsageRow`s from the two parallel per-model maps
    /// for a given window. Shared between the 5h and weekly slices so
    /// both stay perfectly consistent in shape, sorting, and percent-share
    /// computation.
    private static func modelRows(
        tokensByModel: [String: Int],
        wireByModel: [String: Int] = [:],
        dollarsByModel: [String: Double]
    ) -> [ModelUsageRow] {
        let totalTokens = tokensByModel.values.reduce(0, +)
        let totalDollars = dollarsByModel.values.reduce(0, +)
        let canonicals = Set(tokensByModel.keys)
            .union(dollarsByModel.keys)
            .union(wireByModel.keys)
        return canonicals.map { canon in
            let tokens = tokensByModel[canon] ?? 0
            let dollars = dollarsByModel[canon] ?? 0
            return ModelUsageRow(
                model: canon,
                displayName: prettyModelName(canon),
                tokens: tokens,
                wireTokens: wireByModel[canon] ?? 0,
                dollars: dollars,
                percent: totalTokens > 0 ? Double(tokens) / Double(totalTokens) : 0,
                dollarPercent: totalDollars > 0 ? dollars / totalDollars : 0
            )
        }
        .sorted {
            // Tokens primary, dollars secondary — handles cache-read-only
            // rows (zero billable tokens, non-zero dollars) by sinking
            // them to the bottom but not disappearing.
            if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
            return $0.dollars > $1.dollars
        }
    }

    /// Pretty-print the canonical model id for UI rows. Falls back to the
    /// raw id if no friendlier name is wired up yet — better than a blank.
    private static func prettyModelName(_ canonical: String) -> String {
        // Anthropic: "claude-opus-4-7" → "Opus 4.7"
        if canonical.hasPrefix("claude-") {
            let trimmed = String(canonical.dropFirst("claude-".count))
            // Split at first dash, then collapse remaining dashes into dots
            // so "opus-4-7" → "opus.4.7" → "Opus 4.7".
            guard let dash = trimmed.firstIndex(of: "-") else {
                return trimmed.capitalized
            }
            let family = String(trimmed[..<dash]).capitalized
            let version = trimmed[trimmed.index(after: dash)...]
                .replacingOccurrences(of: "-", with: ".")
            return "\(family) \(version)"
        }
        // OpenAI: keep as-is, just uppercase the GPT prefix.
        if canonical.hasPrefix("gpt-") {
            return canonical.replacingOccurrences(of: "gpt-", with: "GPT-")
        }
        // OpenAI reasoning family ("o3-pro", "o4-mini-high", etc.) — already
        // short and conventional, capitalize only the leading letter so it
        // matches the typographic weight of "GPT-..." / "Opus 4.7".
        if let first = canonical.first, first == "o", canonical.count > 1,
           canonical.dropFirst().first?.isNumber == true {
            return canonical.prefix(1).uppercased() + canonical.dropFirst()
        }
        return canonical
    }

    private static func runningSum(_ values: [Double]) -> [Double] {
        var out = [Double]()
        out.reserveCapacity(values.count)
        var sum = 0.0
        for v in values { sum += v; out.append(sum) }
        return out
    }
}
