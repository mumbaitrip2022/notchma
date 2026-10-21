import SwiftUI

/// Things the views can ask the controller to do.
struct NotchActions {
    var showMenu: () -> Void
    var connect: () -> Void
    var bannerTap: (Banner) -> Void
    var openDiff: (String) -> Void
    var copySummary: (String) -> Void
    var openSettings: () -> Void
}

struct RootView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: NotchUI
    @ObservedObject var prefs: Prefs
    @ObservedObject var trust: TrustPolicy
    @ObservedObject var launcher: Launcher
    @ObservedObject var dictation: Dictation
    let system: SystemMonitor
    let pet: PetBrain
    var actions: NotchActions
    var onSize: (CGSize) -> Void

    enum Mode: Equatable { case compact, banner, voice, expanded }

    private var mode: Mode {
        if ui.expanded { return .expanded }
        if dictation.state != .idle { return .voice }
        if store.banner != nil { return .banner }
        return .compact
    }

    var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }

    // MARK: geometry

    private var topR: CGFloat { mode == .compact ? 6 : 10 }
    private var bottomR: CGFloat {
        switch mode {
        case .compact: return min(14, ui.bandHeight / 2)
        case .banner, .voice: return 24
        case .expanded: return 28
        }
    }

    private var width: CGFloat {
        switch mode {
        case .expanded: return NotchUI.expandedWidth
        case .banner, .voice: return 430
        case .compact:
            let base: CGFloat = ui.hasHardwareNotch ? ui.hardwareNotchWidth : 186
            let wings: CGFloat = ui.hasHardwareNotch ? 112 : 168
            // With a hardware notch the pet needs a little room on each side to walk (and hide behind the camera).
            let petWings: CGFloat = ui.hasHardwareNotch && prefs.showPet ? 88 : 0
            return base + (showsActivity ? wings : petWings) + 2 * topR
        }
    }

    private var showsActivity: Bool {
        guard !ui.forceIdle else { return false }
        return !store.approvals.isEmpty || store.isAnyWorking || store.doneFlash
            || store.sessions.values.contains { $0.status == .waitingForInput }
    }

    /// Active sessions in priority order (approval > working > waiting).
    private var active: [Session] {
        store.sortedSessions.filter {
            switch $0.status {
            case .needsApproval, .thinking, .tool, .waitingForInput: return true
            default: return false
            }
        }
    }

    /// Second activity that splits off into its own bubble, like the iPhone island.
    private var secondary: Session? {
        guard mode == .compact, active.count >= 2 else { return nil }
        return active[1]
    }

    private var bubbleWidth: CGFloat { ui.bandHeight + 12 }
    private let gap: CGFloat = 7

    // MARK: views

    private var island: some View {
        HStack(alignment: .top, spacing: gap) {
            // Mirror spacer keeps the main island centred when the bubble shows.
            Color.clear.frame(width: secondary == nil ? 0 : bubbleWidth, height: 1)
            notch
            if let s = secondary {
                SplitBubble(session: s, height: ui.bandHeight, width: bubbleWidth)
                    .onHover { ui.hovering = $0 }
                    .transition(.scale(scale: 0.2, anchor: .leading).combined(with: .opacity))
            } else {
                Color.clear.frame(width: 0, height: 1)
            }
        }
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { onSize($0) })
        .animation(NotchUI.motion, value: secondary?.id)
    }

    private var notch: some View {
        let shape = NotchShape(topRadius: topR, bottomRadius: bottomR)
        return ZStack(alignment: .top) {
            switch mode {
            case .expanded:
                ExpandedView(store: store, ui: ui, prefs: prefs, trust: trust, launcher: launcher, system: system,
                             pet: pet, actions: actions)
                    .transition(.blurReplace)
            case .banner:
                if let b = store.banner {
                    BannerView(banner: b, receipt: store.session(b.sessionID)?.lastTask,
                               petOutfit: .forLevel(store.ledger.level)) { actions.bannerTap(b) }
                        .padding(.top, ui.hasHardwareNotch ? ui.bandHeight - 6 : 0)
                        .id(b.id)
                        .transition(.blurReplace)
                }
            case .voice:
                VoiceView(dictation: dictation)
                    .padding(.top, ui.hasHardwareNotch ? ui.bandHeight - 6 : 0)
                    .transition(.blurReplace)
            case .compact:
                CollapsedView(store: store, ui: ui, pet: pet, showPet: prefs.showPet, showsActivity: showsActivity)
                    .frame(height: ui.bandHeight)
                    .transition(.blurReplace)
            }
        }
        .padding(.horizontal, topR)
        .frame(width: width, alignment: .top)
        .background(Color.black)
        .clipShape(shape)
        .background(
            shape.fill(Color.black)
                .shadow(color: .black.opacity(mode == .compact ? 0 : 0.5),
                        radius: mode == .expanded ? 30 : 18, y: mode == .expanded ? 14 : 8)
        )
        .contentShape(shape)
        .onHover { ui.hovering = $0 }
        .animation(NotchUI.motion, value: mode)
        .animation(NotchUI.motion, value: width)
    }
}

