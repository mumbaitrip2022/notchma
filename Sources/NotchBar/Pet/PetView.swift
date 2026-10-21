import SwiftUI

/// Draws the pet's current frame as crisp square pixels.
struct PetView: View {
    @ObservedObject var brain: PetBrain
    var pixel: CGFloat = 1.5
    var ink: Color = .white
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
            PetCanvas(frame: brain.frame, pixel: pixel, ink: ink, roams: roams, ground: ground)
                .onAppear { brain.appeared(stageWidth: roams ? stagePx : nil, hidden: hiddenPx) }
                .onDisappear { brain.disappeared() }
                .onChange(of: stagePx) { _, w in if roams { brain.setStage(w, hidden: hiddenPx) } }
        }
        .accessibilityLabel("Notch pet")
    }
}

/// Pure drawing, so it can also be rendered into a shareable image.
struct PetCanvas: View {
    let frame: PetBrain.Frame
    var pixel: CGFloat
    var ink: Color
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
            for (y, row) in grid.enumerated() {
                for (x, cell) in row.enumerated() where cell != .none {
                    let r = CGRect(x: originX + CGFloat(x) * pixel, y: originY + CGFloat(y) * pixel,
                                   width: pixel, height: pixel)
                    ctx.fill(Path(r), with: .color(cell == .full ? ink : dim))
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
                        ctx.fill(Path(r), with: .color((ch == "+" ? dim : ink).opacity(fade)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
