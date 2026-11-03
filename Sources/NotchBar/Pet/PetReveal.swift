import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The shareable "outfit reveal": the pet twirls into a poof of cloud and pops out
/// wearing its newest unlock, with confetti. Rendered frame by frame into a looping GIF.
enum PetReveal {
    static let fps = 20.0
    static let count = 84            // about 4 seconds
    static let swapAt = 31           // the new look appears inside the cloud

    struct Shot {
        let unlock: PetLook.Unlock
        let before: PetSprite.Pose
        let after: PetSprite.Pose
        let name: String
    }

    /// The newest thing unlocked at or below this level.
    static func latest(level: Int) -> PetLook.Unlock? { PetLook.unlocks.last { $0.level <= level } }

    static func shot(_ u: PetLook.Unlock, name: String, wear: PetSprite.Outfit?) -> Shot {
        func look(_ level: Int, _ outfit: PetSprite.Outfit) -> PetSprite.Pose {
            var p = PetSprite.Pose()
            p.outfit = outfit
            p.gear = PetLook.gear(level: level).intersection([.bow, .boots, .aura, .orbit])
            return p
        }
        let was = PetLook.outfit(level: u.level - 1, wear: wear)
        let now = u.outfit ?? PetLook.outfit(level: u.level, wear: wear)
        return Shot(unlock: u, before: look(u.level - 1, was), after: look(u.level, now), name: name)
    }

    // MARK: the timeline

    /// One frame of the reveal, as the canvas draws it.
    static func frame(_ f: Int, _ s: Shot) -> PetBrain.Frame {
        var out = PetBrain.Frame()
        var p = f < swapAt ? s.before : s.after
        p.phase = f / 4
        let gear = s.unlock.gear
        var lift = 0

        switch f {
        case ..<16:
            // Just sitting there, looking around.
            p.eyes = f == 13 ? .blink : .open(dx: f < 5 ? 0 : (f < 9 ? -1 : (f < 13 ? 1 : 0)))
            p.tail = (f / 5) % 2 == 0 ? .up : .curl
        case 16..<22:
            // Gets ready.
            p.feet = .tucked; p.eyes = .closed; p.ears = false; p.tail = .down
        case 22..<40:
            // The twirl: up, spinning, and back down.
            let u = Double(f - 22) / 18
            lift = Int((7 * sin(.pi * u)).rounded())
            p.flip = ((f - 22) / 2) % 2 == 1
            p.feet = .tucked; p.eyes = .happy; p.mouth = .open
            p.flying = lift > 0
        case 40..<48:
            p.eyes = f < 43 ? .wide : .happy
            p.mouth = .open; p.blush = true
            lift = f == 44 || f == 45 ? 1 : 0
        default:
            // Showing off the new look.
            p.eyes = (62..<67).contains(f) ? .wink : .happy
            p.mouth = .smile; p.blush = true
            p.tail = (f / 6) % 2 == 0 ? .up : .curl
            if (49..<53).contains(f) { lift = 1 }
            if gear.contains(.boots), (54..<66).contains(f) {
                // Rocket boots: a little hover.
                lift = Int((3 * sin(.pi * Double(f - 54) / 12)).rounded())
                p.flying = lift > 0; p.feet = .tucked; p.mouth = .open
            }
        }
        out.pose = p
        out.lift = lift
        out.particles = particles(f, gear)
        return out
    }

    /// Stable pseudo random numbers so every export is the same.
    private static func hash(_ i: Int, _ salt: Double) -> Double {
        let v = sin(Double(i) * 12.9898 + salt * 78.233) * 43758.5453
        return v - v.rounded(.down)
    }

