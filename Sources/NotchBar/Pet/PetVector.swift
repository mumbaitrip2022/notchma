import CoreGraphics

/// Smooth drawing of the pet. It uses the same 16 × 16 layout as `PetSprite`
/// (one unit is one pet pixel, y grows down), but with round shapes instead of
/// squares, so it stays sharp at any size. Face features are cut out of the body,
/// so whatever is behind the pet shows through them, like the pixel version.
enum PetVector {
    static func draw(_ p: PetSprite.Pose, in c: CGContext, ink: CGColor, pink: CGColor, gold: CGColor? = nil) {
        let gold = gold ?? ink
        c.saveGState()
        defer { c.restoreGState() }
        if p.flip { c.translateBy(x: 16, y: 0); c.scaleBy(x: -1, y: 1) }
        c.setLineCap(.round)
        c.setLineJoin(.round)
        // Cut outs only clear this layer, never what is behind the pet.
        c.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { c.endTransparencyLayer() }
        if p.egg { egg(p, c, ink: ink, pink: pink); return }

        let sq = p.squash, up = p.ears && !sq
        let by: CGFloat = sq ? 7 : 6, sy: CGFloat = sq ? 1 : 0
        let t = CGFloat(p.phase)

        // Behind everything: the aura and the far side of the orbit.
        if p.gear.contains(.aura) { aura(c, pink: pink, t: t) }
        if p.gear.contains(.orbit) { orbit(c, gold: gold, t: t, front: false) }
        c.setFillColor(ink); c.setStrokeColor(ink)

        // Tail
        c.setLineWidth(1.3)
        switch sq ? .down : p.tail {
        case .down: c.move(to: pt(4, 14.4)); c.addQuadCurve(to: pt(1, 13.2), control: pt(1, 15.2))
        case .curl: c.move(to: pt(3, 12.6)); c.addQuadCurve(to: pt(0.9, 10.3), control: pt(0.3, 12.9))
        case .up:   c.move(to: pt(3, 11.6)); c.addQuadCurve(to: pt(1.1, 8.5), control: pt(0.3, 11.4))
        }
        c.strokePath()

        // Feet (gold rocket boots from level 30)
        let boots = p.gear.contains(.boots)
        var feet: [CGRect] = []
        if sq || p.feet == .tucked {
            feet = [CGRect(x: 5, y: 14.2, width: 8, height: 1.8)]
        } else {
            let (a, b): (CGFloat, CGFloat) = p.feet == .stepA ? (4, 11) : p.feet == .stepB ? (5, 12) : (5, 11)
            feet = [CGRect(x: a, y: 14.2, width: 2, height: 1.8), CGRect(x: b, y: 14.2, width: 2, height: 1.8)]
        }
        if boots && p.flying && !sq {
            // Little rocket flames under each foot, flickering.
            let flick: CGFloat = p.phase % 2 == 0 ? 0.8 : 0
            let spots: [CGFloat] = feet.count == 1 ? [6.2, 11.8] : feet.map { $0.midX }
            for x in spots { flame(c, x, 16, 2.4 + flick, pink: pink, gold: gold) }
        }
        c.setFillColor(boots ? gold : ink)
        for f in feet {
            if boots { fillRound(c, f.minX - 0.35, 14.3, f.width + 0.7, 2, 1) } else { fillRound(c, f.minX, f.minY, f.width, f.height, 0.9) }
        }
        c.setFillColor(ink)

        // Ears, then the round body
        let ear = up ? [pt(3.4, 7.6), pt(4.3, 2.9), pt(8.2, 6.3)]
                     : [pt(2.3, by + 2.8), pt(1.2, by + 0.6), pt(5.2, by + 0.2)]
        c.setLineWidth(1.1)
        for e in [ear, mirror(ear)] { c.addLines(between: e); c.closePath(); c.drawPath(using: .fillStroke) }
        if boots {
            // Separate the body from the gold boots, only down by the feet.
            c.saveGState(); c.clip(to: CGRect(x: 0, y: 13.5, width: 18, height: 4))
            cut(c) { c.setLineWidth(0.5); c.addPath(round(2, by, 14, 15 - by, 3.8)); c.strokePath() }
            c.restoreGState()
        }
        fillRound(c, 2, by, 14, 15 - by, 3.8)

        // Pink inside the ears
        if up {
            c.setFillColor(pink); c.setStrokeColor(pink); c.setLineWidth(0.35)
            let inner = [pt(4.9, 6.2), pt(5.05, 4.5), pt(6.8, 6.2)]
            for e in [inner, mirror(inner)] { c.addLines(between: e); c.closePath(); c.drawPath(using: .fillStroke) }
        }

        // Cheeks
        c.setFillColor(pink)
        c.setAlpha(p.blush ? 0.95 : 0.55)
        for x: CGFloat in [4, 14] { c.addPath(oval(x, 11.9, 1.05, p.blush ? 0.7 : 0.5)); c.fillPath() }
        c.setAlpha(1)

        // Eyes
        c.setLineWidth(0.6)
        switch p.eyes {
        case let .open(dx):
            let d = CGFloat(max(-1, min(1, dx))) * 0.7
            for x: CGFloat in [6, 12] { openEye(c, x + d, 10, ink: ink) }
        case .wide:
            for x: CGFloat in [6, 12] {
                cut(c) { c.addPath(oval(x, 9.7, 1.1, 1.5)); c.fillPath() }
                shine(c, x, 9.7, ink: ink)
            }
        case .blink:
            for x: CGFloat in [6, 12] { cut(c) { line(c, pt(x - 0.9, 10.5), pt(x + 0.9, 10.5)) } }
        case .sleepy:
            for x: CGFloat in [6, 12] { cut(c) { c.move(to: pt(x - 0.9, 10.4)); c.addQuadCurve(to: pt(x + 0.9, 10.4), control: pt(x, 10.9)); c.strokePath() } }
        case .closed:
            for x: CGFloat in [6, 12] { cut(c) { arc(c, x, from: 10, dip: 11.4) } }
        case .happy:
            for x: CGFloat in [6, 12] { cut(c) { arc(c, x, from: 10.7, dip: 9.1) } }
        case .wink:
            openEye(c, 6, 10, ink: ink)
            cut(c) { arc(c, 12, from: 10.7, dip: 9.1) }
        case .love:
            for x: CGFloat in [6, 12] {
                cut(c) { c.addPath(heart(x, 10, 3.2)); c.fillPath() }
                c.setFillColor(pink); c.addPath(heart(x, 10, 3.2)); c.fillPath()
            }
        case .shades:
            cut(c) {
                for x: CGFloat in [6, 12] { c.addPath(round(x - 2.1, 9, 4.2, 2.2, 0.9)); c.fillPath() }
                line(c, pt(8, 9.6), pt(10, 9.6))
            }
            c.setStrokeColor(ink); c.setLineWidth(0.35)
            for x: CGFloat in [5, 11] { line(c, pt(x, 9.6), pt(x + 0.8, 9.6)) }
        }

        // Mouth
        c.setLineWidth(0.55)
        switch p.mouth {
        case .small:
            cut(c) { catMouth(c) }
        case .smile:
            cut(c) { c.move(to: pt(8, 11.8)); c.addQuadCurve(to: pt(10, 11.8), control: pt(9, 12.9)); c.strokePath() }
        case .open:
            cut(c) { c.addPath(oval(9, 12.2, 0.9, 0.8)); c.fillPath() }
            c.setFillColor(pink); c.addPath(oval(9, 12.6, 0.55, 0.35)); c.fillPath()
        case .blep:
            cut(c) { catMouth(c); c.addPath(round(8.75, 11.9, 1, 1.3, 0.5)); c.fillPath() }
            c.setFillColor(pink); c.addPath(round(8.75, 11.9, 1, 1.3, 0.5)); c.fillPath()
        case .flat:
            cut(c) { c.move(to: pt(8.1, 12.6)); c.addQuadCurve(to: pt(9.9, 12.6), control: pt(9, 11.7)); c.strokePath() }
        }

        // A pink bow tie under the chin; it wiggles while it moves.
        if p.gear.contains(.bow) { bow(c, sq: sq, moving: p.feet == .stepA || p.feet == .stepB || p.flying, t: t, pink: pink, ink: ink) }

        // Outfits get a thin cut out line so they read on top of the body.
        c.setFillColor(ink); c.setStrokeColor(ink)
        switch p.outfit {
        case .none: break
        case .sprout:
            // Sways in the breeze, and blooms a tiny pink flower when it's happy.
            let base = pt(9, by + 0.3)
            c.saveGState()
            c.translateBy(x: base.x, y: base.y); c.rotate(by: sin(t * 0.5) * 0.14); c.translateBy(x: -base.x, y: -base.y)
            c.setLineWidth(0.7)
            c.move(to: base); c.addQuadCurve(to: pt(9.4, 2.7 + sy), control: pt(9.1, 4 + sy)); c.strokePath()
            c.addPath(oval(10.7, 2.3 + sy, 1.3, 0.65, rot: -0.45)); c.fillPath()
            c.addPath(oval(8.3, 2.5 + sy, 0.95, 0.5, rot: 0.5)); c.fillPath()
            if p.blush {
                let f = pt(9.4, 1.9 + sy)
                c.setFillColor(pink)
                for k in 0..<5 {
                    let a = CGFloat(k) * 2 * .pi / 5 + t * 0.2
                    c.addPath(oval(f.x + cos(a) * 0.75, f.y + sin(a) * 0.75, 0.55, 0.55)); c.fillPath()
                }
                c.setFillColor(gold); c.addPath(oval(f.x, f.y, 0.42, 0.42)); c.fillPath()
                c.setFillColor(ink)
            }
            c.restoreGState()
        case .headphones:
            let band = CGMutablePath()
            band.move(to: pt(2.8, 8 + sy))
            band.addCurve(to: pt(15.2, 8 + sy), control1: pt(2.8, 2.4 + sy), control2: pt(15.2, 2.4 + sy))
            cut(c) { c.setLineWidth(1.5); c.addPath(band); c.strokePath() }
            c.setLineWidth(0.8); c.addPath(band); c.strokePath()
            // Pink cups with a white rim, so they pop on the white cat.
            for x: CGFloat in [1.5, 14.1] {
                outlined(c, round(x, 7.2 + sy, 2.4, 3.2, 1))
                c.setFillColor(pink); c.addPath(round(x + 0.45, 7.65 + sy, 1.5, 2.3, 0.7)); c.fillPath()
                c.setFillColor(ink)
            }
        case .crown:
            // Worn at a sassy little tilt, with a sparkle now and then.
            let b = by + 0.2
            c.saveGState()
            c.translateBy(x: 9, y: b); c.rotate(by: -0.2); c.translateBy(x: -9, y: -b)
            let crown = CGMutablePath()
            crown.addLines(between: [pt(6, b), pt(5.7, b - 3), pt(7.5, b - 1.6), pt(9, b - 3.5),
                                     pt(10.5, b - 1.6), pt(12.3, b - 3), pt(12, b)])
            crown.closeSubpath()
            outlined(c, crown)
            c.setFillColor(pink); c.addPath(oval(9, b - 1, 0.45, 0.45)); c.fillPath()
            if p.phase % 16 < 2 { star(c, 12.3, b - 3, 1.3, color: gold) }
            c.restoreGState()
            c.setFillColor(ink)
        case .wizard:
            // A floppy pink pointed hat between the ears, white dots, a gold star on the tip.
            let b = by + 0.5
            let hat = CGMutablePath()
            hat.move(to: pt(5.6, b))
            hat.addQuadCurve(to: pt(9.7, 1.0 + sy), control: pt(7.6, 3.0 + sy))
            hat.addQuadCurve(to: pt(11.5, 0.5 + sy), control: pt(10.7, 0.1 + sy))
            hat.addQuadCurve(to: pt(12.4, b), control: pt(11.1, 3.4 + sy))
            hat.closeSubpath()
            c.setFillColor(pink)
            outlined(c, hat)
            outlined(c, oval(9, b, 4.4, 0.95))
            c.setFillColor(ink)
            for d in [pt(8.4, b - 2.0), pt(10.5, b - 3.6), pt(10.9, b - 1.4)] { c.addPath(oval(d.x, d.y, 0.38, 0.38)); c.fillPath() }
            let tw: CGFloat = p.phase % 8 < 2 ? 1.8 : 1.25
            star(c, 11.7, 0.6 + sy, tw, color: gold)
            c.setFillColor(ink)
        case .halo:
            let bob = sin(t * 0.55) * 0.45
            c.setStrokeColor(gold); c.setLineWidth(0.75)
            c.addPath(oval(9, 1.5 + bob + sy, 3.3, 0.85)); c.strokePath()
            c.setStrokeColor(ink)
        case .goldCrown:
            let b = by + 0.3
            let crown = CGMutablePath()
            crown.addLines(between: [pt(5.5, b), pt(5.0, b - 3.6), pt(7.2, b - 1.9), pt(9, b - 4.3),
                                     pt(10.8, b - 1.9), pt(13, b - 3.6), pt(12.5, b)])
            crown.closeSubpath()
            c.setFillColor(gold)
            outlined(c, crown)
            for d in [pt(5.0, b - 3.6), pt(9, b - 4.3), pt(13, b - 3.6)] { c.addPath(oval(d.x, d.y, 0.5, 0.5)); c.fillPath() }
            c.setFillColor(pink); c.addPath(oval(9, b - 1.2, 0.55, 0.55)); c.fillPath()
            cut(c) { c.setLineWidth(0.4); line(c, pt(5.6, b - 0.55), pt(12.4, b - 0.55)) }
            // A glint that runs over the gems now and then.
            let g = p.phase % 12
            if g < 3 { star(c, [5.0, 9, 13][g], [b - 3.6, b - 4.3, b - 3.6][g], 1.4, color: ink) }
            c.setFillColor(ink)
        }

        if p.gear.contains(.orbit) { orbit(c, gold: gold, t: t, front: true) }
    }

