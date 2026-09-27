import Foundation

/// One rate-limit window (e.g. Claude's 5h, Codex's 7d). usedPercent is
/// normalized to 0...1 regardless of what the upstream API returns.
struct WindowUsage: Codable {
    let usedPercent: Double
    let resetAt: Date?
    let error: String?
    /// Window length as reported by the provider (Codex sends
    /// limit_window_seconds; Claude's windows are the documented 5h/7d).
    /// Drives display labels, so when a provider changes its quota model —
    /// Codex replaced its 5-hour window with a single weekly one in July
    /// 2026 — the tile relabels itself instead of lying under a hardcoded
    /// "5h". nil on old cached snapshots; labels fall back to the slot name.
    var periodSeconds: TimeInterval? = nil

    static let unknown = WindowUsage(usedPercent: 0, resetAt: nil, error: "no data")

    var percentInt: Int { Int((usedPercent * 100).rounded()) }

    /// A multi-day window (weekly-style) as opposed to an intra-day one.
    var isLongPeriod: Bool { (periodSeconds ?? 0) >= 2 * 86400 }
}

/// One banked Codex reset: OpenAI's own title ("Full reset") + expiry.
/// From `wham/rate-limit-reset-credits`, available cards only.
struct ResetCard: Codable, Identifiable {
    var id: String
    var title: String
    var expiresAt: Date?
}

struct AppUsage: Codable {
    var fiveHour: WindowUsage
    var weekly: WindowUsage
    /// Provider-reported plan tier — Claude's `subscriptionType` (free/pro/max)
    /// or Codex's `plan_type` (free/plus/pro). nil when unknown.
    var plan: String?
    /// Codex banked rate-limit resets ("reset cards") — the count OpenAI
    /// reports in `rate_limit_reset_credits.available_count`. In the
    /// weekly-only quota era these are the user's escape hatches, so the
    /// panel surfaces the count. nil = provider doesn't report any (Claude,
    /// old caches).
    var resetCards: Int? = nil
    /// Per-card detail (what each card is + when it expires). nil when the
    /// detail fetch failed — the count above still stands on its own.
    var resetCardDetails: [ResetCard]? = nil
    /// One short secondary figure for quota-only providers (Grok's monthly
    /// dollars, Gemini's Flash bucket). nil for Claude/Codex.
    var detail: String? = nil

    init(fiveHour: WindowUsage, weekly: WindowUsage, plan: String? = nil,
         resetCards: Int? = nil, resetCardDetails: [ResetCard]? = nil, detail: String? = nil) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.plan = plan
        self.resetCards = resetCards
        self.resetCardDetails = resetCardDetails
        self.detail = detail
    }

    static let empty = AppUsage(fiveHour: .unknown, weekly: .unknown)

    /// True when the provider reported only ONE window on a healthy fetch —
    /// Codex's July 2026 shape (a single weekly quota, secondary_window
    /// gone). The UI hides the empty tile instead of pinning "no data".
    /// Cold start (both unknown) and fetch failures (both carry the same
    /// error) don't qualify, because the primary slot has an error too.
    var secondaryMissing: Bool { weekly.error == "no data" && fiveHour.error == nil }

    /// Placeholder values shown when a provider is toggled off. Non-zero
    /// so the chart vocabulary stays visible (a 0% ring reads as broken,
    /// a 45% ring reads as "data we're choosing not to surface").
    static let dummy = AppUsage(
        fiveHour: WindowUsage(usedPercent: 0.45, resetAt: nil, error: nil),
        weekly: WindowUsage(usedPercent: 0.28, resetAt: nil, error: nil)
    )
}
