import AppKit
import Combine

/// The pet's little mind: what it's doing, where it stands, and the frame to draw.
///
/// Runs at 4 fps while awake and 1 fps while dozing, only while some view shows it.
/// After a minute of dozing it falls into a deep sleep and stops ticking entirely,
/// and it also stops when the displays sleep. Frames go straight to `PetLayerView`
/// through `frames`, never through SwiftUI, so a tick costs a few microseconds.
final class PetBrain: ObservableObject {
    struct Particle: Equatable {
        var kind: PetSprite.ParticleKind
        var x: Double, y: Double       // pet pixels, relative to the sprite's top-left
        var vx: Double = 0, vy: Double = 0
        var life: Int                  // ticks left
        var tint = 0                   // confetti and star colors
        var world = false              // stays where it was dropped while the pet walks on
    }

    struct Frame: Equatable {
        var pose = PetSprite.Pose()
        var x = 0                      // pet pixels from the stage's left edge
        var lift = 0                   // pixels above the ground (jumps, bobs)
        var particles: [Particle] = []
    }

    enum Mood: Equatable { case egg, happy, content, hungry, sleepy }

    /// The frame on screen now. Changes are sent on `frames`; views that only need
    /// `lastPrinted` don't redraw on every tick.
    private(set) var frame = Frame() {
        didSet { frames.send(frame) }
    }
    let frames = PassthroughSubject<Frame, Never>()
    /// Set by the hero view while the receipt prints.
    var printing = false
    /// A new NotchBar version is waiting: the pet carries a little gift box.
    var hasGift = false {
        didSet { if hasGift != oldValue { lastStimulus = Date(); if case .sleep = act { start(.yawn) } } }
    }
    /// Stand still (the big pet on the printer) instead of wandering.
    var stayPut = false
    /// Receipt signature last printed, so it only prints again when something changed.
    @Published var lastPrinted = ""
    /// Changes only when the mood does (asleep, fed, hungry), so the mood line can refresh.
    @Published private(set) var shownMood: Mood = .content
    /// Where the pointer is relative to the pet (-1 left, 0 centered, 1 right), nil when unknown.
    var lookAt: Int?

    var level: () -> Int = { 1 }
    var lastFedAt: () -> Date? = { nil }
    var streak: () -> Int = { 0 }
    /// The hat you picked in the wardrobe (nil: the newest one).
    var wear: () -> PetSprite.Outfit? = { nil }
    /// Try on a look for a moment (a level and a hat), from the wardrobe.
    var preview: (level: Int, outfit: PetSprite.Outfit)? {
        didSet {
            guard preview?.level != oldValue?.level || preview?.outfit != oldValue?.outfit else { return }
            poke()
            if viewers > 0 { step() }
        }
    }

    private enum Act: Equatable {
        case sit, walk(to: Int), sleep, yawn, eat(cookieY: Double, chomps: Int), party, petted, wobble
        // Level and streak celebrations: a spin, a big jump and fireworks; a little dance.
        case tada(big: Bool), dance
        // Little idle fidgets.
        case hop, blep, wag, curious
    }
    private var act: Act = .sit
    private var actTicks = 0
    private var x = 40
    private var facingLeft = false
    private var stageWidth = 100
    private var tick = 0
    private var lastStimulus = Date()
    private var pendingTreats = 0
    private var particles: [Particle] = []
    private var lastLift = 0
    /// Confetti to add to the next plain party (bigger at higher levels).
    private var partyConfetti = 0
    private var timer: Timer?
    private var viewers = 0
    private var displaysAsleep = false
    private var rng = SystemRandomNumberGenerator()
    private var bag = Set<AnyCancellable>()
    // Slow facts, refreshed once a minute instead of every tick.
    private var cachedStreak = 0
    private var cachedNight = false
    private var factsAt = Date.distantPast
    /// Ticks of dozing before the deep sleep (no timer at all).
    static let deepSleepTicks = 60

