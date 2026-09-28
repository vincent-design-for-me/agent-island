import SwiftUI
import AppKit

struct GlowLayer: View {
    let isExpanded: Bool
    let hovering: Bool

    @ObservedObject private var usageStore = UsageStore.shared
    @ObservedObject private var costStore = CostStore.shared
    @ObservedObject private var lowPower = LowPowerModeStore.shared
    @ObservedObject private var alerts = AlertEngine.shared
    @ObservedObject private var monitor = ActivityMonitor.shared
    @ObservedObject private var occlusion = WindowOcclusionStore.shared
    @ObservedObject private var visibility = ProviderVisibilityStore.shared
    @ObservedObject private var glowChoice = GlowColorStore.shared
    @State private var stallPulse = false

    var body: some View {
        ZStack {
            // Calm means CLEAN: the sweep is Vivid-only (owner's call,
            // 2026-07-16 — "清爽模式就是没有光效的").
            LoadingSweep(
                active: !occlusion.isOccluded && !lowPower.effectiveEnabled,
                tint: glowColor
            )

            IslandShape()
                .fill(.black)
                .overlay {
                    IslandShape()
                        .strokeBorder(.white.opacity(isExpanded ? 0.12 : 0), lineWidth: 0.5)
                        // Never trace the top edge: the shape sits flush with
                        // the screen top, and a hairline there reads as a
                        // light leak between panel and bezel (design review:
                        // "顶部漏光,上面一条缝"). Mask off the first point.
                        .mask(Rectangle().padding(.top, 1))
                }
                .shadow(
                    color: glowColor.opacity(attentionActive
                        ? (attentionPulsing ? (stallPulse ? 0.85 : 0.35) : 0.55)
                        : (ambientGlowOn ? 0.35 : 0)),
                    radius: attentionActive ? (attentionPulsing ? (stallPulse ? 22 : 14) : 14) : 14,
                    y: 0
                )
                .animation(attentionPulsing
                    ? .easeInOut(duration: 0.42).repeatForever(autoreverses: true)
                    : .easeInOut(duration: 0.25),
                    value: attentionPulsing ? stallPulse : ambientGlowOn)
                .onAppear { stallPulse = true }
                .animation(.easeInOut(duration: 0.45), value: alerts.severity)
                .shadow(color: isExpanded ? .black.opacity(0.5) : .clear, radius: 20, y: 10)
        }
    }

    /// The steady halo. Vivid: always on. Calm: off — a clean pill — except
    /// while an approaching-limit alert wants its amber/red visible (that's
    /// a functional signal, not ambience, so it survives zero-effects mode).
    private var ambientGlowOn: Bool {
        !lowPower.effectiveEnabled || alerts.severity != .none
    }

    private var glowColor: Color {
        if attentionActive { return IslandColor.alertRed }
        switch alerts.severity {
        case .none: return glowChoice.color
        case .warning: return IslandColor.alertAmber
        case .critical: return IslandColor.alertRed
        }
    }

    private var attentionActive: Bool {
        // A provider hidden in Settings never drives the red island glow —
        // ActivityMonitor already skips its usage overlay, and this guard
        // keeps even session-level attention from a switched-off provider
        // out of the whole-island pulse.
        (visibility.claudeVisible && monitor.claude.isAttentionState)
            || (visibility.codexVisible && monitor.codex.isAttentionState)
    }

    /// Attention that should PULSE. authRequired is attention (red, steady
    /// 0.55 glow) but not pulsing — see `State.pulsesAttention`.
    private var attentionPulsing: Bool {
        (visibility.claudeVisible && monitor.claude.pulsesAttention)
            || (visibility.codexVisible && monitor.codex.pulsesAttention)
    }
}

struct LogoOverlay: View {
    let slot: IslandProvider
    /// Left flank (true) or right flank (false) of the notch.
    let leading: Bool
    let edgePadding: CGFloat
    let topPadding: CGFloat

    private var image: NSImage? { slot.logo }
    private var color: Color { slot.color }

