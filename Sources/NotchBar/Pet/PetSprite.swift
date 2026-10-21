import Foundation

/// Pixel art for the notch pet, built from parts so every mood, outfit and
/// frame comes from one small template. 14 × 16 grid: 4 rows of headroom for
/// accessories, an 11-row body, 1 spare row.
enum PetSprite {
    static let width = 14
    static let height = 16
    private static let bodyTop = 4

    enum Ink: UInt8 { case none = 0, full, dim }

    enum Eyes: Equatable { case open(dx: Int), closed, happy, sleepy, shades, wide }
    enum Mouth: Equatable { case small, open, smile, flat }
    enum Feet: Equatable { case stand, stepA, stepB, tucked }
    enum Outfit: Int, Comparable {
        case none, sprout, headphones, crown
        static func < (a: Outfit, b: Outfit) -> Bool { a.rawValue < b.rawValue }
        static func forLevel(_ l: Int) -> Outfit { l >= 10 ? .crown : l >= 6 ? .headphones : l >= 3 ? .sprout : .none }
    }

    struct Pose: Equatable {
        var eyes: Eyes = .open(dx: 0)
        var mouth: Mouth = .small
        var feet: Feet = .stand
        var ears = true          // false = folded (sleepy, sad)
        var blush = false
        var squash = false       // sleeping loaf: one row shorter
        var outfit: Outfit = .none
        var egg = false
        var flip = false         // face left
    }

    /// Row-major grid, `height` rows of `width` pixels.
    static func render(_ p: Pose) -> [[Ink]] {
        var g = Array(repeating: Array(repeating: Ink.none, count: width), count: height)
        if p.egg { drawEgg(&g, p); return g }

        let top = bodyTop + (p.squash ? 1 : 0)
        var rows: [String] = []
        rows.append(p.ears && !p.squash ? ".##........##." : "..............")
        rows.append(p.ears && !p.squash ? ".###......###." : ".##........##.")
        rows.append(".############.")
        rows.append("##############")
        rows.append(contentsOf: eyeRows(p.eyes))
        rows.append(p.blush ? "#+##########+#" : "##############")
        rows.append(contentsOf: mouthRows(p.mouth))
        rows.append(".############.")
        rows.append(feetRow(p.squash ? .tucked : p.feet))
        if p.squash { rows.remove(at: 3) } // loaf: drop a body row
        stamp(&g, rows, x: 0, y: top)

        switch p.outfit {
        case .none: break
        case .sprout:
            stamp(&g, ["......#.##....", ".......##.....", ".......#......"], x: 0, y: top - 3)
        case .headphones:
            stamp(&g, ["...########...", "..#........#.."], x: 0, y: top - 2)
        case .crown:
            stamp(&g, ["...#..##..#...", "...########...", "...########..."], x: 0, y: top - 3)
        }
        if p.flip { g = g.map { $0.reversed() } }
        return g
    }

    private static func eyeRows(_ e: Eyes) -> [String] {
        switch e {
        case let .open(dx):
            let d = max(-1, min(1, dx))
            var r = Array("##############")
            for c in [3, 4, 9, 10] { r[c + d] = "." }
            return [String(r), String(r)]
        case .wide:    return ["##..######..##", "##..######..##"]
        case .closed:  return ["##############", "##...####...##"]
        case .sleepy:  return ["##############", "###..####..###"]
        case .happy:   return ["###.######.###", "##.#.####.#.##"]
        case .shades:  return ["#............#", "##...####...##"]
        }
    }

    private static func mouthRows(_ m: Mouth) -> [String] {
        switch m {
        case .small: return ["######..######", "##############"]
        case .open:  return ["#####....#####", "######..######"]
        case .smile: return ["#####.##.#####", "######..######"]
        case .flat:  return ["#####....#####", "##############"]
        }
    }

    private static func feetRow(_ f: Feet) -> String {
        switch f {
        case .stand:  return "..###....###.."
        case .stepA:  return "..##.....###.."
        case .stepB:  return "..###.....##.."
        case .tucked: return "...########..."
        }
    }

    private static func drawEgg(_ g: inout [[Ink]], _ p: Pose) {
        var rows = ["....######....", "...########...", "..##########..", "..##########..",
                    ".############.", ".############.", ".############.", ".############.",
                    ".############.", "..##########..", "...########..."]
        // Eyes peek out of the shell.
        switch p.eyes {
        case .closed, .sleepy: rows[5] = ".###..##..###."
        case let .open(dx):
            var r = Array(rows[4]), s = Array(rows[5])
            for c in [4, 5, 8, 9] { r[c + max(-1, min(1, dx))] = "."; s[c + max(-1, min(1, dx))] = "." }
            rows[4] = String(r); rows[5] = String(s)
        default:
            rows[4] = ".###.####.###."; rows[5] = ".##.#.##.#.##."
        }
        rows[8] = ".####.##.####." // crack
        stamp(&g, rows, x: 0, y: bodyTop + 1)
    }

    static func stamp(_ g: inout [[Ink]], _ rows: [String], x: Int, y: Int) {
        for (dy, row) in rows.enumerated() {
            let gy = y + dy
            guard gy >= 0, gy < g.count else { continue }
            for (dx, ch) in row.enumerated() {
                let gx = x + dx
                guard gx >= 0, gx < g[gy].count else { continue }
                switch ch {
                case "#": g[gy][gx] = .full
                case "+": g[gy][gx] = .dim
                default: break
                }
            }
        }
    }

    // MARK: particles

    enum ParticleKind: Equatable { case heart, z, sparkle, cookie, crumb, note, gift }

    static func particle(_ k: ParticleKind) -> [String] {
        switch k {
        case .heart:   return [".#.#.", "#####", ".###.", "..#.."]
        case .z:       return ["###", ".#.", "###"]
        case .sparkle: return [".#.", "###", ".#."]
        case .cookie:  return [".##.", "#+##", "##+#", ".##."]
        case .crumb:   return ["#"]
        case .note:    return [".##", ".#.", "##."]
        case .gift:    return ["##.##", ".###.", "#####", "##+##", "##+##"]
        }
    }
}