    // MARK: high level extras

    private static func aura(_ c: CGContext, pink: CGColor, t: CGFloat) {
        let a = 0.55 + 0.2 * sin(t * 0.35)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let base = pink.converted(to: space, intent: .defaultIntent, options: nil),
              let g = CGGradient(colorsSpace: space,
                                 colors: [base.copy(alpha: a)!, base.copy(alpha: a * 0.35)!, base.copy(alpha: 0)!] as CFArray,
                                 locations: [0, 0.55, 1]) else { return }
        c.drawRadialGradient(g, startCenter: pt(9, 10.5), startRadius: 0, endCenter: pt(9, 10.5), endRadius: 10.5, options: [])
    }

    /// Two little stars circling the pet, passing behind it and in front.
    private static func orbit(_ c: CGContext, gold: CGColor, t: CGFloat, front: Bool) {
        for k in 0..<2 {
            let a = t * 0.42 + CGFloat(k) * .pi
            let depth = sin(a)
            guard (depth > 0) == front else { continue }
            let x = 9 + 9.4 * cos(a), y = 9.6 + 2.4 * depth
            c.saveGState()
            c.setAlpha(front ? 1 : 0.55)
            star(c, x, y, 1.15 + 0.35 * depth, color: gold)
            c.restoreGState()
        }
    }