    @ObservedObject private var visibility = ProviderVisibilityStore.shared
    @ObservedObject private var monitor = ActivityMonitor.shared
    @State private var pulse = false
    @State private var spinAngle: Double = 0

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .scaleEffect(scale)
                .rotationEffect(.degrees(spinAngle))
                .shadow(color: tint.opacity(pulse ? 0.9 : 0.25), radius: glowRadius)
                .padding(leading ? .leading : .trailing, edgePadding)
                .padding(.top, topPadding)
                .opacity(isVisible ? 1 : 0)
                .animation(.openMorph, value: isVisible)
                .animation(pulseAnimation, value: pulse)
                .animation(.easeInOut(duration: 0.3), value: st)
                .onAppear { pulse = true; updateSpin(st) }
                .onChange(of: st) { newState in
                    pulse = false
                    DispatchQueue.main.async { pulse = true }
                    updateSpin(newState)
                }
                .accessibilityLabel(isVisible ? providerLabel : L10n.tr("%@ (hidden)", providerLabel))
                .accessibilityHidden(!isVisible)
        }
    }

    private static let alarmRed = Color(red: 0.96, green: 0.34, blue: 0.29)

    private var tint: Color {
        switch st {
        case .stalled, .rateLimited, .authRequired: return Self.alarmRed
        case .idle, .working, .needsYou: return color
        }
    }

    private var st: ActivityMonitor.State {
        guard isVisible, let provider = slot.alertProvider else { return .idle }
        return monitor.state(for: provider)
    }

    private var scale: CGFloat {
        switch st {
        // authRequired holds still: a login can stay pending for hours and
        // an endless blink reads as a crash, not a state.
        case .idle, .needsYou, .authRequired: return 1.0
        case .working: return pulse ? 1.05 : 1.0
        case .stalled, .rateLimited: return pulse ? 1.16 : 1.0
        }
    }

    private var glowRadius: CGFloat {
        switch st {
        case .idle, .needsYou: return 0
        case .working: return pulse ? 5 : 2
        case .authRequired: return 4
        case .stalled, .rateLimited: return pulse ? 11 : 4
        }
    }

    private var pulseAnimation: Animation {
        switch st {
        case .idle, .needsYou, .authRequired: return .easeOut(duration: 0.3)
        case .working: return .easeInOut(duration: 1.7).repeatForever(autoreverses: true)
        case .stalled, .rateLimited: return .easeInOut(duration: 0.42).repeatForever(autoreverses: true)
        }
    }

    private var spinDirection: Double { leading ? 1 : -1 }

    private func updateSpin(_ state: ActivityMonitor.State) {
        guard state == .working else {
            withAnimation(.easeOut(duration: 0.35)) { spinAngle = 0 }
            return
        }
        spinAngle = 0
        DispatchQueue.main.async {
            withAnimation(.linear(duration: 3.8).repeatForever(autoreverses: false)) {
                spinAngle = spinDirection * 360
            }
        }
    }

    private var isVisible: Bool {
        guard let provider = slot.alertProvider else { return true }
        return visibility.effectiveVisible(provider: provider)
    }

    private var providerLabel: String {
        slot == .codex ? "OpenAI" : slot.displayName
    }
}

struct PeekPillOverlay: View {
    let slot: IslandProvider
    let slotWidth: CGFloat
    let topPadding: CGFloat
    let pillsVisible: Bool
    /// Which flank the pill occupies. Defaults to the provider's native
    /// side; the solo layout hands the number the OTHER flank so the notch
    /// reads logo-on-one-side, number-on-the-other (owner's call,
    /// 2026-07-16) instead of both crowding one end.
    var onTrailingFlank: Bool

    init(
        slot: IslandProvider,
        slotWidth: CGFloat,
        topPadding: CGFloat,
        pillsVisible: Bool,
        onTrailingFlank: Bool
    ) {
        self.slot = slot
        self.slotWidth = slotWidth
        self.topPadding = topPadding
        self.pillsVisible = pillsVisible
        self.onTrailingFlank = onTrailingFlank
    }

    @ObservedObject private var visibility = ProviderVisibilityStore.shared
    @ObservedObject private var usageStore = UsageStore.shared
    @ObservedObject private var extras = ExtraUsageStore.shared
    @ObservedObject private var alerts = AlertEngine.shared

    var body: some View {
        let window = currentWindow
        NotchPeekPill(
            usage: window,
            loading: usageStore.loading,
            tint: tint,
            alignment: onTrailingFlank ? .trailing : .leading,
            severity: severity
        )
        .frame(width: pillContentWidth, alignment: onTrailingFlank ? .trailing : .leading)
        // 14pt from the silhouette BODY edge; the frame is topCurl wider
        // per side (flare region), which holds no body to align against.
        .padding(onTrailingFlank ? .trailing : .leading, 14 + IslandShape.topCurl)
        .padding(.top, topPadding)
        .opacity((pillsVisible && isVisible) ? 1 : 0)
        .animation(.openMorph, value: isVisible)
        .offset(x: pillsVisible ? 0 : (onTrailingFlank ? 6 : -6))
        .allowsHitTesting(false)
        .accessibilityLabel(peekLabel(for: window, provider: providerLabel))
        .accessibilityHidden(!(pillsVisible && isVisible))
    }

