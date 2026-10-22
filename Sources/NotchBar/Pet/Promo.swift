#if DEBUG
import AppKit
import SwiftUI

/// README and social images, rendered offscreen with sample numbers (debug builds only).
enum Promo {
    static let backdrop = Color(red: 0.925, green: 0.910, blue: 0.885)

    static func sampleDay() -> DayLedger.Day {
        var d = DayLedger.Day(key: DayLedger.dayKey(Date()))
        let now = Date()
        func t(_ a: Agent, _ p: String, _ m: Double, _ tok: Int, _ c: Double, _ add: Int, _ rem: Int) -> DayLedger.Turn {
            .init(key: UUID().uuidString, agent: a.rawValue, project: p, duration: m * 60, tokens: tok, cost: c,
                  added: add, removed: rem, endedAt: now)
        }
        d.turns = [t(.claude, "checkout", 74, 1_100_000, 2.40, 690, 140), t(.claude, "checkout", 38, 520_000, 1.10, 310, 96),
                   t(.codex, "api", 31, 410_000, 0.80, 160, 52), t(.cursor, "landing", 22, 0, 0, 120, 30)]
        d.files = Set((0..<41).map { "f\($0)" })
        d.commands = 93; d.testsPassed = 148; d.allowed = 23; d.denied = 2; d.autoAllowed = 11
        return d
    }

    static var content: ReceiptContent {
        ReceiptContent.make(day: sampleDay(), number: 128, petName: "mochi", streak: 5)
    }

    static var pose: PetSprite.Pose { PetSprite.Pose(eyes: .happy, mouth: .smile, blush: true, outfit: .sprout) }

    @MainActor
    static func write(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func save<V: View>(_ v: V, _ name: String, scale: CGFloat = 2) {
            let r = ImageRenderer(content: v)
            r.scale = scale
            guard let img = r.nsImage, let data = ReceiptExport.png(img) else { return }
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        save(PromoHero(), "hero.png")
        save(PromoStates(), "states.png")
        save(ReceiptShareCard(content: content, pose: pose, petName: "mochi", level: 4), "receipt.png")
        save(PromoSocial(), "social-preview.png", scale: 2)
    }
}

/// A black notch hanging from the top edge, like on screen.
private struct HangingNotch<Content: View>: View {
    var width: CGFloat = 560
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(.horizontal, 10)
            .frame(width: width, alignment: .top)
            .background(NotchShape(topRadius: 10, bottomRadius: 28).fill(Color.black))
            .environment(\.colorScheme, .dark)
    }
}

private struct PromoHeader: View {
    let title: String
    var body: some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            ForEach(["plus", "gearshape.fill"], id: \.self) { s in
                Image(systemName: s).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26).background(Circle().fill(Palette.surface3))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }
}

private struct PromoHero: View {
    var body: some View {
        VStack(spacing: 0) {
            HangingNotch {
                VStack(spacing: 6) {
                    PromoHeader(title: "All caught up")
                    HStack(alignment: .top, spacing: 18) {
                        stats
                        VStack(spacing: 0) {
                            PetCanvas(frame: PetBrain.Frame(pose: Promo.pose), pixel: 3, ink: .white, roams: false, ground: 0)
                                .frame(width: 84, height: 48)
                            PrinterSlot().zIndex(1)
                            ReceiptPaper(content: Promo.content, pose: Promo.pose).padding(.top, -3)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 16)
                }
            }
        }
        .padding(.horizontal, 70)
        .padding(.bottom, 60)
        .background(Promo.backdrop)
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("mochi").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text("lvl 4").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.black)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Color.white))
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.surface3)
                Capsule().fill(Color.white).frame(width: 218 * 0.55)
            }
            .frame(width: 218, height: 6)
            Text("820 / 1,000 xp to lvl 5").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.text3)
            VStack(alignment: .leading, spacing: 6) {
                fact("face.smiling", "just ate. vibing 😌")
                fact("flame", "5 day streak")
                fact("shippingbox", "64 tasks shipped all time")
                fact("gift", "lvl 6 unlocks headphones 🎧")
            }
            HStack(spacing: 8) {
                Label("Post it", systemImage: "paperplane.fill")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 11).frame(height: 24).background(Capsule().fill(Color.white))
                ForEach(["doc.on.doc", "square.and.arrow.down"], id: \.self) { s in
                    Image(systemName: s).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 11).frame(height: 24).background(Capsule().fill(Palette.surface3))
                }
            }
        }
        .frame(width: 218, alignment: .leading)
        .padding(.top, 8)
    }

    private func fact(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.text3).frame(width: 14)
            Text(text).font(.system(size: 12)).foregroundStyle(Palette.text2)
        }
    }
}