    private static func bow(_ c: CGContext, sq: Bool, moving: Bool, t: CGFloat, pink: CGColor, ink: CGColor) {
        let cx: CGFloat = 9, cy: CGFloat = sq ? 14.2 : 13.95
        let wig: CGFloat = moving ? (Int(t) % 2 == 0 ? 0.25 : -0.25) : 0
        let bow = CGMutablePath()
        for s: CGFloat in [-1, 1] {
            let tip = cx + s * 2.7, top = cy - 1.05 + s * wig, bot = cy + 1.05 + s * wig
            bow.move(to: pt(cx, cy))
            bow.addCurve(to: pt(tip, top), control1: pt(cx + s * 0.9, cy - 0.7), control2: pt(tip - s * 0.6, top - 0.35))
            bow.addQuadCurve(to: pt(tip, bot), control: pt(tip + s * 0.45, cy + s * wig))
            bow.addCurve(to: pt(cx, cy), control1: pt(tip - s * 0.6, bot + 0.35), control2: pt(cx + s * 0.9, cy + 0.7))
            bow.closeSubpath()
        }
        c.saveGState()
        c.setFillColor(pink)
        outlined(c, bow)
        // The knot, with a soft fold line in each loop.
        outlined(c, round(cx - 0.6, cy - 0.65, 1.2, 1.3, 0.5))
        c.setStrokeColor(ink); c.setAlpha(0.55); c.setLineWidth(0.3)
        for s: CGFloat in [-1, 1] { line(c, pt(cx + s * 1.05, cy), pt(cx + s * 1.9, cy - 0.35 + s * wig * 0.5)) }
        c.restoreGState()
    }

