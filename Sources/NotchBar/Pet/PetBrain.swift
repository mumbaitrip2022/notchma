import AppKit
import Combine

/// The pet's little mind: what it's doing, where it stands, and the frame to draw.
///
/// Runs at 4 fps while awake and 1 fps asleep, only while some view shows it,
/// and stops entirely when the displays sleep. Low frame rates are on purpose:
/// it reads as an old LCD pet and costs next to nothing.
final class PetBrain: ObservableObject {
    struct Particle: Equatable {
        var kind: PetSprite.ParticleKind
        var x: Double, y: Double       // pet pixels, relative to the sprite's top-left
        var vx: Double = 0, vy: Double = 0
        var life: Int                  // ticks left
    }

    struct Frame: Equatable {
        var pose = PetSprite.Pose()
        var x = 0                      // pet pixels from the stage's left edge
        var lift = 0                   // pixels above the ground (jumps, bobs)
        var particles: [Particle] = []
    }

    enum Mood: Equatable { case egg, happy, content, hungry, sleepy }

    @Published private(set) var frame = Frame()
    /// Set by the hero view while the receipt prints.
    var printing = false
    /// A new NotchBar version is waiting: the pet carries a little gift box.
    var hasGift = false {
        didSet { if hasGift != oldValue { lastStimulus = Date(); if case .sleep = act { start(.yawn) } } }
    }
    /// Stand still (the big pet on the printer) instead of wandering.
    var stayPut = false
    /// Receipt signature last printed, so it only prints again when something changed.
    var lastPrinted = ""
    /// Where the pointer is relative to the pet (-1 left, 0 centered, 1 right), nil when unknown.
    var lookAt: Int?

    var level: () -> Int = { 1 }
    var lastFedAt: () -> Date? = { nil }
    var streak: () -> Int = { 0 }

    private enum Act: Equatable {
        case sit, walk(to: Int), sleep, yawn, eat(cookieY: Double, chomps: Int), party, petted, wobble
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
    private var timer: Timer?
    private var viewers = 0
    private var displaysAsleep = false
    private var rng = SystemRandomNumberGenerator()
    private var bag = Set<AnyCancellable>()

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
        start(.petted)
        burst(.heart, count: 2)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    func party() {
        lastStimulus = Date()
        start(.party)
        burst(.sparkle, count: 3)
    }

    #if DEBUG
    func debugSleep() { lastStimulus = .distantPast; start(.sleep) }
    #endif

    // MARK: loop

    private func reschedule(immediate: Bool = true) {
        timer?.invalidate()
        timer = nil
        guard viewers > 0, !displaysAsleep else { return }
        let asleep = act == .sleep
        let t = Timer(timeInterval: asleep ? 1.0 : 0.25, repeats: true) { [weak self] _ in self?.step() }
        t.tolerance = asleep ? 0.2 : 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
        guard immediate else { return }
        if pendingTreats > 0 { serveTreat() }
        step()
    }

