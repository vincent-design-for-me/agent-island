import SwiftUI

/// Compact quota rows for the quota-only providers, under the Claude/Codex
/// tiles: logo, name, plan, one bar, percent, reset or error, and an
/// optional secondary figure on the right.
struct ExtraUsageRows: View {
    @ObservedObject private var store = ExtraUsageStore.shared
    @ObservedObject private var quotaMode = QuotaDisplayModeStore.shared

    static let rowHeight: CGFloat = 24

    var body: some View {
        VStack(spacing: 2) {
            ForEach(store.shown) { provider in
                row(provider, usage: store.usage[provider] ?? .empty)
            }
        }
    }

    private func row(_ provider: ExtraProvider, usage: AppUsage) -> some View {
        let window = usage.fiveHour
        let value = quotaMode.displayValue(usedPercent: window.usedPercent)
        return HStack(spacing: 8) {
            if let logo = provider.logo {
                Image(nsImage: logo)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                    .foregroundStyle(provider.color)
            }
            Text(provider.displayName)
                .font(Typography.providerTitle)
                .foregroundStyle(.white.opacity(0.92))
            if let plan = usage.plan {
                Text(plan.uppercased())
                    .font(Typography.chip)
                    .foregroundStyle(.white.opacity(0.5))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(provider.color.opacity(0.85))
                        .frame(width: geo.size.width * min(1, max(0, value / 100)))
                }
            }
            .frame(width: 150, height: 5)
            Text("\(Int(value.rounded()))%")
                .font(Typography.bodyNumber)
                .foregroundStyle(.white.opacity(0.9))
                .frame(minWidth: 32, alignment: .trailing)
            Text(caption(window))
                .font(Typography.caption)
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let detail = usage.detail {
                Text(detail)
                    .font(Typography.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .frame(height: Self.rowHeight)
    }

    private func caption(_ window: WindowUsage) -> String {
        if let error = window.error, error != "no data" { return error }
        guard let reset = window.resetAt else { return "" }
        return L10n.tr("resets in %@", Duration.compact(max(0, reset.timeIntervalSinceNow)))
    }
}
