import AppKit
import Combine
import SwiftUI

/// The live pet. Frames are drawn by `PetLayerView` into a tiny bitmap that Core
/// Animation scales up with nearest-neighbour filtering, so a tick never re-renders
/// SwiftUI or lays out the notch window.
struct PetView: View {
    let brain: PetBrain
    var pixel: CGFloat = 1.5
    var ink: Color = .white
    /// Pink for ears, cheeks and hearts; nil draws them dim (receipt paper).
    var accent: Color? = PetSprite.blushColor
    /// Walk around the stage (compact notch) or stay centered (hero, receipt).
    var roams = true
    /// Pixels kept clear under the feet.
    var ground: CGFloat = 1
    /// Width (pt) hidden by a hardware notch in the middle of the stage.
    var hiddenWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let stagePx = Int(geo.size.width / pixel)
            let hiddenPx = Int((hiddenWidth / pixel).rounded(.up))
            PetLayer(brain: brain, pixel: pixel, ink: NSColor(ink), accent: accent.map { NSColor($0) }, roams: roams, ground: Int(ground))
                .allowsHitTesting(false)
                .onAppear { brain.appeared(stageWidth: roams ? stagePx : nil, hidden: hiddenPx) }
                .onDisappear { brain.disappeared() }
                .onChange(of: stagePx) { _, w in if roams { brain.setStage(w, hidden: hiddenPx) } }
        }
        .accessibilityLabel("Notch pet")
    }
}

private struct PetLayer: NSViewRepresentable {
    let brain: PetBrain
    let pixel: CGFloat
    let ink: NSColor
    let accent: NSColor?
    let roams: Bool
    let ground: Int

    func makeNSView(context: Context) -> PetLayerView {
        let v = PetLayerView()
        v.style = .init(pixel: pixel, ink: ink, accent: accent, roams: roams, ground: ground)
        v.attach(brain)
        return v
    }

    func updateNSView(_ v: PetLayerView, context: Context) {
        v.style = .init(pixel: pixel, ink: ink, accent: accent, roams: roams, ground: ground)
    }
}

/// One small layer whose contents are the pet in pet pixels (a ~100×16 bitmap).
final class PetLayerView: NSView {
    struct Style: Equatable {
        var pixel: CGFloat = 1.5
        var ink: NSColor = .white
        var accent: NSColor?
        var roams = true
        var ground = 1
    }

    var style = Style() { didSet { if style != oldValue { redraw() } } }
    private var current = PetBrain.Frame()
    private var sub: AnyCancellable?
    private let sprite = CALayer()
    private var ctx: CGContext?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        sprite.anchorPoint = .zero
        sprite.magnificationFilter = .nearest
        sprite.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(sprite)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func attach(_ brain: PetBrain) {
        current = brain.frame
        sub = brain.frames.sink { [weak self] f in
            self?.current = f
            self?.redraw()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); redraw() }

    private func redraw() {
        let size = bounds.size, px = style.pixel
        guard size.width > 0, size.height > 0, px > 0 else { return }
        let w = Int((size.width / px).rounded(.up)), h = Int((size.height / px).rounded(.up))
        if ctx?.width != w || ctx?.height != h {
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            // Draw top-down, like the sprite rows.
            ctx?.translateBy(x: 0, y: CGFloat(h))
            ctx?.scaleBy(x: 1, y: -1)
        }
        guard let c = ctx else { return }
        c.clear(CGRect(x: 0, y: 0, width: w, height: h))
        PetCanvas.draw(current, in: c, stageWidth: Int(size.width / px), height: h, ink: style.ink.cgColor,
                       accent: style.accent?.cgColor, roams: style.roams, ground: style.ground)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.contents = c.makeImage()
        // Anchored bottom-left, like the SwiftUI canvas: feet sit `ground` pixels above the bottom.
        sprite.frame = CGRect(x: 0, y: 0, width: CGFloat(w) * px, height: CGFloat(h) * px)
        CATransaction.commit()
    }
}

/// Pure drawing, so it can also be rendered into a shareable image.
struct PetCanvas: View {
    let frame: PetBrain.Frame
    var pixel: CGFloat
    var ink: Color
    var accent: Color? = PetSprite.blushColor
    var roams = true
    var ground: CGFloat = 1

    var body: some View {
        Canvas { ctx, size in
            let grid = PetSprite.render(frame.pose)
            let spriteW = CGFloat(PetSprite.width) * pixel
            let spriteH = CGFloat(PetSprite.height) * pixel
            let originX = roams ? CGFloat(frame.x) * pixel : ((size.width - spriteW) / 2 / pixel).rounded(.down) * pixel
            let originY = size.height - ground * pixel - spriteH - CGFloat(frame.lift) * pixel
            let dim = ink.opacity(0.45)
            let pink = accent ?? dim
            for (y, row) in grid.enumerated() {
                for (x, cell) in row.enumerated() where cell != .none {
                    let r = CGRect(x: originX + CGFloat(x) * pixel, y: originY + CGFloat(y) * pixel,
                                   width: pixel, height: pixel)
                    ctx.fill(Path(r), with: .color(cell == .full ? ink : cell == .blush ? pink : dim))
                }
            }
            for p in frame.particles {
                let rows = PetSprite.particle(p.kind)
                let px = originX + (p.x.rounded()) * pixel
                let py = originY + (p.y.rounded()) * pixel - CGFloat(rows.count) * pixel
                let fade = p.kind == .z || p.kind == .sparkle ? min(1, Double(p.life) / 3) : 1
                for (y, row) in rows.enumerated() {
                    for (x, ch) in row.enumerated() where ch != "." {
                        let r = CGRect(x: px + CGFloat(x) * pixel, y: py + CGFloat(y) * pixel, width: pixel, height: pixel)
                        ctx.fill(Path(r), with: .color((ch == "+" ? dim : ch == "P" ? pink : ink).opacity(fade)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
    /// The same picture in pet pixels, for `PetLayerView`: one unit is one pet pixel, y grows down.
    static func draw(_ frame: PetBrain.Frame, in c: CGContext, stageWidth: Int, height: Int, ink: CGColor,
                     accent: CGColor? = nil, roams: Bool, ground: Int) {
        let grid = PetSprite.render(frame.pose)
        let originX = roams ? frame.x : max(0, stageWidth - PetSprite.width) / 2
        let originY = height - ground - PetSprite.height - frame.lift
        let dim = ink.copy(alpha: ink.alpha * 0.45) ?? ink
        let pink = accent ?? dim
        for (y, row) in grid.enumerated() {
            for (x, cell) in row.enumerated() where cell != .none {
                c.setFillColor(cell == .full ? ink : cell == .blush ? pink : dim)
                c.fill(CGRect(x: originX + x, y: originY + y, width: 1, height: 1))
            }
        }
        for p in frame.particles {
            let rows = PetSprite.particle(p.kind)
            let px = originX + Int(p.x.rounded())
            let py = originY + Int(p.y.rounded()) - rows.count
            let fade = p.kind == .z || p.kind == .sparkle ? min(1, Double(p.life) / 3) : 1
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch != "." {
                    let base = ch == "+" ? dim : ch == "P" ? pink : ink
                    c.setFillColor(base.copy(alpha: base.alpha * fade) ?? base)
                    c.fill(CGRect(x: px + x, y: py + y, width: 1, height: 1))
                }
            }
        }
    }
}
