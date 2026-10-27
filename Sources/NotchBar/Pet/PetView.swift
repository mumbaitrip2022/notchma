import AppKit
import Combine
import SwiftUI

/// The live pet. Frames are drawn by `PetLayerView` straight into a layer bitmap at
/// screen resolution, so a tick never re-renders SwiftUI or lays out the notch window.
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

/// One small layer whose contents are the pet, drawn at the screen's resolution.
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
    private var ctxUnit: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        sprite.anchorPoint = .zero
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
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); redraw() }

    private func redraw() {
        let size = bounds.size, px = style.pixel
        guard size.width > 0, size.height > 0, px > 0 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let unit = px * scale // bitmap pixels per pet pixel
        let w = Int((size.width * scale).rounded(.up)), h = Int((size.height * scale).rounded(.up))
        if ctx?.width != w || ctx?.height != h || ctxUnit != unit {
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            // Draw top-down in pet pixels, like the sprite rows.
            ctx?.translateBy(x: 0, y: CGFloat(h))
            ctx?.scaleBy(x: unit, y: -unit)
            ctxUnit = unit
        }
        guard let c = ctx else { return }
        let stageH = CGFloat(h) / unit
        c.clear(CGRect(x: 0, y: 0, width: CGFloat(w) / unit, height: stageH))
        PetCanvas.draw(current, in: c, stageWidth: size.width / px, height: stageH, ink: style.ink.cgColor,
                       accent: style.accent?.cgColor, roams: style.roams, ground: CGFloat(style.ground))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.contents = c.makeImage()
        sprite.contentsScale = scale
        // Anchored bottom-left, like the SwiftUI canvas: feet sit `ground` pixels above the bottom.
        sprite.frame = CGRect(x: 0, y: 0, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
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
            let ink = NSColor(ink).cgColor, accent = accent.map { NSColor($0).cgColor }
            ctx.withCGContext { cg in
                cg.scaleBy(x: pixel, y: pixel)
                PetCanvas.draw(frame, in: cg, stageWidth: size.width / pixel, height: size.height / pixel,
                               ink: ink, accent: accent, roams: roams, ground: ground)
            }
        }
        .allowsHitTesting(false)
    }
    /// The picture in pet pixels: one unit is one pet pixel, y grows down.
    static func draw(_ frame: PetBrain.Frame, in c: CGContext, stageWidth: CGFloat, height: CGFloat, ink: CGColor,
                     accent: CGColor? = nil, roams: Bool, ground: CGFloat) {
        let size = CGFloat(PetSprite.width)
        let originX = roams ? CGFloat(frame.x) : max(0, ((stageWidth - size) / 2).rounded(.down))
        let originY = height - ground - CGFloat(PetSprite.height) - CGFloat(frame.lift)
        let dim = ink.copy(alpha: ink.alpha * 0.45) ?? ink
        let pink = accent ?? dim
        c.saveGState()
        c.translateBy(x: originX, y: originY)
        PetVector.draw(frame.pose, in: c, ink: ink, pink: pink)
        c.restoreGState()
        for p in frame.particles {
            let h = CGFloat(PetSprite.particle(p.kind).count)
            let fade = p.kind == .z || p.kind == .sparkle ? min(1, CGFloat(p.life) / 3) : 1
            PetVector.particle(p.kind, at: CGPoint(x: originX + p.x, y: originY + p.y - h), in: c,
                               ink: ink, pink: pink, alpha: fade)
        }
    }
}
