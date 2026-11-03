#if DEBUG
import AppKit
import SwiftUI

/// Debug only: every look from level 1 to 50, and frame strips of the celebrations, on one image.
enum PetSheet {
    static let levels = [1, 3, 6, 10, 15, 20, 25, 30, 35, 40, 45, 50]

    @MainActor static func write(to path: String) {
        let r = ImageRenderer(content: Sheet())
        r.scale = 2
        guard let img = r.nsImage, let data = ReceiptExport.png(img) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    static func pose(level: Int, _ edit: (inout PetSprite.Pose) -> Void = { _ in }) -> PetSprite.Pose {
        var p = PetSprite.Pose(eyes: .open(dx: 0))
        p.outfit = PetLook.outfit(level: level, wear: nil)
        p.gear = PetLook.gear(level: level).intersection([.scarf, .boots, .aura, .orbit])
        edit(&p)
        return p
    }

    /// Runs a real brain offscreen and keeps every `every`th frame.
    static func film(level: Int, frames: Int, every: Int = 1, _ kick: (PetBrain) -> Void) -> [PetBrain.Frame] {
        let b = PetBrain()
        b.level = { level }
        b.lastFedAt = { Date() }
        b.stayPut = true
        b.setStage(28)
        kick(b)
        var out: [PetBrain.Frame] = []
        for i in 0..<frames {
            b.debugStep(1)
            if i % every == 0 { out.append(b.frame) }
        }
        return out
    }

    private struct Sheet: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(PetSheet.levels, id: \.self) { l in
                    HStack(spacing: 6) {
                        Text("lvl \(l)").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white)
                            .frame(width: 52, alignment: .leading)
                        cell(PetSheet.pose(level: l))
                        cell(PetSheet.pose(level: l) { $0.phase = 5; $0.eyes = .happy; $0.mouth = .smile; $0.blush = true })
                        cell(PetSheet.pose(level: l) { $0.phase = 9; $0.feet = .stepA; $0.eyes = .open(dx: 1) }, lift: 1)
                        cell(PetSheet.pose(level: l) { $0.phase = 3; $0.feet = .tucked; $0.flying = true; $0.eyes = .happy; $0.mouth = .open }, lift: 3)
                        cell(PetSheet.pose(level: l) { $0.phase = 2; $0.squash = true; $0.eyes = .closed; $0.ears = false })
                        cell(PetSheet.pose(level: l) { $0.flip = true; $0.phase = 14 })
                        // On receipt paper.
                        PetCanvas(frame: .init(pose: PetSheet.pose(level: l) { $0.eyes = .happy; $0.mouth = .smile }),
                                  pixel: 4, ink: Thermal.ink, accent: nil, roams: false, ground: 0)
                            .frame(width: 112, height: 72).background(Thermal.paper)
                    }
                }
                strip("lvl 50 unlock", PetSheet.film(level: 50, frames: 60, every: 4) { $0.celebrate(level: 50) })
                strip("lvl 30 unlock", PetSheet.film(level: 30, frames: 48, every: 4) { $0.celebrate(level: 30) })
                strip("lvl 47 party", PetSheet.film(level: 47, frames: 16) { $0.celebrate(level: 47) })
                strip("100 day dance", PetSheet.film(level: 12, frames: 40, every: 3) { $0.celebrate(streak: 100) })
            }
            .padding(20)
            .background(Color.black)
        }

        private func cell(_ p: PetSprite.Pose, lift: Int = 0) -> some View {
            PetCanvas(frame: .init(pose: p, lift: lift), pixel: 4, ink: .white, roams: false, ground: 1)
                .frame(width: 112, height: 72)
                .background(Color(white: 0.07))
        }

        private func strip(_ title: String, _ frames: [PetBrain.Frame]) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white)
                HStack(spacing: 2) {
                    ForEach(Array(frames.enumerated()), id: \.offset) { _, f in
                        PetCanvas(frame: f, pixel: 2.5, ink: .white, roams: false, ground: 1)
                            .frame(width: 70, height: 50)
                            .background(Color(white: 0.07))
                    }
                }
            }
        }
    }
}
#endif