    private static func particles(_ f: Int, _ gear: PetSprite.Gear) -> [PetBrain.Particle] {
        var ps: [PetBrain.Particle] = []
        // Sparkles gathering in before the twirl.
        if (10..<28).contains(f) {
            let u = Double(f - 10) / 18
            for k in 0..<6 {
                let a = Double(k) * .pi / 3 + Double(f) * 0.28
                let r = 2 + 13 * (1 - u)
                ps.append(.init(kind: .star, x: 7 + r * cos(a), y: 9 + r * 0.7 * sin(a), life: f < 25 ? 9 : 28 - f, tint: k % 3))
            }
        }
        // The burst when it lands.
        if (38..<62).contains(f) {
            let d = Double(f - 38)
            let r = 3 + 15 * (1 - exp(-d / 5))
            for k in 0..<10 {
                let a = Double(k) * .pi / 5 + 0.3
                ps.append(.init(kind: .star, x: 7 + r * cos(a), y: 8 + r * 0.75 * sin(a) + d * 0.08,
                                life: f < 52 ? 9 : (62 - f) / 3, tint: k % 3))
            }
        }
        // Landing puffs.
        if (40..<48).contains(f) {
            let d = Double(f - 40)
            ps.append(.init(kind: .puff, x: 2 - d * 0.5, y: 15, life: 4 - (f - 40) / 2))
            ps.append(.init(kind: .puff, x: 13 + d * 0.5, y: 15, life: 4 - (f - 40) / 2))
        }
        // Confetti raining down from the top.
        if f >= 36 {
            for k in 0..<26 {
                let start = 36 + Int(hash(k, 1) * 10)
                guard f >= start else { continue }
                let d = Double(f - start)
                let x = -12 + hash(k, 2) * 40 + sin(d * 0.25 + Double(k)) * 1.2
                let y = -9 - hash(k, 3) * 6 + d * (0.38 + hash(k, 4) * 0.25)
                guard y < 19 else { continue }
                ps.append(.init(kind: .confetti, x: x, y: y, life: 200 - f, tint: k % 3))
            }
        }
        // Twinkles while it poses.
        if f >= 50 {
            let spots: [(Double, Double)] = [(-6, 3), (20, 1), (19, 11), (-5, 12), (8, -4)]
            for (k, s) in spots.enumerated() where (f + k * 7) % 21 < 7 {
                ps.append(.init(kind: .star, x: s.0, y: s.1, life: 9, tint: k % 3))
            }
        }
        // Gear that only shows while moving gets its own little moment.
        if gear.contains(.trail), f >= 50 {
            for k in 0..<7 where (f / 3 + k) % 4 != 0 {
                ps.append(.init(kind: .star, x: -10 + Double(k) * 6, y: 15 - Double((f / 3 + k) % 3), life: 9, tint: k % 3))
            }
        }
        if gear.contains(.shooting), (50..<72).contains(f) {
            let d = Double(f - 50)
            ps.append(.init(kind: .shooting, x: -14 + d * 2.2, y: -6 + d * 0.5, vx: 2.2, vy: 0.5, life: 9))
        }
        return ps
    }

    // MARK: export