    private static func flame(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ len: CGFloat, pink: CGColor, gold: CGColor) {
        let f = CGMutablePath()
        f.move(to: pt(x - 0.95, y))
        f.addQuadCurve(to: pt(x, y + len), control: pt(x - 0.8, y + len * 0.65))
        f.addQuadCurve(to: pt(x + 0.95, y), control: pt(x + 0.8, y + len * 0.65))
        f.closeSubpath()
        c.setFillColor(pink); c.addPath(f); c.fillPath()
        c.setFillColor(gold); c.addPath(oval(x, y + 0.6, 0.5, 0.7)); c.fillPath()
    }

    /// A four point sparkle centered on (x, y), `r` from the center to a tip.
    static func star(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, color: CGColor) {
        let i = r * 0.3
        c.setFillColor(color)
        c.addLines(between: [pt(x, y - r), pt(x + i, y - i), pt(x + r, y), pt(x + i, y + i),
                             pt(x, y + r), pt(x - i, y + i), pt(x - r, y), pt(x - i, y - i)])
        c.closePath(); c.fillPath()
    }

    /// One particle in its pixel box (`PetSprite.particle` sizes), top-left at `o`.
    static func particle(_ p: PetBrain.Particle, at o: CGPoint, in c: CGContext,
                         ink: CGColor, pink: CGColor, gold: CGColor? = nil, alpha: CGFloat) {
        let k = p.kind, gold = gold ?? ink
        c.saveGState()
        defer { c.restoreGState() }
        c.translateBy(x: o.x, y: o.y)
        c.setAlpha(alpha)
        c.setLineCap(.round); c.setLineJoin(.round)
        c.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { c.endTransparencyLayer() }
        c.setFillColor(ink); c.setStrokeColor(ink)
        switch k {
        case .heart:
            c.setFillColor(pink); c.addPath(heart(2.5, 2.1, 4.6)); c.fillPath()
        case .z:
            c.setLineWidth(0.55)
            c.addLines(between: [pt(0.4, 0.5), pt(2.6, 0.5), pt(0.4, 2.5), pt(2.6, 2.5)]); c.strokePath()
        case .sparkle:
            c.addLines(between: [pt(1.5, -0.2), pt(1.85, 1.15), pt(3.2, 1.5), pt(1.85, 1.85),
                                 pt(1.5, 3.2), pt(1.15, 1.85), pt(-0.2, 1.5), pt(1.15, 1.15)])
            c.closePath(); c.fillPath()
        case .cookie:
            c.addPath(oval(2, 2, 1.9, 1.9)); c.fillPath()
            cut(c) { for d in [pt(1.3, 1.4), pt(2.7, 2.5), pt(1.6, 2.9)] { c.addPath(oval(d.x, d.y, 0.35, 0.35)); c.fillPath() } }
        case .crumb:
            c.addPath(oval(0.5, 0.5, 0.5, 0.5)); c.fillPath()
        case .note:
            c.setLineWidth(0.45)
            c.move(to: pt(2.3, 2.3)); c.addLine(to: pt(2.3, 0.3)); c.addQuadCurve(to: pt(3, 1.5), control: pt(3.1, 0.7)); c.strokePath()
            c.addPath(oval(1.6, 2.4, 0.85, 0.62, rot: -0.4)); c.fillPath()
        case .gift:
            fillRound(c, 0.2, 2, 4.6, 3, 0.5)
            cut(c) { c.setLineWidth(0.55); line(c, pt(2.5, 2.2), pt(2.5, 4.8)) }
            c.setFillColor(pink)
            c.addPath(oval(1.6, 1.2, 0.9, 0.55, rot: 0.4)); c.fillPath()
            c.addPath(oval(3.4, 1.2, 0.9, 0.55, rot: -0.4)); c.fillPath()
        case .star:
            star(c, 1.5, 1.5, 1.5, color: p.tint == 2 ? pink : gold)
        case .shooting:
            // A gold head with a fading tail pointing back along its path.
            let len = max(1, (p.vx * p.vx + p.vy * p.vy).squareRoot())
            let dx = -CGFloat(p.vx / len), dy = -CGFloat(p.vy / len)
            for i in 0..<6 {
                let f = CGFloat(i)
                c.setFillColor(gold.copy(alpha: 1 - f / 6) ?? gold)
                c.addPath(oval(0.5 + dx * f * 0.9, 0.5 + dy * f * 0.9, 0.42 - f * 0.05, 0.42 - f * 0.05)); c.fillPath()
            }
        case .puff:
            let r = 0.5 + CGFloat(max(0, 4 - p.life)) * 0.3
            c.setFillColor(ink.copy(alpha: 0.5) ?? ink)
            c.addPath(oval(1, 1, r, r * 0.8)); c.fillPath()
        case .confetti:
            c.setFillColor([pink, gold, ink][p.tint % 3])
            c.translateBy(x: 0.5, y: 0.5)
            c.rotate(by: CGFloat(p.life) * 0.9 + CGFloat(p.tint))
            c.fill(CGRect(x: -0.55, y: -0.3, width: 1.1, height: 0.6))
        }
    }

