import Foundation

/// Readings and visibility for the quota-only providers. Refreshes ride
/// UsageStore's own poll, so these add no timer of their own. A failed fetch
/// keeps the last good percentages and carries the error, the same way the
/// Claude/Codex tiles degrade.
@MainActor
final class ExtraUsageStore: ObservableObject {
    static let shared = ExtraUsageStore()

    @Published private(set) var usage: [ExtraProvider: AppUsage] = [:]
    @Published private(set) var lastUpdated: [ExtraProvider: Date] = [:]
    @Published var enabled: Set<ExtraProvider> {
        didSet {
            let ids = ExtraProvider.allCases.filter(enabled.contains).map(\.rawValue)
            UserDefaults.standard.set(ids, forKey: Self.enabledKey)
            refresh()
        }
    }

    private static let enabledKey = "AgentIsland.extraProvidersEnabled.v1"
    private static let cacheKey = "AgentIsland.extraUsageCache.v1"
    private var inFlight = false

    private struct Cached: Codable {
        var usage: [String: AppUsage]
        var updated: [String: Date]
    }

    /// Shown in the panel and the settings toggle: enabled AND installed.
    var shown: [ExtraProvider] {
        ExtraProvider.allCases.filter { enabled.contains($0) && $0.isDetected }
    }

    private init() {
        if let ids = UserDefaults.standard.stringArray(forKey: Self.enabledKey) {
            enabled = Set(ids.compactMap(ExtraProvider.init(rawValue:)))
        } else {
            // First run: switch on whatever this machine is already signed in to.
            enabled = Set(ExtraProvider.allCases.filter(\.isDetected))
        }
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(Cached.self, from: data) {
            for (key, value) in cached.usage {
                if let provider = ExtraProvider(rawValue: key) { usage[provider] = value }
            }
            for (key, value) in cached.updated {
                if let provider = ExtraProvider(rawValue: key) { lastUpdated[provider] = value }
            }
        }
    }

    func refresh() {
        guard !AppEnvironment.isDemo, !inFlight else { return }
        let targets = shown
        guard !targets.isEmpty else { return }
        inFlight = true
        Task {
            let results = await withTaskGroup(of: (ExtraProvider, AppUsage).self) { group in
                for provider in targets {
                    group.addTask { (provider, await provider.fetch()) }
                }
                var out: [(ExtraProvider, AppUsage)] = []
                for await result in group { out.append(result) }
                return out
            }
            for (provider, fetched) in results {
                usage[provider] = UsageStore.mergedUsage(existing: usage[provider] ?? .empty, fetched: fetched)
                if fetched.fiveHour.error == nil { lastUpdated[provider] = Date() }
            }
            inFlight = false
            persist()
        }
    }

    private func persist() {
        let cached = Cached(
            usage: Dictionary(uniqueKeysWithValues: usage.map { ($0.key.rawValue, $0.value) }),
            updated: Dictionary(uniqueKeysWithValues: lastUpdated.map { ($0.key.rawValue, $0.value) })
        )
        if let data = try? JSONEncoder().encode(cached) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }
}