/// Detached mini-island for the second running agent.
struct SplitBubble: View {
    let session: Session
    let height: CGFloat
    let width: CGFloat

    var body: some View {
        ZStack {
            switch session.status {
            case .needsApproval:
                Image(systemName: "circle.fill").font(.system(size: 8.5))
                    .foregroundStyle(Color.approval)
                    .symbolEffect(.pulse, options: .repeating)
            case .waitingForInput:
                Circle().fill(Color.waiting).frame(width: 8, height: 8)
            default:
                AgentGlyph(agent: session.agent, active: true, size: 13)
            }
        }
        .frame(width: width, height: height)
        .background(NotchShape(topRadius: 5, bottomRadius: height / 2).fill(Color.black))
        .contentShape(Rectangle())
        .help("\(session.projectName) · \(session.statusText)")
    }
}

/// Short alert: turn finished, agent needs you, or stopped.
struct BannerView: View {
    let banner: Banner
    var receipt: TaskReceipt?
    var petOutfit: PetSprite.Outfit = .none
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if banner.kind == .pet {
                PetCanvas(frame: PetBrain.Frame(pose: PetSprite.Pose(eyes: .happy, mouth: .smile, blush: true, outfit: petOutfit)),
                          pixel: 2, ink: .white, roams: false, ground: 1)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surface3))
            } else {
                AgentTile(agent: banner.agent, size: 36)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(banner.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(banner.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
                if banner.kind == .done, let receipt {
                    // Task receipt: time · tokens · API-equivalent cost · lines changed.
                    Text(Fmt.receipt(receipt))
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Palette.text3)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                        .help("Cost is the API-equivalent value; it isn't billed on a Pro/Max plan.")
                }
            }
            Spacer(minLength: 8)
            icon
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder private var icon: some View {
        switch banner.kind {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.black, Color.success)
                .symbolEffect(.bounce, value: banner.id)
        case .waiting:
            Image(systemName: "ellipsis.bubble.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.waiting)
                .symbolEffect(.bounce, value: banner.id)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.black, Color.danger)
        case .pet:
            Image(systemName: "sparkles")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, value: banner.id)
        case .info:
            Image(systemName: "info.circle.fill")
                .font(.system(size: 21))
                .foregroundStyle(.black, Color.white.opacity(0.85))
                .symbolEffect(.bounce, value: banner.id)
        case .draft:
            Image(systemName: "arrow.up.message.fill")
                .font(.system(size: 21))
                .foregroundStyle(Color.success)
                .symbolEffect(.bounce, value: banner.id)
        case .attention:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 21))
                .foregroundStyle(Color.approval)
                .symbolEffect(.bounce, value: banner.id)
        case let .limit(critical):
            Image(systemName: "gauge.with.dots.needle.67percent")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(critical ? Color.danger : Color.approval)
                .symbolEffect(.bounce, value: banner.id)
        }
    }
}

/// Live dictation: level meter + what you've said so far.
struct VoiceView: View {
    @ObservedObject var dictation: Dictation

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surface3)
                LevelBars(level: dictation.level)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(dictation.state == .finishing ? "Finishing…" : "Listening…")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(dictation.text.isEmpty ? "Say your next instruction · ⌃⌥V to finish" : dictation.text)
                    .font(.system(size: 12))
                    .foregroundStyle(dictation.text.isEmpty ? Palette.text3 : Palette.text2)
                    .lineLimit(2)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }
}

/// Five solid bars driven by the mic level (no gradients, cheap to draw).
struct LevelBars: View {
    let level: Float
    private let weights: [Float] = [0.5, 0.8, 1.0, 0.8, 0.5]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<weights.count, id: \.self) { i in
                Capsule()
                    .fill(Color.danger)
                    .frame(width: 3, height: CGFloat(4 + 14 * min(1, level * weights[i])))
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
    }
}