    // MARK: parts

    private static func egg(_ p: PetSprite.Pose, _ c: CGContext, ink: CGColor, pink: CGColor) {
        let shell = CGMutablePath()
        shell.move(to: pt(8, 5))
        shell.addCurve(to: pt(14, 11.5), control1: pt(11.8, 5), control2: pt(14, 8.5))
        shell.addCurve(to: pt(8, 16), control1: pt(14, 14.3), control2: pt(11.4, 16))
        shell.addCurve(to: pt(2, 11.5), control1: pt(4.6, 16), control2: pt(2, 14.3))
        shell.addCurve(to: pt(8, 5), control1: pt(2, 8.5), control2: pt(4.2, 5))
        c.setFillColor(ink); c.addPath(shell); c.fillPath()
        c.setLineWidth(0.6)
        switch p.eyes {
        case .closed, .sleepy, .blink:
            for x: CGFloat in [6, 10] { cut(c) { line(c, pt(x - 0.8, 10.2), pt(x + 0.8, 10.2)) } }
        case let .open(dx):
            let d = CGFloat(max(-1, min(1, dx))) * 0.6
            for x: CGFloat in [6, 10] {
                cut(c) { c.addPath(oval(x + d, 9.9, 0.8, 1)); c.fillPath() }
                c.setFillColor(ink); c.addPath(oval(x + d + 0.3, 9.5, 0.27, 0.27)); c.fillPath()
            }
        default:
            for x: CGFloat in [6, 10] { cut(c) { arc(c, x, from: 10.5, dip: 9.1, half: 0.85) } }
        }
        c.setFillColor(pink)
        for x: CGFloat in [3.6, 12.4] { c.addPath(oval(x, 11.6, 0.8, 0.5)); c.fillPath() }
        cut(c) {
            c.addLines(between: [pt(1.5, 12.6), pt(4, 13.6), pt(6, 12.6), pt(8, 13.6), pt(10, 12.6), pt(12, 13.6), pt(14.5, 12.6)])
            c.strokePath()
        }
    }

