import Foundation

/// Which window the share cards cover. nil means the live default — the
/// last seven days for the weekly card, the current month for the monthly
/// one. Session-only on purpose: reopening the app always lands on "now".
@MainActor
final class ReportRangeStore: ObservableObject {
    static let shared = ReportRangeStore()

    /// First day of a custom seven-day weekly window.
    @Published var weekStart: Date?
    /// Any date inside a custom month for the monthly card.
    @Published var month: Date?

    private init() {
        // Headless-snapshot rigs only: AGENTISLAND_REPORT_WEEK_START / _MONTH
        // take yyyy-MM-dd and pin the card to that window.
        let env = ProcessInfo.processInfo.environment
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        weekStart = env["AGENTISLAND_REPORT_WEEK_START"].flatMap(parser.date(from:))
        month = env["AGENTISLAND_REPORT_MONTH"].flatMap(parser.date(from:))
    }

    /// Earliest day the cached history can cover (the scan looks back to
    /// January 1 of the current year).
    static var earliestDay: Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return cal.date(byAdding: .day, value: -(CostSummary.yearHistoryDays() - 1), to: today) ?? today
    }
}
