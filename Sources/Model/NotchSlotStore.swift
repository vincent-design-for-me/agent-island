import AppKit
import SwiftUI

/// Every provider that can sit on the collapsed notch.
enum IslandProvider: String, CaseIterable, Identifiable {
    case claude, codex, cursor, grok

    var id: String { rawValue }

    /// Claude/Codex carry session activity and usage alerts; the quota-only
    /// providers have neither, so they never spin, pulse or glow.
    var alertProvider: AlertEngine.Provider? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        default: nil
        }
    }

    var extra: ExtraProvider? { ExtraProvider(rawValue: rawValue) }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor, .grok: extra?.displayName ?? rawValue
        }
    }

    var color: Color {
        switch self {
        case .claude: IslandColor.claude
        case .codex: IslandColor.codex
        case .cursor, .grok: extra?.color ?? .white
        }
    }

    var logo: NSImage? {
        switch self {
        case .claude: ProviderLogos.claude
        case .codex: ProviderLogos.openAI
        case .cursor, .grok: extra?.logo
        }
    }

    var isAvailable: Bool { extra?.isDetected ?? true }
}

/// Which providers occupy the collapsed notch — at most two, left then
/// right. Stored under the same key and JSON shape 2.x used, so an existing
/// choice carries over. Until the user picks, the notch follows the
/// Claude/Codex visibility toggles exactly as before.
@MainActor
final class NotchSlotStore: ObservableObject {
    static let shared = NotchSlotStore()
    static let maxSlots = 2

    private static let key = "AgentIsland.enabledProviders.v1"

    @Published private(set) var explicit: [IslandProvider]?
    private let visibility = ProviderVisibilityStore.shared

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            explicit = Array(ids.compactMap(IslandProvider.init(rawValue:)).prefix(Self.maxSlots))
        }
    }

    var slots: [IslandProvider] {
        if let explicit { return explicit.filter(\.isAvailable) }
        var derived: [IslandProvider] = []
        if visibility.claudeShown { derived.append(.claude) }
        if visibility.codexShown { derived.append(.codex) }
        return derived
    }

    /// Adds or removes a provider. Adding past the limit is refused so the
    /// user decides what to drop.
    @discardableResult
    func toggle(_ provider: IslandProvider) -> Bool {
        var next = slots
        if let index = next.firstIndex(of: provider) {
            next.remove(at: index)
        } else {
            guard next.count < Self.maxSlots else { return false }
            next.append(provider)
        }
        explicit = next
        if let data = try? JSONEncoder().encode(next.map(\.rawValue)) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        if provider.extra != nil { ExtraUsageStore.shared.refresh() }
        return true
    }

    /// Logo and number placement. Duo: first slot left, second right. Solo:
    /// logo on the provider's native side (Codex right, the rest left) and
    /// the number crosses to the other flank.
    struct Layout: Equatable {
        var leadingLogo: IslandProvider?
        var trailingLogo: IslandProvider?
        var leadingPill: IslandProvider?
        var trailingPill: IslandProvider?
        var solo: IslandProvider?
    }

    var layout: Layout {
        let current = slots
        switch current.count {
        case 2:
            return Layout(leadingLogo: current[0], trailingLogo: current[1],
                          leadingPill: current[0], trailingPill: current[1], solo: nil)
        case 1 where current[0] == .codex:
            return Layout(leadingLogo: nil, trailingLogo: .codex,
                          leadingPill: .codex, trailingPill: nil, solo: .codex)
        case 1:
            return Layout(leadingLogo: current[0], trailingLogo: nil,
                          leadingPill: nil, trailingPill: current[0], solo: current[0])
        default:
            return Layout()
        }
    }
}
