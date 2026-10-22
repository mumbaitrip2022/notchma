import CoreGraphics
import SwiftUI

/// Pixel art for the notch pet: a round little kitty with pink ears and cheeks
/// and a tail. Everything is built from parts so every mood, outfit and frame
/// comes from one template.
///
/// 16 × 16 grid: 3 rows of headroom for accessories and hops, then a 13-row body.
/// The body is 14 wide; the 2 columns behind it hold the tail.
enum PetSprite {
    static let width = 16
    static let height = 16
    private static let bodyTop = 3
    private static let bodyX = 2

    /// `blush` is drawn in the accent color (pink) where there is one, else like `dim`.
    enum Ink: UInt8 { case none = 0, full, dim, blush }

    /// Soft pink for ears, cheeks, tongue and hearts.
    static let blushColor = Color(red: 1.0, green: 0.55, blue: 0.70)

    enum Eyes: Equatable { case open(dx: Int), closed, happy, sleepy, shades, wide, love, wink, blink }
    enum Mouth: Equatable { case small, open, smile, flat, blep }
    enum Feet: Equatable { case stand, stepA, stepB, tucked }
    enum Tail: Equatable { case up, curl, down }
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
        var blush = false        // big rosy cheeks
        var squash = false       // sleeping loaf: one row shorter
        var outfit: Outfit = .none
        var egg = false
        var flip = false         // face left
        var tail: Tail = .up
    }

    /// Row-major grid, `height` rows of `width` pixels.
    static func render(_ p: Pose) -> [[Ink]] {
        var g = Array(repeating: Array(repeating: Ink.none, count: width), count: height)
        if p.egg { drawEgg(&g, p); return g }

        var rows = bodyRows(p)
        let top = bodyTop + (p.squash ? 1 : 0)
        if p.squash { rows.remove(at: 4) } // loaf: drop a head row
        stamp(&g, rows.map { String($0) }, x: bodyX, y: top)

        // A short tail behind the body (rows are body rows; the loaf keeps rows 5+ in place).
        let cells: [(Int, Int)]
        switch p.squash ? .down : p.tail {
        case .up:   cells = [(6, 0), (7, 1)]
        case .curl: cells = [(7, 0), (8, 1)]
        case .down: cells = [(11, 2), (11, 3)]
        }
        for (r, c) in cells { g[bodyTop + r][c] = .full }

        switch p.outfit {
        case .none: break
        case .sprout:
            stamp(&g, ["......#.##....", ".......##.....", ".......#......", ".......#......", ".......#......"],
                  x: bodyX, y: top - 2)
        case .headphones:
            stamp(&g, ["...########...", "..............", "..............", ".#..........#.", "##..........##"],
                  x: bodyX, y: top)
        case .crown:
            stamp(&g, ["....#.##.#....", "....######....", "....######...."], x: bodyX, y: top)
        }
        if p.flip { g = g.map { $0.reversed() } }
        return g
    }

    /// The 14 × 13 body: pointy ears, round head, face, little feet.
    private static func bodyRows(_ p: Pose) -> [[Character]] {
        let up = p.ears && !p.squash
        var r: [[Character]] = [
            up ? "..#........#.." : "..............",
            up ? "..#P......P#.." : "..............",
            up ? "..#P#....#P#.." : ".##........##.",
            "..##########..",
            ".############.",
            "##############",
            "##############",
            "##############",
            "##############",
            "##############",
            ".############.",
            "..##########..",
            feetRow(p.squash ? .tucked : p.feet),
        ].map { Array($0) }

        // Face rows: eyes 6 and 7, cheeks and mouth 8 and 9. Kept simple: dark dots on white.
        func set(_ row: Int, _ cols: [Int], _ ch: Character = ".") {
            for c in cols where c >= 0 && c < 14 { r[row][c] = ch }
        }

        switch p.eyes {
        case let .open(dx):
            let d = max(-1, min(1, dx))
            for row in 6...7 { set(row, [3 + d, 4 + d, 9 + d, 10 + d]) }
        case .blink, .sleepy:
            set(7, [3, 4, 9, 10])
        case .closed:   // ‿ ‿
            set(6, [2, 5, 8, 11]); set(7, [3, 4, 9, 10])
        case .happy:    // ^ ^
            set(6, [3, 4, 9, 10]); set(7, [2, 5, 8, 11])
        case .wide:
            for row in 5...7 { set(row, [3, 4, 9, 10]) }
        case .shades:
            for row in 6...7 { set(row, [2, 3, 4, 5, 8, 9, 10, 11]) }
            set(6, [6, 7])
        case .love:     // ♥ ♥
            set(5, [1, 2, 4, 5, 8, 9, 11, 12]); set(6, [1, 2, 3, 4, 5, 8, 9, 10, 11, 12])
            set(7, [2, 3, 4, 9, 10, 11]); set(8, [3, 10])
        case .wink:
            for row in 6...7 { set(row, [3, 4]) }
            set(6, [9, 10]); set(7, [8, 11])
        }

        // Pink cheeks beside the mouth; two rows when blushing.
        for row in p.blush ? [8, 9] : [8] {
            for c in [1, 2, 11, 12] where r[row][c] == "#" { r[row][c] = "P" }
        }

        switch p.mouth {
        case .small: set(8, [5, 8]); set(9, [6, 7])
        case .smile: set(8, [5, 8]); set(9, [6, 7])
        case .open:  set(8, [6, 7]); set(9, [6, 7], "P")
        case .flat:  set(8, [6, 7]); set(9, [5, 8])
        case .blep:  set(8, [5, 6, 7, 8]); set(9, [7], "P")
        }
        return r
    }

    private static func feetRow(_ f: Feet) -> String {
        switch f {
        case .stand:  return "...##....##..."
        case .stepA:  return "..##.....##..."
        case .stepB:  return "...##.....##.."
        case .tucked: return "...########..."
        }
    }

    private static func drawEgg(_ g: inout [[Ink]], _ p: Pose) {
        var rows = ["....######....", "...########...", "..##########..", "..##########..",
                    ".############.", ".############.", ".############.", ".############.",
                    ".############.", "..##########..", "...########..."]
        // Eyes peek out of the shell, with rosy cheeks.
        switch p.eyes {
        case .closed, .sleepy, .blink: rows[5] = ".###..##..###."
        case let .open(dx):
            var r = Array(rows[4]), s = Array(rows[5])
            for c in [4, 5, 8, 9] { r[c + max(-1, min(1, dx))] = "."; s[c + max(-1, min(1, dx))] = "." }
            rows[4] = String(r); rows[5] = String(s)
        default:
            rows[4] = ".###.####.###."; rows[5] = ".##.#.##.#.##."
        }
        rows[6] = ".#P########P#."
        rows[8] = ".####.##.####." // crack
        stamp(&g, rows, x: 1, y: bodyTop + 2)
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
                case "P": g[gy][gx] = .blush
                default: break
                }
            }
        }
    }

    // MARK: particles

    enum ParticleKind: Equatable { case heart, z, sparkle, cookie, crumb, note, gift }

    /// `#` ink, `+` dim, `P` pink.
    static func particle(_ k: ParticleKind) -> [String] {
        switch k {
        case .heart:   return [".P.P.", "PPPPP", ".PPP.", "..P.."]
        case .z:       return ["###", ".#.", "###"]
        case .sparkle: return [".#.", "#+#", ".#."]
        case .cookie:  return [".##.", "#+##", "##+#", ".##."]
        case .crumb:   return ["#"]
        case .note:    return [".##", ".#.", "##."]
        case .gift:    return ["PP.PP", ".PPP.", "#####", "##+##", "##+##"]
        }
    }
}