/// The collapsed notch in its three moods: idle with the pet, working, and asking.
private struct PromoStates: View {
    var body: some View {
        VStack(spacing: 22) {
            pill(width: 236) {
                Spacer()
                PetCanvas(frame: PetBrain.Frame(pose: PetSprite.Pose(eyes: .open(dx: 1), outfit: .sprout)),
                          pixel: 2, ink: .white, roams: false, ground: 0)
                    .frame(width: 32, height: 28)
                    .clipped()
                Spacer()
            }
            pill(width: 380) {
                Image(systemName: "asterisk").font(.system(size: 13, weight: .heavy)).foregroundStyle(Color.claude).frame(width: 15)
                Text("checkout").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                Text("Running the tests").font(.system(size: 12.5)).foregroundStyle(Palette.text2)
                Spacer()
                Text("3/5").font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundStyle(Palette.text2)
                ProgressRing(fraction: 0.6)
            }
            pill(width: 380) {
                Image(systemName: "circle.fill").font(.system(size: 8.5)).foregroundStyle(Color.approval).frame(width: 15)
                Text("api").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                Text("wants to run a command").font(.system(size: 12.5)).foregroundStyle(Color.approval)
                Spacer()
                Text("1").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                    .frame(minWidth: 18, minHeight: 18).background(Capsule().fill(Color.approval))
            }
        }
        .padding(.vertical, 34)
        .padding(.horizontal, 60)
        .background(Promo.backdrop)
        .environment(\.colorScheme, .dark)
    }

    private func pill<C: View>(width: CGFloat, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 8) { c() }
            .padding(.horizontal, 14)
            .frame(width: width, height: 30)
            .background(NotchShape(topRadius: 6, bottomRadius: 15).fill(Color.black))
    }
}

/// 1280 × 640 card for link previews (GitHub, X, Slack).
private struct PromoSocial: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Spacer().frame(height: 120)
                Text("NotchBar")
                    .font(.system(size: 96, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text("Dynamic Island for your\nAI coding agents")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineSpacing(2)
                Text("Claude Code · Codex · Cursor")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(Capsule().fill(Color.white))
                    .padding(.top, 10)
                Spacer()
                Text("free and open source for macOS")
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.bottom, 56)
            }
            .padding(.leading, 84)
            Spacer()
            VStack(spacing: 0) {
                PetCanvas(frame: PetBrain.Frame(pose: Promo.pose), pixel: 5, ink: .white, roams: false, ground: 0)
                    .frame(width: 140, height: 80)
                    .padding(.top, 58)
                PrinterSlot().scaleEffect(1.25).zIndex(1)
                ReceiptPaper(content: Promo.content, pose: Promo.pose)
                    .scaleEffect(1.25, anchor: .top)
                    .padding(.top, -2)
            }
            .frame(width: 380, height: 640, alignment: .top)
            .clipped()
            .padding(.trailing, 84)
        }
        .frame(width: 1280, height: 640)
        .background(Color(white: 0.055))
        .environment(\.colorScheme, .dark)
    }
}
#endif
