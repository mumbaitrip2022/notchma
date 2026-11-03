import Foundation

/// The road from level 1 to 50: what each milestone unlocks and how the pet looks at a level.
enum PetLook {
    struct Unlock: Equatable {
        let level: Int
        let name: String        // "a wizard hat"
        let emoji: String
        var outfit: PetSprite.Outfit? = nil
        var gear: PetSprite.Gear = []
    }

    static let unlocks: [Unlock] = [
        Unlock(level: 3, name: "a sprout", emoji: "🌱", outfit: .sprout),
        Unlock(level: 6, name: "headphones", emoji: "🎧", outfit: .headphones),
        Unlock(level: 10, name: "the crown", emoji: "👑", outfit: .crown),
        Unlock(level: 15, name: "a little bow", emoji: "🎀", gear: .bow),
        Unlock(level: 20, name: "a wizard hat", emoji: "🪄", outfit: .wizard),
        Unlock(level: 25, name: "a halo", emoji: "😇", outfit: .halo),
        Unlock(level: 30, name: "rocket boots", emoji: "🚀", gear: .boots),
        Unlock(level: 35, name: "a sparkle trail", emoji: "✨", gear: .trail),
        Unlock(level: 40, name: "a glow up aura", emoji: "🌸", gear: .aura),
        Unlock(level: 45, name: "shooting stars", emoji: "🌠", gear: .shooting),
        Unlock(level: 50, name: "the golden crown", emoji: "🌟", outfit: .goldCrown, gear: .orbit),
    ]

    static let maxLevel = 50

    static func unlock(at level: Int) -> Unlock? { unlocks.first { $0.level == level } }
    static func next(after level: Int) -> Unlock? { unlocks.first { $0.level > level } }

    /// Everything extra the pet has at this level. They stack.
    static func gear(level: Int) -> PetSprite.Gear {
        unlocks.filter { $0.level <= level }.reduce(into: []) { $0.formUnion($1.gear) }
    }

    /// The hat you picked if it's unlocked, else the newest one.
    static func outfit(level: Int, wear: PetSprite.Outfit?) -> PetSprite.Outfit {
        if let w = wear, w.unlockLevel <= level { return w }
        return .forLevel(level)
    }

    /// Hats in the order you unlock them, "no hat" first.
    static let hats: [PetSprite.Outfit] = PetSprite.Outfit.allCases

    /// How big a level up party is: 0 at the start, 10 at level 50.
    static func tier(_ level: Int) -> Int { max(0, min(10, level / 5)) }

    /// The banner line for reaching a level.
    static func levelUpLine(_ level: Int) -> String {
        if level == maxLevel { return "ASCENDED. golden crown and orbiting stars" }
        if let u = unlock(at: level) {
            switch u.level {
            case 10: return "unlocked the crown 👑 royalty behavior"
            case 25: return "unlocked a halo 😇 an angel who ships"
            case 30: return "unlocked rocket boots 🚀 watch it hop"
            default: return "unlocked \(u.name) \(u.emoji)"
            }
        }
        if let n = next(after: level) {
            let left = n.level - level
            return left == 1 ? "one more level to \(n.name) \(n.emoji)" : "\(left) levels to \(n.name) \(n.emoji)"
        }
        return "past level 50. it's just showing off now ✨"
    }

    /// The card's "what's next" line.
    static func nextLine(_ level: Int) -> String {
        if level == 0 { return "hatches when a task finishes 🐣" }
        guard let n = next(after: level) else { return "fully ascended. just vibes now 🌟" }
        return "lvl \(n.level) unlocks \(n.name) \(n.emoji)"
    }

    /// Streak days that get a banner.
    static let streakMilestones = [7, 14, 30, 50, 100, 200, 365]

    static func streakLine(_ days: Int) -> (title: String, sub: String) {
        switch days {
        case 7: return ("one week streak 😎", "shades on. it's that kind of week")
        case 14: return ("two week streak 🔥", "the flame is alive now. keep it fed")
        case 30: return ("30 day streak ✨", "golden flame unlocked. that's a whole month")
        case 50: return ("50 day streak 🔥", "half a century of shipping days")
        case 100: return ("100 day streak 💯", "century club. it's doing its victory dance")
        case 365: return ("365 day streak 🎂", "a full year. you are the main character")
        default: return ("\(days) day streak 🔥", "unreal consistency. keep going")
        }
    }
}
