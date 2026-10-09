import Foundation

/// Append-only per-day, per-model token archive, owned by the app.
///
/// Reports are rebuilt from local session logs on every scan, but Claude Code
/// deletes session files untouched for 30 days by default, so old months
/// silently shrank. The ledger records what each scan saw; when a later scan
/// sees less for a day/model (its log was deleted), the missing tokens come
/// back as synthetic events, so every window — month, week, heatmap, any-date
/// reports — keeps the full history. Token components are stored instead of
/// dollars so a pricing update re-prices the archive too.
///
/// One file per provider, so the parallel Claude and Codex scans never write
/// the same file.
enum UsageLedger {
    struct Entry: Codable, Equatable {
        var input: Int = 0
        var output: Int = 0
        var cacheCreation: Int = 0
        /// Subset of `cacheCreation` written to the 1-hour cache (2x input).
        var cacheCreation1h: Int = 0
        var cacheRead: Int = 0

        var total: Int { input + output + cacheCreation + cacheRead }

        mutating func add(_ event: TokenEvent) {
            input += event.inputTokens
            output += event.outputTokens
            cacheCreation += event.cacheCreationTokens
            cacheCreation1h += event.cacheCreation1hTokens
            cacheRead += event.cacheReadTokens
        }
    }

    /// day ("yyyy-MM-dd", local) → "model|variant" → totals. The variant
    /// keeps what prices a request differently once requests are summed:
    /// fast mode, and a prompt over Haiku 5.5's long-context threshold.
    typealias Days = [String: [String: Entry]]

    private static let version = 2

    private struct File: Codable {
        var version: Int
        var days: Days
    }

    static func key(for event: TokenEvent) -> String {
        let model = Pricing.canonicalModelName(event.model)
        let long = event.longPromptOverride ?? (event.promptTokens > Pricing.haiku55Threshold)
        return "\(model)|\(event.fast ? "fast" : "std")\(long ? "+long" : "")"
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentIsland", isDirectory: true)
    }

    static func url(for provider: TokenEvent.Provider) -> URL {
        directory.appendingPathComponent(provider == .claude ? "ledger-claude.json" : "ledger-codex.json")
    }

    /// Records this scan and returns `events` plus synthetic events for any
    /// day/model the archive knows more about than the logs still do.
    static func reconcile(_ events: [TokenEvent], provider: TokenEvent.Provider) -> [TokenEvent] {
        let fileURL = url(for: provider)
        var archive = load(fileURL)
        let scanned = aggregate(events)
        let (merged, missing) = merge(archive: archive, scanned: scanned)
        if merged != archive {
            archive = merged
            save(archive, to: fileURL)
        }
        return events + syntheticEvents(missing, provider: provider)
    }

    /// Pure merge, unit-tested: each day/model keeps whichever record is
    /// larger; when the archive is larger, the difference is "missing".
    static func merge(archive: Days, scanned: Days) -> (merged: Days, missing: Days) {
        var merged = archive
        var missing: Days = [:]
        for (day, models) in scanned {
            for (model, entry) in models {
                let stored = archive[day]?[model]
                if stored == nil || entry.total >= stored!.total {
                    merged[day, default: [:]][model] = entry
                }
            }
        }
        for (day, models) in archive {
            for (model, stored) in models {
                let seen = scanned[day]?[model] ?? Entry()
                guard stored.total > seen.total else { continue }
                missing[day, default: [:]][model] = Entry(
                    input: max(0, stored.input - seen.input),
                    output: max(0, stored.output - seen.output),
                    cacheCreation: max(0, stored.cacheCreation - seen.cacheCreation),
                    cacheCreation1h: max(0, stored.cacheCreation1h - seen.cacheCreation1h),
                    cacheRead: max(0, stored.cacheRead - seen.cacheRead)
                )
            }
        }
        return (merged, missing)
    }

    static func aggregate(_ events: [TokenEvent]) -> Days {
        var days: Days = [:]
        for event in events where event.model != "<synthetic>" {
            let entryTotal = event.inputTokens + event.outputTokens
                + event.cacheCreationTokens + event.cacheReadTokens
            guard entryTotal > 0 else { continue }
            days[dayKey(event.timestamp), default: [:]][key(for: event), default: Entry()].add(event)
        }
        return days
    }

    private static func syntheticEvents(_ missing: Days, provider: TokenEvent.Provider) -> [TokenEvent] {
        missing.flatMap { day, models -> [TokenEvent] in
            guard let noon = noon(of: day) else { return [] }
            return models.map { key, entry in
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                let variant = parts.count > 1 ? parts[1] : "std"
                return TokenEvent(provider: provider, timestamp: noon, model: parts[0],
                                  inputTokens: entry.input, outputTokens: entry.output,
                                  cacheCreationTokens: entry.cacheCreation, cacheReadTokens: entry.cacheRead,
                                  cacheCreation1hTokens: entry.cacheCreation1h,
                                  fast: variant.hasPrefix("fast"),
                                  longPromptOverride: variant.hasSuffix("+long"))
            }
        }
    }

    // MARK: - Dates

    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    static func dayKey(_ date: Date) -> String { dayFormatter().string(from: date) }

    /// Midday keeps a synthetic event on its own day across DST shifts.
    private static func noon(of day: String) -> Date? {
        dayFormatter().date(from: day).map { $0.addingTimeInterval(12 * 3600) }
    }

    // MARK: - Storage

    private static func load(_ url: URL) -> Days {
        // An older layout is dropped and rebuilt from the logs on this scan;
        // v1 only ever existed on the day v2 shipped, so its logs are intact.
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == version else { return [:] }
        return file.days
    }

    private static func save(_ days: Days, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(File(version: version, days: days)).write(to: url, options: .atomic)
        } catch {
            NSLog("AgentIsland: could not write usage ledger: %@", error.localizedDescription)
        }
    }
}