    private func start(_ a: Act) {
        let wasAsleep = act == .sleep
        act = a
        actTicks = 0
        if wasAsleep != (a == .sleep) { reschedule(immediate: false) }
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
        let hour = Calendar.current.component(.hour, from: Date())
        let night = hour >= 1 && hour < 6
        var pose = PetSprite.Pose()
        pose.outfit = .forLevel(level())
        pose.egg = level() == 0
        let hungry = mood == .hungry
        var lift = 0

        if printing, act != .sleep { act = .party }

        switch act {
        case .sit:
            pose.eyes = blinkOr(lookEyes())
            pose.ears = !hungry
            if hungry { pose.eyes = blinkOr(.sleepy); pose.mouth = .flat }
            if pose.egg {
                // Eggs wobble now and then.
                if actTicks % 24 < 4 { start(.wobble) }
            } else if !stayPut && actTicks > 8 && Int.random(in: 0..<(hungry ? 40 : 14), using: &rng) == 0 {
                let target = randomSpot()
                if abs(target - x) > 6 { start(.walk(to: target)) }
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
            if x == target || actTicks > 120 { start(.sit) }

        case .sleep:
            pose.eyes = .closed
            pose.squash = true
            pose.ears = false
            if tick % 3 == 0 { spawn(.z, x: 13, y: 9, vx: 0.4, vy: -0.6, life: 6) }
            if idleFor < 5 { start(.yawn) }

        case .yawn:
            pose.eyes = .closed
            pose.mouth = actTicks < 5 ? .open : .small
            pose.ears = actTicks > 2
            if actTicks > 7 { start(.sit) }

        case let .eat(cookieY, chomps):
            pose.eyes = .open(dx: 0)
            let mouthY = 7.0
            if cookieY < mouthY - 3 {
                pose.mouth = .open
                act = .eat(cookieY: cookieY + 2, chomps: chomps)
                particles.removeAll { $0.kind == .cookie }
                particles.append(Particle(kind: .cookie, x: 5, y: cookieY + 2, life: 2))
            } else if chomps < 6 {
                pose.mouth = chomps % 2 == 0 ? .open : .small
                pose.eyes = .happy
                particles.removeAll { $0.kind == .cookie }
                if chomps % 2 == 0 {
                    spawn(.crumb, x: Double.random(in: 3...10, using: &rng), y: 9, vx: Double.random(in: -0.6...0.6, using: &rng), vy: -0.6, life: 3)
                }
                act = .eat(cookieY: cookieY, chomps: chomps + 1)
            } else {
                start(.party)
                burst(.heart, count: 2)
            }

        case .party:
            pose.eyes = .happy
            pose.mouth = .smile
            pose.blush = true
            lift = actTicks % 4 < 2 ? 2 : 0
            pose.feet = lift > 0 ? .tucked : .stand
            if actTicks % 6 == 0 { spawn(.sparkle, x: Double.random(in: -2...12, using: &rng), y: 2, vy: -0.4, life: 4) }
            if !printing && actTicks > 14 { start(.sit) }

        case .petted:
            pose.eyes = .happy
            pose.mouth = .smile
            pose.blush = true
            lift = actTicks < 3 ? 1 : 0
            if actTicks > 8 { start(.sit) }

        case .wobble:
            pose.eyes = .open(dx: actTicks % 2 == 0 ? -1 : 1)
            x += actTicks % 2 == 0 ? 1 : -1
            if actTicks >= 4 { start(.sit) }
        }

        // Shades for a week-long streak (when the eyes are plain open).
        if streak() >= 7, case .open = pose.eyes, !pose.egg { pose.eyes = .shades }
        pose.flip = facingLeft && !pose.egg
        x = min(max(0, x), max(0, stageWidth - PetSprite.width))

        particles = particles.compactMap { p in
            var p = p
            p.x += p.vx; p.y += p.vy; p.life -= 1
            if p.kind == .crumb { p.vy += 0.5 }
            return p.life > 0 ? p : nil
        }
        var shown = particles
        if hasGift && !pose.egg {
            // The present sits on the ground next to the pet, on the side it faces.
            shown.append(Particle(kind: .gift, x: facingLeft ? -6 : 15, y: 15 + Double(lift), life: 1))
        }
        let next = Frame(pose: pose, x: x, lift: lift, particles: shown)
        if next != frame { frame = next }
    }

    private func lookEyes() -> PetSprite.Eyes {
        if let l = lookAt { return .open(dx: l) }
        // Glance around now and then.
        let phase = (tick / 12) % 5
        return .open(dx: phase == 1 ? -1 : phase == 3 ? 1 : 0)
    }

    private func blinkOr(_ e: PetSprite.Eyes) -> PetSprite.Eyes {
        tick % 17 == 0 ? .closed : e
    }

    private func spawn(_ k: PetSprite.ParticleKind, x: Double, y: Double, vx: Double = 0, vy: Double = 0, life: Int) {
        guard particles.count < 10 else { return }
        particles.append(Particle(kind: k, x: x, y: y, vx: vx, vy: vy, life: life))
    }

    private func burst(_ k: PetSprite.ParticleKind, count: Int) {
        for i in 0..<count {
            spawn(k, x: Double(2 + i * 6), y: 1, vx: i % 2 == 0 ? -0.3 : 0.3, vy: -0.6, life: 6)
        }
    }
}
