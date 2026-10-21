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
        p.outfit = .forLevel(ledger.level)
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
                    .background(Capsule().fill(Color.white))
                    .contentTransition(.numericText())
            }

            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.surface3)
                        Capsule().fill(Color.white)
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
                if ledger.streak >= 2 { fact("flame", "\(ledger.streak) day streak") }
                if ledger.lifetime.tasks > 0 {
                    fact("shippingbox", "\(ledger.lifetime.tasks.formatted()) task\(ledger.lifetime.tasks == 1 ? "" : "s") shipped all time")
                }
                fact("gift", unlockLine)
            }

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

    private var unlockLine: String {
        switch ledger.level {
        case 0: return "hatches when a task finishes 🐣"
        case ..<3: return "lvl 3 unlocks a sprout 🌱"
        case ..<6: return "lvl 6 unlocks headphones 🎧"
        case ..<10: return "lvl 10 unlocks the crown 👑"
        default: return "max drip unlocked 👑"
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
        let text = "my AI agents' receipt for today 🧾\(stats) printed by \(ledger.petName), the pet that lives in my notch 🐾\n\ngithub.com/mumbaitrip2022/notchma"
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