    private static func openEye(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, ink: CGColor) {
        cut(c) { c.addPath(oval(x, y, 0.95, 1.15)); c.fillPath() }
        shine(c, x, y, ink: ink)
    }

    private static func shine(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, ink: CGColor) {
        c.setFillColor(ink); c.addPath(oval(x + 0.35, y - 0.45, 0.32, 0.32)); c.fillPath()
    }

    /// The cat "ω" mouth.
    private static func catMouth(_ c: CGContext) {
        c.move(to: pt(7.9, 11.7))
        c.addQuadCurve(to: pt(9, 11.8), control: pt(8.45, 12.6))
        c.addQuadCurve(to: pt(10.1, 11.7), control: pt(9.55, 12.6))
        c.strokePath()
    }

    /// A curved eye: ‿ when `dip` is below `from`, ^ when above.
    private static func arc(_ c: CGContext, _ x: CGFloat, from y: CGFloat, dip: CGFloat, half: CGFloat = 1) {
        c.move(to: pt(x - half, y)); c.addQuadCurve(to: pt(x + half, y), control: pt(x, dip)); c.strokePath()
    }

    /// Runs `body` with drawing that erases instead of paints.
    private static func cut(_ c: CGContext, _ body: () -> Void) {
        c.saveGState(); c.setBlendMode(.clear); body(); c.restoreGState()
    }