    private var isVisible: Bool {
        guard let provider = slot.alertProvider else { return true }
        return visibility.effectiveVisible(provider: provider)
    }

    private var pillContentWidth: CGFloat {
        max(0, slotWidth - 14)
    }

    private var currentWindow: WindowUsage {
        switch slot {
        case .claude: return usageStore.claude.fiveHour
        case .codex: return usageStore.codex.fiveHour
        case .cursor, .grok:
            return slot.extra.flatMap { extras.usage[$0]?.fiveHour } ?? .unknown
        }
    }

    private var severity: AlertEngine.Severity {
        switch slot {
        case .claude: return alerts.claudeSeverity
        case .codex: return alerts.codexSeverity
        case .cursor, .grok: return .none
        }
    }

    private var tint: Color { slot.color }

    private var providerLabel: String { slot.displayName }

    private func peekLabel(for window: WindowUsage, provider: String) -> String {
        // Codex's tracked window is weekly since July 2026; speak the window
        // the provider actually has instead of a hardcoded "5-hour".
        let weekly = window.isLongPeriod
        if window.error != nil && window.usedPercent == 0 {
            return L10n.tr(weekly ? "%@: no data for weekly window"
                                  : "%@: no data for 5-hour window", provider)
        }
        let pct = window.percentInt
        guard let resetAt = window.resetAt else {
            return L10n.tr(weekly ? "%@: %d percent of weekly window used"
                                  : "%@: %d percent of 5-hour window used", provider, pct)
        }
        let remaining = max(0, resetAt.timeIntervalSinceNow)
        let resetPhrase: String
        if remaining >= 2 * 86400 {
            resetPhrase = L10n.tr("resets in %d days", Int((remaining / 86400).rounded(.down)))
        } else if remaining >= 3600 {
            resetPhrase = L10n.tr("resets in %d hours", Int((remaining / 3600).rounded(.down)))
        } else {
            resetPhrase = L10n.tr("resets in %d minutes", max(1, Int((remaining / 60).rounded(.down))))
        }
        return L10n.tr(weekly ? "%@: %d percent of weekly window used, %@"
                              : "%@: %d percent of 5-hour window used, %@", provider, pct, resetPhrase)
    }
}

struct LoadingSweep: View {
    let active: Bool
    let tint: Color

    var body: some View {
        if active {
            // The sweep's geometry never changes — only its rotation. The old
            // build re-shaded the conic `AngularGradient(angle:)` on the CPU
            // every frame (a 30Hz TimelineView), which drove
            // `rgba64_shade_conic_RGB` in CoreGraphics on the main thread and
            // was the app's dominant idle-CPU cost. Here the conic field is
            // shaded ONCE (fixed angle) and spun by a GPU rotation transform,
            // masked to the fixed island stroke so the outline stays put while
            // the highlight travels around it — visually identical, but the
            // shading no longer repeats per frame. The field is sized to the
            // island's bounding circle so the rotated layer always covers the
            // stroke it's masked to.
            GeometryReader { geo in
                let side = max(geo.size.width, geo.size.height) * 2.2
                Rectangle()
                    .fill(
                        AngularGradient(
                            gradient: Gradient(stops: [
                                .init(color: .clear, location: 0.00),
                                .init(color: tint.opacity(0.0), location: 0.55),
                                .init(color: tint, location: 0.78),
                                .init(color: .white.opacity(0.95), location: 0.92),
                                .init(color: tint.opacity(0.0), location: 1.00),
                            ]),
                            center: .center,
                            angle: .degrees(0)
                        )
                    )
                    .frame(width: side, height: side)
                    .rotationEffect(.degrees(rotation))
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .mask {
                IslandShape()
                    .stroke(lineWidth: 4)
                    .blur(radius: 3)
            }
            .onAppear {
                rotation = 0
                withAnimation(.linear(duration: 3.6).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
            .onDisappear { rotation = 0 }
        }
    }

    @State private var rotation: Double = 0
}
