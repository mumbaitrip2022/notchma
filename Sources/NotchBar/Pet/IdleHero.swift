import AppKit
import SwiftUI

/// What the open notch shows when nothing needs you: your pet on the printer,
/// and today's receipt feeding out of it.
struct IdleHero: View {
    @ObservedObject var ledger: DayLedger
    @ObservedObject var brain: PetBrain
    let sessionCount: Int
    let sounds: Bool
    var showSessions: () -> Void

    @State private var feedback: String?
    @State private var feedbackWork: DispatchWorkItem?

    private var content: ReceiptContent {
        ReceiptContent.make(day: ledger.today, number: ledger.receiptNumber, petName: ledger.petName,
                            streak: ledger.streak)
    }

    /// The pet as printed on paper and in the shared image: always smiling.
    private var portrait: PetSprite.Pose {
        var p = PetSprite.Pose()
        p.outfit = PetLook.outfit(level: ledger.level, wear: ledger.wearing)
        p.gear = PetLook.gear(level: ledger.level).intersection([.scarf, .boots, .orbit])
        p.egg = ledger.level == 0
        p.eyes = p.egg ? .open(dx: 0) : (ledger.streak >= 7 ? .shades : .happy)
        p.mouth = .smile
        p.blush = !p.egg
        return p
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            stats
            VStack(spacing: 0) {
                PetView(brain: brain, pixel: 3, roams: false, ground: 0)
                    .frame(width: 84, height: 48)
                    .contentShape(Rectangle())
                    .onTapGesture { brain.pet() }
                    .help("Pet \(ledger.petName)")
                let c = content
                ReceiptPrinter(content: c, pose: portrait, animate: c.signature != brain.lastPrinted,
                               sound: sounds) { printing in
                    brain.printing = printing
                    if printing { brain.lastPrinted = c.signature }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .onContinuousHover { phase in
            // The pet keeps an eye on your pointer (it stands centered above the receipt).
            if case let .active(p) = phase {
                let petX: CGFloat = 228 + 8 + (Thermal.width + 18) / 2
                brain.lookAt = p.x < petX - 30 ? -1 : (p.x > petX + 30 ? 1 : 0)
            } else {
                brain.lookAt = nil
            }
        }
        .onAppear {
            ledger.rollIfNeeded()
            brain.stayPut = true
            brain.poke()
        }
        .onDisappear {
            brain.preview = nil
            brain.stayPut = false
            brain.lookAt = nil
            brain.printing = false
        }
    }

    // MARK: left column

    private var stats: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ledger.petName)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(ledger.level == 0 ? "egg" : "lvl \(ledger.level)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(ledger.level >= PetLook.maxLevel
                        ? AnyShapeStyle(LinearGradient(colors: [Color(cgColor: PetSprite.goldColor), Color(red: 1, green: 0.66, blue: 0.3)],
                                                       startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Color.white)))
                    .contentTransition(.numericText())
            }

            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.surface3)
                        Capsule().fill(ledger.level >= 40 ? AnyShapeStyle(LinearGradient(
                                colors: [PetSprite.blushColor, Color(cgColor: PetSprite.goldColor)], startPoint: .leading, endPoint: .trailing))
                            : AnyShapeStyle(Color.white))
                            .frame(width: max(6, g.size.width * ledger.levelProgress))
                    }
                }
                .frame(height: 6)
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: ledger.levelProgress)
                Text(xpLine)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.text3)
            }

            VStack(alignment: .leading, spacing: 6) {
                fact("face.smiling", brain.moodLine)
                let st = ledger.streakInfo
                if st.days >= 2 {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        StreakFlame(days: st.days).frame(width: 14)
                        (Text("\(st.days) day streak").foregroundStyle(Palette.text2)
                         + Text(st.skipReady ? "  ·  1 skip left" : "  ·  skip used").foregroundStyle(Palette.text3))
                            .font(.system(size: 12))
                    }
                    .help("Miss one day a week and the streak keeps going. Gold flame at 30 days.")
                }
                if ledger.lifetime.tasks > 0 {
                    fact("shippingbox", "\(ledger.lifetime.tasks.formatted()) task\(ledger.lifetime.tasks == 1 ? "" : "s") shipped all time")
                }
            }

            if ledger.level > 0 { wardrobe }

            if let feedback {
                Text(feedback)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.success)
                    .transition(.opacity)
            }
            HStack(spacing: 8) {
                Button(action: post) { Label("Post it", systemImage: "paperplane.fill") }
                    .buttonStyle(NBButtonStyle(kind: .primary, compact: true))
                    .help("Copies the receipt image and opens a post on X. Paste it in with ⌘V")
                Button(action: copy) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(NBButtonStyle(kind: .secondary, compact: true))
                    .help("Copy the receipt as an image")
                Button(action: save) { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(NBButtonStyle(kind: .secondary, compact: true))
                    .help("Save the receipt to your Desktop")
            }
            if sessionCount > 0 {
                Button(action: showSessions) {
                    HStack(spacing: 4) {
                        Text(sessionCount == 1 ? "1 session" : "\(sessionCount) sessions")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.text2)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 218, alignment: .leading)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .animation(NotchUI.motion, value: feedback)
    }

    private func fact(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.text3)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var xpLine: String {
        if ledger.level == 0 { return "0 xp. hatches after your first task" }
        let next = DayLedger.xpFor(level: ledger.level + 1)
        return "\(ledger.xp.formatted()) / \(next.formatted()) xp to lvl \(ledger.level + 1)"
    }

    // MARK: wardrobe

    /// Hats to pick from. Hover any of them, even locked ones, to try it on.
    private var wardrobe: some View {
        let level = ledger.level
        let worn = PetLook.outfit(level: level, wear: ledger.wearing)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(PetLook.hats, id: \.self) { hat in
                    let open = hat.unlockLevel <= level
                    Button {
                        guard open else { return }
                        ledger.wearing = hat == .forLevel(level) ? nil : hat
                        brain.preview = nil
                        brain.pet()
                    } label: {
                        HatChip(hat: hat, unlocked: open, selected: open && hat == worn)
                    }
                    .buttonStyle(.plain)
                    .onHover { on in
                        brain.preview = on ? (max(level, hat.unlockLevel), hat) : nil
                    }
                    .help(open ? (hat == .none ? "No hat" : "Wear it") : "Unlocks at lvl \(hat.unlockLevel). Hover to try it on")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "gift")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.text3)
                    .frame(width: 14)
                Text(PetLook.nextLine(level))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text2)
            }
            .contentShape(Rectangle())
            .onHover { on in
                guard let n = PetLook.next(after: level) else { return }
                brain.preview = on ? (n.level, n.outfit ?? PetLook.outfit(level: n.level, wear: ledger.wearing)) : nil
            }
            .help("Hover to preview it")
        }
    }

    // MARK: sharing

    @MainActor private func render() -> NSImage? {
        ReceiptExport.image(ReceiptShareCard(content: content, pose: portrait, petName: ledger.petName, level: ledger.level))
    }

    private func copy() {
        guard let img = render(), ReceiptExport.copy(img) else { return say("couldn't make the image") }
        say("copied. paste it anywhere ✨")
    }

    private func save() {
        guard let img = render(), let url = ReceiptExport.save(img, day: ledger.today.key) else {
            return say("couldn't save it")
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        say("saved to your Desktop")
    }

    private func post() {
        guard let img = render(), ReceiptExport.copy(img) else { return say("couldn't make the image") }
        let d = ledger.today
        var bits: [String] = []
        if d.tasks > 0 { bits.append("\(d.tasks) task\(d.tasks == 1 ? "" : "s")") }
        if d.files.count > 0 { bits.append("\(d.files.count) files") }
        if d.testsPassed > 0 { bits.append("\(d.testsPassed) tests passed") }
        let stats = bits.isEmpty ? "" : " " + bits.joined(separator: ", ") + "."
        let text = "my AI agents' receipt for today 🧾\(stats) printed by \(ledger.petName), the pet that lives in my notch 🐾\n\nmumbaitrip2022.github.io/notchma"
        var c = URLComponents(string: "https://x.com/intent/post")!
        c.queryItems = [URLQueryItem(name: "text", value: text)]
        if let url = c.url { NSWorkspace.shared.open(url) }
        say("image copied. press ⌘V in the post 📸")
    }

    private func say(_ text: String) {
        feedbackWork?.cancel()
        feedback = text
        let w = DispatchWorkItem { feedback = nil }
        feedbackWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }
}