    /// The whole reveal as a looping GIF.
    @MainActor
    static func gif(_ s: Shot, scale: CGFloat = 2) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, count, nil) else { return nil }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps,
                                                     kCGImagePropertyGIFUnclampedDelayTime: 1 / fps]] as CFDictionary
        for f in 0..<count {
            let r = ImageRenderer(content: Card(shot: s, f: f))
            r.scale = scale
            guard let img = r.cgImage else { return nil }
            CGImageDestinationAddImage(dest, img, delay)
        }
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Saves to the Desktop and puts it on the clipboard, ready to paste or drag into a post.
    static func share(_ gif: Data, name: String, unlock: PetLook.Unlock) -> URL? {
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let file = "\(name) unlocked \(unlock.name)".replacingOccurrences(of: "/", with: " ")
        let url = dir.appendingPathComponent(file + ".gif")
        do { try gif.write(to: url, options: .atomic) } catch { return nil }
        let item = NSPasteboardItem()
        item.setData(gif, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
        item.setString(url.absoluteString, forType: .fileURL)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        return url
    }

    // MARK: the card

    static let size = CGSize(width: 340, height: 340)

    struct Card: View {
        let shot: Shot
        let f: Int

        private static let pixel: CGFloat = 9

        var body: some View {
            let fr = PetReveal.frame(f, shot)
            ZStack(alignment: .top) {
                Color(white: 0.06)
                // A soft pink glow behind the new look.
                RadialGradient(colors: [PetSprite.blushColor.opacity(0.28), .clear], center: .center, startRadius: 4, endRadius: 150)
                    .frame(width: 340, height: 300)
                    .offset(y: 40)
                    .opacity(ramp(36, 46))
                NotchShape(topRadius: 6, bottomRadius: 14)
                    .fill(Color.black)
                    .frame(width: 150, height: 26)
                VStack(spacing: 0) {
                    ZStack {
                        PetCanvas(frame: fr, pixel: Self.pixel, ink: .white, roams: false, ground: 2)
                        cloud(lift: fr.lift)
                    }
                    .frame(width: 340, height: 236)
                    .padding(.top, 26)
                    caption
                }
            }
            .frame(width: PetReveal.size.width, height: PetReveal.size.height)
            .opacity(min(ramp(-1, 2), 1 - ramp(PetReveal.count - 4, PetReveal.count - 1)))
            .background(Color(white: 0.06))
            .environment(\.colorScheme, .dark)
        }

        /// 0 before `a`, 1 after `b`, a straight line between.
        private func ramp(_ a: Int, _ b: Int) -> Double {
            max(0, min(1, Double(f - a) / Double(max(1, b - a))))
        }

        /// The poof that hides the outfit change.
        private func cloud(lift: Int) -> some View {
            let grow = ramp(25, 30), shrink = ramp(33, 41)
            let s = grow * (1 - shrink)
            let puffs: [(CGFloat, CGFloat, CGFloat)] = [(0, 0, 46), (-38, 10, 34), (38, 8, 36), (-20, -26, 32), (22, -24, 34),
                                                        (-46, -12, 24), (48, -14, 22), (0, 30, 30)]
            let rim = Color(red: 0.96, green: 0.56, blue: 0.72), fill = Color(red: 1, green: 0.84, blue: 0.9)
            return ZStack {
                // A rim layer under a lighter layer gives the cloud its outline.
                ForEach(0..<2, id: \.self) { layer in
                    ForEach(0..<puffs.count, id: \.self) { i in
                        let p = puffs[i], r = p.2 * 1.55 + (layer == 0 ? 3 : 0)
                        Circle().fill(layer == 0 ? rim : fill)
                            .frame(width: r * 2, height: r * 2)
                            .offset(x: p.0 * 1.55 * (0.8 + 0.2 * shrink), y: p.1 * 1.4 * (0.8 + 0.2 * shrink))
                    }
                }
                // Sparkles on the cloud.
                ForEach(0..<3, id: \.self) { k in
                    Image(systemName: "sparkle")
                        .font(.system(size: [18, 13, 15][k], weight: .bold))
                        .foregroundStyle(Color(cgColor: PetSprite.goldColor))
                        .offset(x: [-44, 50, 8][k], y: [-30, -10, 34][k])
                        .rotationEffect(.degrees(Double(f) * 12))
                }
            }
            .scaleEffect(0.2 + 0.8 * s)
            .opacity(s == 0 ? 0 : min(1, s * 1.6))
            .offset(y: 236 / 2 - 2 * Self.pixel - 8 * Self.pixel - CGFloat(lift) * Self.pixel)
        }

        private var caption: some View {
            let u = shot.unlock
            let title = u.level >= PetLook.maxLevel ? "\(shot.name) ascended \(u.emoji)" : "\(shot.name) unlocked \(u.name) \(u.emoji)"
            let after = ramp(41, 48)
            return ZStack {
                Text("something's happening 👀")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .opacity(1 - ramp(30, 36))
                VStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("lvl \(u.level) · the pet that lives in my notch")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .opacity(after)
                .offset(y: 8 * (1 - after))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 20)
            .frame(height: 52)
        }
    }
}