    private static func outlined(_ c: CGContext, _ path: CGPath) {
        cut(c) { c.setLineWidth(0.6); c.addPath(path); c.strokePath() }
        c.addPath(path); c.fillPath()
    }

    private static func line(_ c: CGContext, _ a: CGPoint, _ b: CGPoint) {
        c.move(to: a); c.addLine(to: b); c.strokePath()
    }

    private static func fillRound(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) {
        c.addPath(round(x, y, w, h, r)); c.fillPath()
    }

    private static func round(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
               cornerWidth: min(r, w / 2), cornerHeight: min(r, h / 2), transform: nil)
    }

    private static func oval(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, rot: CGFloat = 0) -> CGPath {
        var t = CGAffineTransform(translationX: x, y: y).rotated(by: rot)
        return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2), transform: &t)
    }

    private static func heart(_ cx: CGFloat, _ cy: CGFloat, _ s: CGFloat) -> CGPath {
        let w = s / 2, h = s * 0.9, p = CGMutablePath()
        p.move(to: pt(cx, cy + h * 0.45))
        p.addCurve(to: pt(cx, cy - h * 0.22), control1: pt(cx - w * 1.15, cy - h * 0.05), control2: pt(cx - w * 0.55, cy - h * 0.7))
        p.addCurve(to: pt(cx, cy + h * 0.45), control1: pt(cx + w * 0.55, cy - h * 0.7), control2: pt(cx + w * 1.15, cy - h * 0.05))
        p.closeSubpath()
        return p
    }

    /// Mirrors across the body's middle (x = 9).
    private static func mirror(_ pts: [CGPoint]) -> [CGPoint] { pts.map { CGPoint(x: 18 - $0.x, y: $0.y) } }
    private static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
}