/// Your pet, live, in the notch header. Click it for today's receipt. A scrap of
/// paper sticks out when there's activity you haven't seen printed yet.
struct PetButton: View {
    @ObservedObject var ledger: DayLedger
    @ObservedObject var brain: PetBrain
    let open: () -> Void
    @State private var hover = false
    @Environment(\.displayScale) private var displayScale

    private var fresh: Bool {
        ledger.today.tasks > 0 && !brain.lastPrinted.hasPrefix(ledger.today.signature + ledger.petName)
    }

    var body: some View {
        Button(action: open) {
            ZStack(alignment: .bottom) {
                Circle().fill(hover ? Palette.surface3.opacity(1.4) : Palette.surface3)
                PetView(brain: brain, pixel: displayScale >= 2 ? 1.5 : 1, roams: false, ground: 3)
                    .frame(width: 26, height: 26)
                    .clipShape(Circle())
                if fresh {
                    // The receipt peeking out: new numbers to print.
                    VStack(spacing: 1.5) {
                        ForEach(0..<2, id: \.self) { _ in Rectangle().fill(Thermal.faint).frame(width: 5, height: 1) }
                    }
                    .frame(width: 8, height: 9)
                    .background(Thermal.paper)
                    .clipShape(TornEdge(tooth: 1.5))
                    .offset(x: 9, y: 4)
                    .transition(.scale(scale: 0.3, anchor: .top).combined(with: .opacity))
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
            .scaleEffect(hover ? 1.08 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hover)
            .animation(NotchUI.motion, value: fresh)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0; if $0 { brain.poke() } }
        .help(fresh ? "\(ledger.petName) has a fresh receipt for you" : "Today's receipt from \(ledger.petName)")
    }
}

/// One hat in the wardrobe: the pet wearing it, dimmed with a lock until it's unlocked.
private struct HatChip: View {
    let hat: PetSprite.Outfit
    let unlocked: Bool
    let selected: Bool
    @State private var hover = false

    var body: some View {
        ZStack {
            Circle().fill(hover ? Palette.surface3.opacity(1.5) : Palette.surface3)
            PetCanvas(frame: .init(pose: PetSprite.Pose(eyes: .happy, mouth: .smile, outfit: hat)),
                      pixel: 1.5, ink: .white, roams: false, ground: 0)
                .frame(width: 26, height: 25)
                .opacity(unlocked ? 1 : 0.3)
            if !unlocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Palette.text2)
                    .offset(x: 9, y: 9)
            }
        }
        .frame(width: 27, height: 27)
        .overlay(Circle().strokeBorder(Color.white.opacity(selected ? 0.9 : 0), lineWidth: 1.5))
        .scaleEffect(hover ? 1.1 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hover)
        .onHover { hover = $0 }
    }
}

/// The streak flame: still at first, flickering from 14 days, gold from 30.
struct StreakFlame: View {
    let days: Int

    var body: some View {
        let icon = Image(systemName: days >= 14 ? "flame.fill" : "flame")
            .font(.system(size: 11, weight: .semibold))
        if days >= 14 {
            TimelineView(.periodic(from: .now, by: 0.12)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                icon
                    .foregroundStyle(days >= 30
                        ? AnyShapeStyle(LinearGradient(colors: [Color(red: 1, green: 0.93, blue: 0.6), Color(cgColor: PetSprite.goldColor), Color(red: 1, green: 0.55, blue: 0.2)],
                                                       startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(Color(red: 1, green: 0.55, blue: 0.3)))
                    .scaleEffect(x: 1 + 0.05 * sin(t * 11), y: 1 + 0.09 * sin(t * 7.3), anchor: .bottom)
                    .opacity(0.85 + 0.15 * sin(t * 17))
            }
        } else {
            icon.foregroundStyle(Palette.text3)
        }
    }
}