    init() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.publisher(for: NSWorkspace.screensDidSleepNotification).sink { [weak self] _ in
            self?.displaysAsleep = true; self?.reschedule()
        }.store(in: &bag)
        ws.publisher(for: NSWorkspace.screensDidWakeNotification).sink { [weak self] _ in
            self?.displaysAsleep = false; self?.reschedule()
        }.store(in: &bag)
    }

    var mood: Mood {
        if level() == 0 { return .egg }
        if case .sleep = act { return .sleepy }
        if let fed = lastFedAt(), Date().timeIntervalSince(fed) < 8 * 3600 {
            return Date().timeIntervalSince(fed) < 20 * 60 ? .happy : .content
        }
        return .hungry
    }

    var moodLine: String {
        switch mood {
        case .egg: return "still an egg 🥚 warm and cozy"
        case .happy: return "just ate. vibing 😌"
        case .content: return "chilling, well fed"
        case .hungry: return "kinda hungry. feed it a prompt 🍪"
        case .sleepy: return "sleeping. shh 💤"
        }
    }

    // MARK: visibility

    func appeared(stageWidth w: Int? = nil, hidden: Int = 0) {
        if let w { setStage(w, hidden: hidden) }
        viewers += 1
        reschedule()
    }

    func disappeared() {
        viewers = max(0, viewers - 1)
        reschedule()
    }

    func setStage(_ w: Int, hidden: Int = 0) {
        guard w > PetSprite.width else { return }
        stageWidth = w
        // A hardware notch hides the middle of the stage: the pet may walk behind it, never rest there.
        if hidden > 0 {
            let mid = w / 2
            blocked = (mid - hidden / 2 - PetSprite.width + 1)...(mid + hidden / 2 - 1)
        } else {
            blocked = nil
        }
        x = min(max(0, x), w - PetSprite.width)
        if let b = blocked, b.contains(x) { x = x - b.lowerBound < b.upperBound - x ? max(0, b.lowerBound - 1) : min(w - PetSprite.width, b.upperBound + 1) }
    }

    /// Left edges where the pet would be hidden behind the camera.
    private var blocked: ClosedRange<Int>?

    private func randomSpot() -> Int {
        let maxX = max(0, stageWidth - PetSprite.width)
        for _ in 0..<12 {
            let t = Int.random(in: 0...maxX, using: &rng)
            if blocked?.contains(t) != true { return t }
        }
        return x
    }

    // MARK: stimuli

    /// Something happened (you hovered, an agent did something): wake up.
    func poke() {
        lastStimulus = Date()
        if case .sleep = act { start(.yawn) }
    }

    /// A task finished: a cookie drops in next time the pet is on screen.
    func feed() {
        pendingTreats = min(pendingTreats + 1, 3)
        lastStimulus = Date()
        if viewers > 0 { serveTreat() }
    }

    /// You clicked the pet.
    func pet() {
        lastStimulus = Date()
        if level() == 0 { start(.wobble); return }
        start(.petted)
        burst(.heart, count: 3)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    func party() {
        lastStimulus = Date()
        start(.party)
        burst(.sparkle, count: 3)
    }

    /// Reached a level: a party that grows with the level, and a big show on unlocks.
    func celebrate(level: Int) {
        lastStimulus = Date()
        let tier = PetLook.tier(level)
        if PetLook.unlock(at: level) != nil {
            start(.tada(big: level >= PetLook.maxLevel))
        } else {
            partyConfetti = tier * 2
            start(.party)
            burst(.sparkle, count: 3 + tier / 3)
        }
    }

    /// A streak milestone: a dance on the big ones, a party otherwise.
    func celebrate(streak days: Int) {
        lastStimulus = Date()
        if days >= 100 { start(.dance) } else { partyConfetti = min(days / 3, 16); start(.party); burst(.heart, count: 2) }
    }

    #if DEBUG
    func debugSleep() { lastStimulus = .distantPast; start(.sleep) }
    func debugStep(_ n: Int) { for _ in 0..<n { step() } }
    var isTicking: Bool { timer != nil }
    #endif

    // MARK: loop

    private func reschedule(immediate: Bool = true) {
        timer?.invalidate()
        timer = nil
        guard viewers > 0, !displaysAsleep else { return }
        let asleep = act == .sleep
        if asleep && actTicks >= Self.deepSleepTicks { return }   // deep sleep: woken by poke()
        let t = Timer(timeInterval: asleep ? 1.0 : (isFast ? Self.fastTick : 0.25), repeats: true) { [weak self] _ in self?.step() }
        t.tolerance = asleep ? 0.2 : 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
        guard immediate else { return }
        if pendingTreats > 0 { serveTreat() }
        step()
    }

    /// Celebrations run at 10 fps so the fireworks and confetti move smoothly.
    private static let fastTick = 0.1
    private var isFast: Bool { if case .tada = act { return true }; return false }

    private func start(_ a: Act) {
        let wasAsleep = act == .sleep, wasFast = isFast
        act = a
        actTicks = 0
        if wasAsleep != (a == .sleep) || wasFast != isFast { reschedule(immediate: false) }
    }

    private func serveTreat() {
        guard pendingTreats > 0, level() > 0 else { return }
        switch act { case .eat, .party: return; default: break }
        pendingTreats -= 1
        start(.eat(cookieY: -8, chomps: 0))
    }

    private func step() {
        tick += 1
        actTicks += 1
        let idleFor = Date().timeIntervalSince(lastStimulus)
        if Date().timeIntervalSince(factsAt) > 60 {
            factsAt = Date()
            cachedStreak = streak()
            let hour = Calendar.current.component(.hour, from: Date())
            cachedNight = hour >= 1 && hour < 6
        }
        let night = cachedNight
        var pose = PetSprite.Pose()
        let lvl = preview?.level ?? level()
        let gear = PetLook.gear(level: lvl)
        pose.outfit = preview?.outfit ?? PetLook.outfit(level: lvl, wear: wear())
        pose.gear = gear.intersection([.scarf, .boots, .aura, .orbit])
        pose.phase = tick
        pose.egg = lvl == 0
        let oldX = x
        let hungry = mood == .hungry
        var lift = 0

        if printing, act != .sleep { act = .party }

        switch act {
        case .sit:
            pose.eyes = blinkOr(lookEyes())
            pose.ears = !hungry
            // A slow, lazy tail sway.
            pose.tail = (tick / 6) % 3 == 2 ? .curl : .up
            if hungry { pose.eyes = blinkOr(.sleepy); pose.mouth = .flat; pose.tail = .down }
            if pose.egg {
                // Eggs wobble now and then.
                if actTicks % 24 < 4 { start(.wobble) }
            } else if actTicks > 8 {
                let roll = Int.random(in: 0..<(hungry ? 60 : 24), using: &rng)
                if roll == 0 && !stayPut {
                    let target = randomSpot()
                    if abs(target - x) > 6 { start(.walk(to: target)) }
                } else if roll == 1 && !hungry {
                    start([.hop, .blep, .wag, .curious, .wag].randomElement(using: &rng) ?? .wag)
                }
            }
            if idleFor > (night ? 45 : 150) { start(.sleep) }

        case let .walk(target):
            let speed = hungry ? 1 : (actTicks % 3 == 0 ? 2 : 1)
            facingLeft = target < x
            x += target > x ? min(speed, target - x) : -min(speed, x - target)
            pose.feet = tick % 2 == 0 ? .stepA : .stepB
            lift = tick % 2
            pose.eyes = .open(dx: facingLeft ? -1 : 1)
            pose.ears = !hungry
            pose.tail = hungry ? .down : (tick % 4 < 2 ? .up : .curl)
            if hungry { pose.mouth = .flat }
            // Level 35: sparkles left behind on the ground.
            if gear.contains(.trail) && tick % 2 == 0 {
                spawn(.star, x: facingLeft ? 13 : 1, y: Double.random(in: 11...14, using: &rng), vy: -0.15, life: 6,
                      tint: Int.random(in: 0...2, using: &rng), world: true)
            }
            // Hums a little tune on a full belly.
            if mood == .happy && tick % 10 == 0 {
                spawn(.note, x: facingLeft ? 1 : 13, y: 3, vx: facingLeft ? -0.3 : 0.3, vy: -0.5, life: 5)
            }
            if x == target || actTicks > 120 { start(.sit) }

        case .sleep:
            pose.eyes = .closed
            pose.squash = true
            pose.ears = false
            if idleFor < 5 { start(.yawn) }
            else if actTicks >= Self.deepSleepTicks {
                // Deep sleep: one still "z" above the head, then no more ticks until something wakes it.
                particles = [Particle(kind: .z, x: 14, y: 7, life: 3)]   // ages to 2 below (a soft z), then stays put
                timer?.invalidate()
                timer = nil
            } else if tick % 3 == 0 { spawn(.z, x: 14, y: 9, vx: 0.4, vy: -0.6, life: 6) }

        case .yawn:
            pose.eyes = actTicks < 5 ? .closed : .blink
            pose.mouth = actTicks < 5 ? .open : .small
            pose.ears = actTicks > 2
            pose.tail = actTicks < 4 ? .down : .curl
            lift = actTicks == 5 || actTicks == 6 ? 1 : 0     // a little stretch
            if actTicks > 7 { start(.sit) }

        case let .eat(cookieY, chomps):
            pose.eyes = .wide
            pose.tail = tick % 2 == 0 ? .up : .curl
            let mouthY = 7.0
            if cookieY < mouthY - 3 {
                pose.mouth = .open
                act = .eat(cookieY: cookieY + 2, chomps: chomps)
                particles.removeAll { $0.kind == .cookie }
                particles.append(Particle(kind: .cookie, x: facingLeft ? 5 : 7, y: cookieY + 2, life: 2))
            } else if chomps < 6 {
                pose.mouth = chomps % 2 == 0 ? .open : .small
                pose.eyes = .happy
                pose.blush = true
                pose.tail = chomps % 2 == 0 ? .up : .curl
                particles.removeAll { $0.kind == .cookie }
                if chomps % 2 == 0 {
                    spawn(.crumb, x: Double.random(in: 4...11, using: &rng), y: 12, vx: Double.random(in: -0.6...0.6, using: &rng), vy: -0.6, life: 3)
                }
                act = .eat(cookieY: cookieY, chomps: chomps + 1)
            } else {
                start(.party)
                burst(.heart, count: 2)
            }

        case .party:
            pose.eyes = actTicks % 8 < 6 ? .happy : .love
            pose.blush = true
            lift = actTicks % 4 < 2 ? 2 : 0
            pose.mouth = actTicks < 4 ? .blep : (lift > 0 ? .open : .smile)
            pose.feet = lift > 0 ? .tucked : .stand
            pose.tail = tick % 2 == 0 ? .up : .curl
            if actTicks % 6 == 0 { spawn(.sparkle, x: Double.random(in: -2...12, using: &rng), y: 2, vy: -0.4, life: 4) }
            if actTicks == 1 && partyConfetti > 0 { confetti(partyConfetti, speed: 0.4); partyConfetti = 0 }
            if !printing && actTicks > 14 { start(.sit) }

        case let .tada(big):
            // 10 fps: crouch, spin up into a big jump, fireworks at the top, then a happy bounce.
            let t = actTicks
            switch t {
            case ..<6:
                pose.eyes = .wide; pose.mouth = .small; pose.squash = t >= 2; pose.ears = true
                pose.tail = .up
            case 6..<14:
                if t % 2 == 0 { facingLeft.toggle() }
                lift = [1, 2, 3, 3, 4, 4, 4, 4][t - 6]
                pose.eyes = .happy; pose.mouth = .open; pose.feet = .tucked; pose.tail = .curl
                if t == 6 { haptic() }
            case 14..<24:
                lift = [4, 4, 4, 3, 3, 2, 2, 1, 0, 0][t - 14]
                pose.eyes = .love; pose.mouth = .open; pose.blush = true; pose.feet = .tucked
                if t == 14 { fireworks(at: -3, 6); fireworks(at: 19, 6); confetti(big ? 22 : 14, speed: 1); haptic() }
            default:
                let b = (t - 24) % 8
                lift = b < 2 ? 0 : b < 4 ? 2 : b < 6 ? 1 : 0
                pose.eyes = (t / 6) % 3 == 2 ? .love : .happy
                pose.mouth = lift > 0 ? .open : .smile
                pose.blush = true
                pose.feet = lift > 0 ? .tucked : .stand
                pose.tail = t % 4 < 2 ? .up : .curl
                if big && t == 34 { fireworks(at: -4, 4); fireworks(at: 20, 8); haptic() }
                if big && t == 48 { fireworks(at: 20, 3); fireworks(at: -4, 8); confetti(16, speed: 1) }
                if t > (big ? 70 : 44) { start(.sit) }
            }

        case .dance:
            // Side steps, a turn each beat, notes flying. Ends in the big jump.
            let beat = actTicks / 2
            facingLeft = beat % 4 >= 2
            lift = actTicks % 2 == 0 ? 1 : 0
            pose.feet = actTicks % 2 == 0 ? .stepA : .stepB
            pose.eyes = beat % 6 == 5 ? .wink : .happy
            pose.mouth = .smile
            pose.blush = true
            pose.tail = actTicks % 2 == 0 ? .up : .curl
            x += beat % 4 < 2 ? 1 : -1
            if actTicks % 3 == 0 { spawn(.note, x: Double.random(in: 0...14, using: &rng), y: 2, vx: 0.2, vy: -0.5, life: 5) }
            if actTicks > 32 { start(.tada(big: true)) }

        case .petted:
            // Melts: heart eyes, rosy cheeks, a happy wiggle, then a wink.
            pose.eyes = actTicks < 7 ? .love : actTicks < 10 ? .wink : .happy
            pose.mouth = actTicks < 7 ? .open : .smile
            pose.blush = true
            pose.tail = tick % 2 == 0 ? .up : .curl
            lift = actTicks < 6 && actTicks % 3 == 1 ? 1 : 0
            pose.feet = lift > 0 ? .tucked : .stand
            if actTicks == 4 { spawn(.heart, x: 6, y: 0, vy: -0.7, life: 6) }
            if actTicks > 12 { start(.sit) }

        case .hop:
            // Two bouncy hops.
            let h = [1, 2, 2, 1, 0, 1, 2, 2, 1, 0]
            lift = actTicks < h.count ? h[actTicks] : 0
            pose.eyes = .happy
            pose.mouth = lift > 0 ? .open : .smile
            pose.feet = lift > 0 ? .tucked : .stand
            pose.tail = lift > 0 ? .up : .curl
            if actTicks == 2 || actTicks == 7 { spawn(.sparkle, x: facingLeft ? 0 : 14, y: 4, vy: -0.3, life: 3) }
            if actTicks >= h.count { start(.sit) }

        case .blep:
            // Forgot its tongue out. Blinks about it.
            pose.eyes = actTicks == 5 ? .blink : .open(dx: 0)
            pose.mouth = .blep
            pose.tail = (actTicks / 3) % 2 == 0 ? .up : .curl
            if actTicks > 10 { start(.sit) }

        case .wag:
            pose.eyes = actTicks < 3 ? lookEyes() : .happy
            pose.mouth = .smile
            pose.blush = actTicks > 3
            pose.tail = tick % 2 == 0 ? .up : .curl
            if actTicks > 9 { start(.sit) }

        case .curious:
            // Looks one way, then the other, ears up, then back.
            let phase = actTicks / 3
            pose.eyes = phase == 2 ? .blink : .wide
            if phase == 1 { facingLeft = true } else if phase == 3 { facingLeft = false }
            pose.mouth = .small
            pose.tail = .up
            if actTicks > 13 { start(.sit) }

        case .wobble:
            pose.eyes = .open(dx: actTicks % 2 == 0 ? -1 : 1)
            x += actTicks % 2 == 0 ? 1 : -1
            if actTicks >= 4 { start(.sit) }
        }

        // Shades for a week-long streak (when the eyes are plain open).
        if cachedStreak >= 7, case .open = pose.eyes, !pose.egg { pose.eyes = .shades }
        pose.flip = facingLeft && !pose.egg
        x = min(max(0, x), max(0, stageWidth - PetSprite.width))

        // Rocket boots: flames while it's up, little puffs when it lands.
        if gear.contains(.boots) && !pose.egg {
            pose.flying = lift > 0
            if lastLift > 0 && lift == 0 {
                spawn(.puff, x: 3, y: 14, vx: -0.35, vy: -0.1, life: 4)
                spawn(.puff, x: 12, y: 14, vx: 0.35, vy: -0.1, life: 4)
            }
        }
        lastLift = lift

        // Level 45: now and then a shooting star crosses the notch.
        if gear.contains(.shooting) && !pose.egg && Int.random(in: 0..<(isFast ? 400 : 170), using: &rng) == 0 {
            let dir: Double = Bool.random(using: &rng) ? 1 : -1
            let from = stayPut ? Double.random(in: -6...18, using: &rng)
                : Double(Int.random(in: 0...max(1, stageWidth), using: &rng) - x)
            spawn(.shooting, x: from, y: Double.random(in: -1...1.5, using: &rng), vx: dir * 2.4, vy: 0.55, life: 7, world: true)
        }

        let moved = Double(x - oldX)
        particles = particles.compactMap { p in
            var p = p
            if p.world { p.x -= moved }
            p.x += p.vx; p.y += p.vy; p.life -= 1
            switch p.kind {
            case .crumb: p.vy += 0.5
            case .confetti: p.vy = min(p.vy + 0.12, 0.7); p.vx *= 0.93
            case .star where !p.world: p.vx *= 0.82; p.vy = p.vy * 0.82 + 0.03
            default: break
            }
            return p.life > 0 ? p : nil
        }
        var shown = particles
        if hasGift && !pose.egg {
            // The present sits on the ground next to the pet, on the side it faces.
            shown.append(Particle(kind: .gift, x: facingLeft ? -6 : Double(PetSprite.width + 1), y: 16 + Double(lift), life: 1))
        }
        let next = Frame(pose: pose, x: x, lift: lift, particles: shown)
        if next != frame { frame = next }
        let m = mood
        if m != shownMood { shownMood = m }
    }

    private func lookEyes() -> PetSprite.Eyes {
        if let l = lookAt { return .open(dx: l) }
        // Glance around now and then.
        let phase = (tick / 12) % 5
        return .open(dx: phase == 1 ? -1 : phase == 3 ? 1 : 0)
    }

    private func blinkOr(_ e: PetSprite.Eyes) -> PetSprite.Eyes {
        // A blink every few seconds, sometimes a double blink.
        let t = tick % 23
        return t == 0 || (tick % 69 == 2 && t == 2) ? .blink : e
    }

    private func spawn(_ k: PetSprite.ParticleKind, x: Double, y: Double, vx: Double = 0, vy: Double = 0, life: Int,
                       tint: Int = 0, world: Bool = false, cap: Int = 10) {
        guard particles.count < cap else { return }
        particles.append(Particle(kind: k, x: x, y: y, vx: vx, vy: vy, life: life, tint: tint, world: world))
    }

    /// A ring of gold and pink stars bursting out from a point (pet pixels).
    private func fireworks(at cx: Double, _ cy: Double) {
        for i in 0..<10 {
            let a = Double(i) / 10 * 2 * .pi
            spawn(.star, x: cx + cos(a), y: cy + sin(a), vx: cos(a) * 1.0, vy: sin(a) * 0.8, life: 9,
                  tint: i % 3 == 0 ? 2 : 0, cap: 48)
        }
    }

    /// Confetti raining down over the pet. `speed` 1 at 10 fps, lower for 4 fps parties.
    private func confetti(_ n: Int, speed: Double) {
        for i in 0..<n {
            spawn(.confetti, x: Double.random(in: -6...20, using: &rng), y: Double.random(in: 0...5, using: &rng),
                  vx: Double.random(in: -0.6...0.6, using: &rng) / speed, vy: Double.random(in: -0.9...0, using: &rng),
                  life: Int((Double.random(in: 14...24, using: &rng) * speed).rounded()) + 4, tint: i % 3, cap: 48)
        }
    }

    private func haptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    private func burst(_ k: PetSprite.ParticleKind, count: Int) {
        for i in 0..<count {
            spawn(k, x: Double(1 + i * 5), y: 2 - Double(i % 2), vx: i % 2 == 0 ? -0.3 : 0.3, vy: -0.6, life: 7)
        }
    }
}
