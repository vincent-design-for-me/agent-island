import SwiftUI

/// The date control under a share card: the weekly card takes any start
/// date (it covers that day plus the next six), the monthly card steps by
/// month. "Latest" drops back to the live default.
struct ReportRangeBar: View {
    enum Kind { case weekly, monthly }

    let kind: Kind
    @ObservedObject private var range = ReportRangeStore.shared

    private var cal: Calendar { Calendar.current }
    private var today: Date { cal.startOfDay(for: Date()) }

    var body: some View {
        HStack(spacing: 8) {
            switch kind {
            case .weekly: weeklyControls
            case .monthly: monthlyControls
            }
            if isCustom {
                Button(L10n.tr("Latest")) {
                    range.weekStart = kind == .weekly ? nil : range.weekStart
                    range.month = kind == .monthly ? nil : range.month
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(IslandColor.liveTeal)
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.75))
        .frame(height: 24)
    }

    private var isCustom: Bool {
        kind == .weekly ? range.weekStart != nil : range.month != nil
    }

    private var weeklyControls: some View {
        let latestStart = cal.date(byAdding: .day, value: -6, to: today) ?? today
        let earliest = min(ReportRangeStore.earliestDay, latestStart)
        return HStack(spacing: 8) {
            Text(L10n.tr("Report start date"))
            DatePicker(
                "",
                selection: Binding(
                    get: { range.weekStart ?? latestStart },
                    set: { range.weekStart = cal.isDate($0, inSameDayAs: latestStart) ? nil : $0 }
                ),
                in: earliest...latestStart,
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var monthlyControls: some View {
        let current = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
        let shown = range.month.flatMap { cal.date(from: cal.dateComponents([.year, .month], from: $0)) } ?? current
        let earliest = cal.date(from: cal.dateComponents([.year, .month], from: ReportRangeStore.earliestDay)) ?? current
        let zh = L10n.locale.identifier.hasPrefix("zh")
        let df = DateFormatter()
        df.locale = zh ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US_POSIX")
        df.dateFormat = zh ? "yyyy年M月" : "MMMM yyyy"
        return HStack(spacing: 10) {
            stepButton("chevron.left", enabled: shown > earliest) { step(shown, by: -1, current: current) }
            Text(df.string(from: shown))
                .frame(minWidth: 90)
            stepButton("chevron.right", enabled: shown < current) { step(shown, by: 1, current: current) }
        }
    }

    private func step(_ shown: Date, by months: Int, current: Date) {
        guard let next = cal.date(byAdding: .month, value: months, to: shown) else { return }
        range.month = next >= current ? nil : next
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
    }
}
