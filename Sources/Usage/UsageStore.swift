import Foundation
import Combine
import Network
import AppKit

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()
    private init() {
        guard !AppEnvironment.isDemo,
              let snapshot = Self.loadCachedSnapshot() else { return }
        claude = snapshot.claude
        codex = snapshot.codex
        lastUpdated = snapshot.updatedAt
    }

    @Published var claude: AppUsage = .empty
    @Published var codex: AppUsage = .empty
    @Published var lastUpdated: Date?
    @Published var refreshWarning: String?
    @Published var loading = false
    /// When the current `loading` window started. A refresh normally clears
    /// `loading` within a couple seconds; if a fetch wedges (e.g. a half-open
    /// VPN tunnel that stays "connected" but never returns data), `loading`
    /// would otherwise stick true forever and every scheduled poll would no-op
    /// on the guard, freezing the panel at "synced N minutes ago". This lets
    /// `refresh()` treat a too-old loading window as wedged and restart it.
    private var loadingStartedAt: Date?
    /// Set while a `claude auth login` flow is in progress (spawned + still
    /// polling for the keychain to update). The UI hides the re-auth button
    /// during this window so users don't double-tap and spawn duplicate CLI
    /// processes; the click ends up no-ops anyway because the spawn check
    /// gates on this.
    @Published var claudeReauthInProgress = false
    @Published var codexReauthInProgress = false
    @Published var codexAccounts: [CodexAccountSwitcher.Account] = CodexAccountSwitcher.accounts()
    @Published var activeCodexAccountLabel: String? = CodexAccountSwitcher.activeAccount()?.label
    @Published var codexAutoSwitch = CodexAccountSwitcher.autoSwitchEnabled {
        didSet { CodexAccountSwitcher.autoSwitchEnabled = codexAutoSwitch }
    }
    /// Labels already tried during the current exhaustion episode, so auto
    /// rotation walks the pool once instead of cycling forever.
    private var codexRotationTried: Set<String> = []

    private var refreshTask: Task<Void, Never>?
    private var reauthPollTask: Task<Void, Never>?
    private var codexReauthPollTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var boundaryTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?
    private var intervalCancellable: AnyCancellable?
    private var netMonitor: NWPathMonitor?
    private let netQueue = DispatchQueue(label: "UsageStore.network")
    private var lastNetStatus: NWPath.Status?
    private static let cacheKey = "UsageStore.lastSuccessfulUsage.v1"
    private static let cacheMaxAge: TimeInterval = 24 * 60 * 60

    /// Anthropic's /api/oauth/usage is aggressively rate-limited per token.
    /// `RefreshIntervalStore` enforces a 5-minute floor (300/900/1800).
    private var pollInterval: TimeInterval {
        TimeInterval(RefreshIntervalStore.shared.seconds)
    }

    /// Refresh on a "user is looking now" moment (opening the panel), but only
    /// when the data is already older than the poll interval. This is the whole
    /// trick to staying fresh without polling faster: it can never make a call
    /// the schedule wouldn't have made anyway, so opening the island ten times
    /// in a row still costs at most one fetch — no extra pressure on the
    /// rate-limited endpoint. Fresh data is fresh; stale data refreshes on open.
    func refreshIfStale() {
        guard let last = lastUpdated else { refresh(); return }
        if Date().timeIntervalSince(last) >= pollInterval { refresh() }
    }

    func refresh() {
        // Skip only if a refresh is genuinely in flight. A `loading` window
        // older than 90s is presumed wedged (a hung fetch that never returned),
        // so fall through and restart instead of no-op'ing forever — otherwise
        // the panel freezes at the last successful sync.
        if loading, let started = loadingStartedAt, Date().timeIntervalSince(started) < 90 { return }
        // Demo mode for screen recordings: skip the network entirely and
        // inject hand-tuned values that read as "real, healthy heavy-user
        // data". Reset times are recomputed each refresh so the countdowns
        // tick down naturally on camera. Off by default — only fires when
        // AGENTISLAND_DEMO=1 is set in the launching env.
        if AppEnvironment.isDemo {
            let now = Date()
            let claudeFiveHour = Self.demoDouble("AGENTISLAND_DEMO_CLAUDE_5H", fallback: 0.73)
            let claudeWeekly = Self.demoDouble("AGENTISLAND_DEMO_CLAUDE_WEEKLY", fallback: 0.81)
            let codexFiveHour = Self.demoDouble("AGENTISLAND_DEMO_CODEX_5H", fallback: 0.67)
            let codexWeekly = Self.demoDouble("AGENTISLAND_DEMO_CODEX_WEEKLY", fallback: 0.76)
            let claudeReset = Self.demoMinutes("AGENTISLAND_DEMO_CLAUDE_RESET_MINUTES", fallback: 107)
            let codexReset = Self.demoMinutes("AGENTISLAND_DEMO_CODEX_RESET_MINUTES", fallback: 143)
            self.claude = AppUsage(
                fiveHour: WindowUsage(
                    usedPercent: claudeFiveHour,
                    resetAt: now.addingTimeInterval(TimeInterval(claudeReset * 60)),
                    error: nil
                ),
                weekly: WindowUsage(
                    usedPercent: claudeWeekly,
                    resetAt: now.addingTimeInterval(4 * 86400 + 11 * 3600),
                    error: nil
                ),
                plan: "max"
            )
            self.codex = AppUsage(
                fiveHour: WindowUsage(
                    usedPercent: codexFiveHour,
                    resetAt: now.addingTimeInterval(TimeInterval(codexReset * 60)),
                    error: nil
                ),
                weekly: WindowUsage(
                    usedPercent: codexWeekly,
                    resetAt: now.addingTimeInterval(4 * 86400 + 18 * 3600),
                    error: nil
                ),
                plan: "pro"
            )
            self.lastUpdated = now
            self.refreshWarning = nil
            return
        }

        loading = true
        loadingStartedAt = Date()
        refreshTask?.cancel()
        refreshTask = Task {
            async let codexResult = UsageFetcher.fetchCodex()
            async let claudeResult = UsageFetcher.fetchClaude()
            let c = await codexResult
            let cl = await claudeResult

            // Cancellation = network monitor saw the path come up while we
            // were mid-flight on a dead one. The fetched values are the
            // dead-path errors — drop them so the supersedes refresh
            // doesn't have a brief "cancelled" caption flash to overwrite.
            if Task.isCancelled {
                self.loading = false
                return
            }

            // Don't clobber existing good values when a fetch returns an
            // all-error result. A transient 429 shouldn't blank the panel
            // back to "0%" — that's worse than slightly stale data. Preserve
            // the last useful percentages, but carry the new error forward so
            // the UI admits the values are stale instead of showing a fake
            // fresh reset countdown. But if
            // the existing value is itself error-only (cold start sitting
            // on `.empty`, or a series of failures), let the new error
            // through — otherwise a single bad first fetch sticks "no data"
            // permanently even after the network recovers.
            let codexFailed = UsageStore.isErrorOnly(c)
            let claudeFailed = UsageStore.isErrorOnly(cl)

            let mergedCodex = UsageStore.mergedUsage(existing: self.codex, fetched: c)
            let mergedClaude = UsageStore.mergedUsage(existing: self.claude, fetched: cl)
            self.codex = mergedCodex
            self.claude = mergedClaude
            UsageStore.saveCachedSnapshot(claude: mergedClaude, codex: mergedCodex)
            if !codexFailed { self.rotateCodexIfExhausted(mergedCodex) }
            self.refreshWarning = UsageStore.refreshWarning(codexFailed: codexFailed, claudeFailed: claudeFailed)
            self.lastUpdated = Date()
            self.loading = false
            self.scheduleBoundaryRefresh()
        }
        ExtraUsageStore.shared.refresh()
    }

    /// The 5-minute poll floor means a window can sit visibly expired — and,
    /// worse, an afterReset auto-resume never fires — for up to 5 minutes
    /// after it actually rolls over. Schedule one extra targeted fetch a few
    /// seconds past the soonest upcoming reset so the moment a window flips we
    /// pull fresh data: the countdown updates AND the changed resetAt drives
    /// the trigger engine. One-shot per reset, so it doesn't add to the poll
    /// rate the endpoint is sensitive to.
    private func scheduleBoundaryRefresh() {
        boundaryTimer?.invalidate()
        boundaryTimer = nil
        let now = Date()
        let resets = [
            claude.fiveHour.resetAt, claude.weekly.resetAt,
            codex.fiveHour.resetAt, codex.weekly.resetAt,
        ].compactMap { $0 }.filter { $0 > now }
        guard let soonest = resets.min() else { return }
        // +8s cushion so the provider has flipped the window before we ask;
        // clamp the far end so a week-away weekly reset doesn't hold a timer
        // for days (the regular poll covers the long tail).
        let delay = min(soonest.timeIntervalSince(now) + 8, 6 * 3600)
        boundaryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
    }

    private static func demoDouble(_ key: String, fallback: Double) -> Double {
        guard let raw = ProcessInfo.processInfo.environment[key],
              let value = Double(raw) else { return fallback }
        return min(1, max(0, value))
    }

    private static func demoMinutes(_ key: String, fallback: Int) -> Int {
        guard let raw = ProcessInfo.processInfo.environment[key],
              let value = Int(raw) else { return fallback }
        return max(1, value)
    }

    /// True when both windows have errors and zero values — nothing useful
    /// to show, so we keep whatever we had before.
    private static func isErrorOnly(_ u: AppUsage) -> Bool {
        u.fiveHour.error != nil && u.weekly.error != nil
            && u.fiveHour.usedPercent == 0 && u.weekly.usedPercent == 0
    }

    static func mergedUsage(existing: AppUsage, fetched: AppUsage) -> AppUsage {
        guard isErrorOnly(fetched), !isErrorOnly(existing) else { return fetched }
        let error = fetched.fiveHour.error ?? fetched.weekly.error
        return AppUsage(
            fiveHour: WindowUsage(
                usedPercent: existing.fiveHour.usedPercent,
                resetAt: existing.fiveHour.resetAt,
                error: error,
                periodSeconds: existing.fiveHour.periodSeconds
            ),
            weekly: WindowUsage(
                usedPercent: existing.weekly.usedPercent,
                resetAt: existing.weekly.resetAt,
                error: error,
                periodSeconds: existing.weekly.periodSeconds
            ),
            plan: existing.plan,
            resetCards: existing.resetCards,
            resetCardDetails: existing.resetCardDetails,
            detail: existing.detail
        )
    }

    private static func refreshWarning(codexFailed: Bool, claudeFailed: Bool) -> String? {
        switch (claudeFailed, codexFailed) {
        case (true, true): return L10n.tr("Usage refresh failed")
        case (true, false): return L10n.tr("Claude stale")
        case (false, true): return L10n.tr("Codex stale")
        case (false, false): return nil
        }
    }

    private static func loadCachedSnapshot() -> UsageCacheSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let snapshot = try? JSONDecoder().decode(UsageCacheSnapshot.self, from: data) else {
            return nil
        }
        return UsageCachePolicy.restoredSnapshot(snapshot, now: Date(), maxAge: cacheMaxAge)
    }

    private static func saveCachedSnapshot(claude: AppUsage,
                                           codex: AppUsage,
                                           fetchedClaude: Bool = true,
                                           fetchedCodex: Bool = true) {
        let existing = loadCachedSnapshot()
        guard let snapshot = UsageCachePolicy.snapshotForSave(
            claude: claude,
            codex: codex,
            existing: existing,
            now: Date(),
            fetchedClaude: fetchedClaude,
            fetchedCodex: fetchedCodex
        ), let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    /// Replace current usage values with hand-tuned percentages so the
    /// alert engine's pulse + tint behavior can be exercised without
    /// waiting for a real provider crossing. Auto-refresh continues — the
    /// next scheduled poll will overwrite these values with real data.
    /// Each call uses fresh `resetAt` timestamps so the alert engine
    /// treats it as a new reset window and re-evaluates crossings.
    func injectPreviewUsage(claudeFiveHour: Double, codexFiveHour: Double) {
        let now = Date()
        let fiveHourReset = now.addingTimeInterval(2 * 3600 + 14 * 60)
        let weeklyReset = now.addingTimeInterval(4 * 86400 + 6 * 3600)
        self.claude = AppUsage(
            fiveHour: WindowUsage(
                usedPercent: claudeFiveHour,
                resetAt: fiveHourReset,
                error: nil
            ),
            weekly: WindowUsage(
                usedPercent: 0.45,
                resetAt: weeklyReset,
                error: nil
            ),
            plan: claude.plan ?? "max"
        )
        self.codex = AppUsage(
            fiveHour: WindowUsage(
                usedPercent: codexFiveHour,
                resetAt: fiveHourReset,
                error: nil
            ),
            weekly: WindowUsage(
                usedPercent: 0.30,
                resetAt: weeklyReset,
                error: nil
            ),
            plan: codex.plan ?? "pro"
        )
        self.lastUpdated = now
        self.refreshWarning = nil
    }

    /// Re-authenticate Claude via the in-app browser login.
    ///
    /// Preferred path (`ClaudeWebLogin`): opens the real Claude authorize page
    /// in the default browser — reusing the user's claude.ai session, usually a
    /// single click — and catches the OAuth redirect on a local loopback
    /// listener, writing the fresh, fully-scoped token pair straight to the
    /// keychain. No Terminal, no manual code paste. On any failure we fall back
    /// to the legacy `claude auth login` + keychain-poll so a machine that can't
    /// run the loopback flow is no worse off than before.
    enum ClaudeSignInMode {
        /// Open the authorize page in the chosen browser, catch the redirect locally.
        case browser
        /// Same loopback flow, but the link goes to the clipboard.
        case copyLink
        /// Paste the `code#state` the page shows — no local listener needed.
        case code
    }

    /// Which sign-in is in flight, so the button can say "link copied".
    @Published var claudeSignInMode: ClaudeSignInMode?

    func reauthenticateClaude(_ mode: ClaudeSignInMode = .browser) {
        guard !claudeReauthInProgress else { return }
        claudeReauthInProgress = true
        claudeSignInMode = mode
        reauthPollTask?.cancel()
        reauthPollTask = Task { [weak self] in
            guard let self else { return }
            let outcome: ClaudeWebLogin.Outcome
            switch mode {
            case .browser: outcome = await ClaudeWebLogin.shared.start()
            case .copyLink: outcome = await ClaudeWebLogin.shared.start(delivery: .copyLink)
            case .code: outcome = await ClaudeWebLogin.shared.startWithCode()
            }
            switch outcome {
            case .success:
                await self.finishClaudeReauthWithSingleFetch()
            case .failed where mode == .browser:
                await self.runClaudeCLIReauthFallback()
            case .canceled, .failed:
                await MainActor.run { self.claudeReauthInProgress = false }
            }
            await MainActor.run { self.claudeSignInMode = nil }
        }
    }

    /// Abandons a loopback sign-in the user walked away from (e.g. a copied
    /// link never opened), so another method can start right away.
    func cancelClaudeSignIn() {
        ClaudeWebLogin.shared.cancel()
    }

    /// Legacy fallback: spawn `claude auth login` in Terminal and poll the
    /// keychain metadata for a change, then hit the usage API once. Kept only
    /// as a safety net for setups where the loopback listener can't bind.
    private func runClaudeCLIReauthFallback() async {
        let initialStamp = ClaudeCredentials.keychainModificationStamp()
        guard ClaudeCredentials.spawnReauth() else {
            await MainActor.run { self.claudeReauthInProgress = false }
            return
        }
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            let currentStamp = ClaudeCredentials.keychainModificationStamp()
            guard currentStamp != nil, currentStamp != initialStamp else { continue }
            await finishClaudeReauthWithSingleFetch()
            return
        }
        await finishClaudeReauthWithSingleFetch()
    }

    // MARK: - Codex accounts

    func reloadCodexAccounts() {
        codexAccounts = CodexAccountSwitcher.accounts()
        activeCodexAccountLabel = CodexAccountSwitcher.activeAccount()?.label
    }

    func saveCurrentCodexAccount(label: String) {
        CodexAccountSwitcher.parkCurrent(label: label)
        reloadCodexAccounts()
    }

    func switchCodexAccount(_ account: CodexAccountSwitcher.Account) {
        guard CodexAccountSwitcher.activate(account) else { return }
        codexRotationTried.removeAll()
        reloadCodexAccounts()
        Task { await finishCodexReauthWithSingleFetch() }
    }

    func forgetCodexAccount(_ account: CodexAccountSwitcher.Account) {
        CodexAccountSwitcher.forget(account)
        reloadCodexAccounts()
    }

    /// Opt-in: when the live account's window reads 100%, move to the next
    /// parked account. Keyed off the real /wham/usage percentages rather than
    /// CLI failure text, so it never guesses.
    private func rotateCodexIfExhausted(_ usage: AppUsage) {
        guard codexAutoSwitch else { return }
        let exhausted = [usage.fiveHour, usage.weekly].contains { $0.error == nil && $0.usedPercent >= 1 }
        guard exhausted else {
            codexRotationTried.removeAll()
            return
        }
        if let active = CodexAccountSwitcher.activeAccount()?.label { codexRotationTried.insert(active) }
        guard let next = CodexAccountSwitcher.rotationCandidate(tried: codexRotationTried) else { return }
        codexRotationTried.insert(next.label)
        guard CodexAccountSwitcher.activate(next) else { return }
        reloadCodexAccounts()
        Task { await finishCodexReauthWithSingleFetch() }
    }

    func reauthenticateCodex() {
        guard !codexReauthInProgress else { return }
        let initialStamp = CodexCredentials.authModificationStamp()
        guard CodexCredentials.spawnReauth() else { return }
        codexReauthInProgress = true
        codexReauthPollTask?.cancel()
        codexReauthPollTask = Task { [weak self, initialStamp] in
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                let currentStamp = CodexCredentials.authModificationStamp()
                guard currentStamp != nil, currentStamp != initialStamp else {
                    continue
                }
                await self?.finishCodexReauthWithSingleFetch()
                return
            }
            await self?.finishCodexReauthWithSingleFetch()
        }
    }

    private func finishCodexReauthWithSingleFetch() async {
        let c = await UsageFetcher.fetchCodex()
        await MainActor.run {
            let mergedCodex = UsageStore.mergedUsage(existing: self.codex, fetched: c)
            self.codex = mergedCodex
            UsageStore.saveCachedSnapshot(
                claude: self.claude,
                codex: mergedCodex,
                fetchedClaude: false,
                fetchedCodex: true
            )
            self.refreshWarning = UsageStore.isErrorOnly(c) ? L10n.tr("Codex stale") : nil
            if !UsageStore.isErrorOnly(c) {
                self.lastUpdated = Date()
            }
            self.codexReauthInProgress = false
            self.reloadCodexAccounts()
        }
    }

    private func finishClaudeReauthWithSingleFetch() async {
        let cl = await UsageFetcher.fetchClaude()
        await MainActor.run {
            let mergedClaude = UsageStore.mergedUsage(existing: self.claude, fetched: cl)
            self.claude = mergedClaude
            UsageStore.saveCachedSnapshot(
                claude: mergedClaude,
                codex: self.codex,
                fetchedClaude: true,
                fetchedCodex: false
            )
            self.refreshWarning = UsageStore.isErrorOnly(cl) ? L10n.tr("Claude stale") : nil
            if !UsageStore.isErrorOnly(cl) {
                self.lastUpdated = Date()
            }
            self.claudeReauthInProgress = false
        }
    }

    func startAutoRefresh() {
        stopAutoRefresh()
        refresh()
        armTimer()
        // Re-arm whenever the user changes the refresh interval. We
        // dropFirst() the initial @Published replay so we don't re-fire
        // refresh() on subscription.
        intervalCancellable = RefreshIntervalStore.shared.$seconds
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.armTimer() }
            }
        startNetworkMonitor()
        startWakeMonitor()
    }

    /// Macs sleep overnight — exactly when a quota window resets and an
    /// overnight run wants to auto-continue. A sleeping Mac's timers don't
    /// fire, so on wake the panel would sit on pre-sleep data (an expired
    /// countdown, the stale exhausted state) until the next poll, and the
    /// afterReset trigger would miss its window. Refresh immediately on wake
    /// so both recover the instant the machine is back.
    private func startWakeMonitor() {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
        // Locked but not slept: even with App Nap disabled the scheduled poll
        // may be up to `pollInterval` away when the screen unlocks. Refresh the
        // instant it unlocks so a reset that landed during the lock is picked
        // up (and its afterReset trigger caught up) without waiting.
        if let unlockObserver { DistributedNotificationCenter.default().removeObserver(unlockObserver) }
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
    }

    func stopAutoRefresh() {
        pollTimer?.invalidate()
        pollTimer = nil
        boundaryTimer?.invalidate()
        boundaryTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let unlockObserver {
            DistributedNotificationCenter.default().removeObserver(unlockObserver)
            self.unlockObserver = nil
        }
        intervalCancellable?.cancel()
        intervalCancellable = nil
        netMonitor?.cancel()
        netMonitor = nil
        lastNetStatus = nil
    }

    private func armTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
    }

    /// Trigger an immediate refresh whenever the network transitions from
    /// unsatisfied to satisfied — closes the launch-at-login race where
    /// Wi-Fi is still associating when our first refresh fires. Without
    /// this, the panel sits at the empty cold-start state until the next
    /// scheduled poll (5–30 minutes away). The initial path callback fires
    /// with the current state and is deliberately ignored (lastNetStatus
    /// starts nil) — startAutoRefresh's own refresh() already covers
    /// cold-start, and acting on the initial callback would double-fire.
    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let was = self.lastNetStatus
                self.lastNetStatus = path.status
                guard path.status == .satisfied,
                      let prior = was, prior != .satisfied else { return }
                // Cancel any in-flight refresh — its URLSession call was
                // started on the dead path and is going to return an
                // error. Wait for it to finalize so its loading=false
                // lands before we start the replacement, otherwise our
                // refresh() hits the `if loading { return }` guard.
                self.refreshTask?.cancel()
                await self.refreshTask?.value
                self.refresh()
            }
        }
        monitor.start(queue: netQueue)
        netMonitor = monitor
    }
}
