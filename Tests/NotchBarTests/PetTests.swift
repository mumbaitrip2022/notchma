import XCTest
@testable import NotchBar

final class PetTests: XCTestCase {
    private func ledger() -> DayLedger { DayLedger(persists: false) }

    func testLevelCurve() {
        XCTAssertEqual(DayLedger.level(xp: 0), 1)
        XCTAssertEqual(DayLedger.level(xp: 99), 1)
        XCTAssertEqual(DayLedger.level(xp: 100), 2)
        XCTAssertEqual(DayLedger.level(xp: 299), 2)
        XCTAssertEqual(DayLedger.level(xp: 300), 3)
        for l in 1...20 { XCTAssertEqual(DayLedger.level(xp: DayLedger.xpFor(level: l)), l) }
    }

    func testEggHatchesOnFirstTask() {
        let l = ledger()
        var changes: [(Int, Int)] = []
        l.onLevelChange = { changes.append(($0, $1)) }
        XCTAssertEqual(l.level, 0)
        l.turn(key: "a#1", agent: .claude, project: "app", receipt: TaskReceipt(duration: 120), endedAt: Date())
        XCTAssertEqual(l.level, 1)
        XCTAssertEqual(changes.first?.0, 0)
        XCTAssertEqual(changes.first?.1, 1)
    }

    func testTurnUpsertCountsOnce() {
        let l = ledger()
        let now = Date()
        l.turn(key: "s#1", agent: .claude, project: "app", receipt: TaskReceipt(duration: 60), endedAt: now)
        var r = TaskReceipt(duration: 60); r.tokens = 5000; r.costUSD = 0.4
        l.turn(key: "s#1", agent: .claude, project: "app", receipt: r, endedAt: now) // tokens arrive later
        XCTAssertEqual(l.today.tasks, 1)
        XCTAssertEqual(l.lifetime.tasks, 1)
        XCTAssertEqual(l.today.tokens, 5000)
        XCTAssertEqual(l.today.cost ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(l.streak, 1)
    }

    func testFilesAndApprovals() {
        let l = ledger()
        l.file("/a.swift"); l.file("/a.swift"); l.file("/b.swift")
        l.approval(allowed: true); l.approval(allowed: false)
        l.tests(passed: 12, failed: 1)
        XCTAssertEqual(l.today.files.count, 2)
        XCTAssertEqual(l.lifetime.files, 2)
        XCTAssertEqual(l.today.allowed, 1)
        XCTAssertEqual(l.today.denied, 1)
        XCTAssertEqual(l.today.testsPassed, 12)
    }

    func testReceiptLines() {
        let empty = ReceiptContent.make(day: DayLedger.Day(key: "2026-10-21"), number: 3, petName: "mochi", streak: 0)
        XCTAssertTrue(empty.lines.contains(.center("no orders yet today")))

        var d = DayLedger.Day(key: "2026-10-21")
        d.turns = [.init(key: "1", agent: "claude", project: "shop", duration: 3600, tokens: 1_200_000, cost: 3.5,
                         added: 1200, removed: 40, endedAt: Date())]
        d.files = ["x", "y"]
        d.testsPassed = 60
        let full = ReceiptContent.make(day: d, number: 42, petName: "mochi", streak: 4)
        XCTAssertTrue(full.lines.contains(.bold("TOTAL", "$3.50")))
        XCTAssertTrue(full.lines.contains(.row("CLAUDE CODE", "1h 00m")))
        XCTAssertTrue(full.lines.contains(.row("streak", "🔥 4 days")))
        XCTAssertEqual(full.lines.first, .title("NOTCHBAR"))
    }

    /// House style: no em or en dashes in anything the user reads.
    func testNoDashesInReceiptOrQuips() {
        var d = DayLedger.Day(key: "2026-10-21")
        d.turns = [.init(key: "1", agent: "cursor", project: "p", duration: 90, endedAt: Date())]
        d.denied = 5; d.testsFailed = 3
        let lines = ReceiptContent.make(day: d, number: 1, petName: "bao", streak: 9).lines
        let text = lines.map { "\($0)" }.joined(separator: "\n")
        XCTAssertFalse(text.contains("—"))
        XCTAssertFalse(text.contains("–"))
        let brain = PetBrain()
        brain.level = { 0 }
        XCTAssertFalse(brain.moodLine.contains("—"))
    }

    func testSpriteShapes() {
        for eyes: PetSprite.Eyes in [.open(dx: -1), .open(dx: 1), .closed, .happy, .sleepy, .shades, .wide, .love, .wink, .blink] {
            for outfit: PetSprite.Outfit in [.none, .sprout, .headphones, .crown] {
                let g = PetSprite.render(.init(eyes: eyes, outfit: outfit))
                XCTAssertEqual(g.count, PetSprite.height)
                XCTAssertTrue(g.allSatisfy { $0.count == PetSprite.width })
            }
        }
        var p = PetSprite.Pose(eyes: .open(dx: 1))
        let right = PetSprite.render(p)
        p.flip = true
        XCTAssertEqual(PetSprite.render(p), right.map { Array($0.reversed()) })
        XCTAssertFalse(PetSprite.render(.init(egg: true)).joined().allSatisfy { $0 == .none })
        for mouth: PetSprite.Mouth in [.small, .open, .smile, .flat, .blep] {
            for tail: PetSprite.Tail in [.up, .curl, .down] {
                for squash in [false, true] {
                    let g = PetSprite.render(.init(mouth: mouth, squash: squash, tail: tail))
                    XCTAssertEqual(g.count, PetSprite.height)
                }
            }
        }
        // Pink cheeks and ears are there to be tinted.
        XCTAssertTrue(PetSprite.render(.init()).joined().contains(.blush))
    }

    /// Every act runs for a while without getting stuck or crashing, idle fidgets included.
    func testBrainRunsAllActs() {
        let brain = PetBrain()
        brain.level = { 4 }
        brain.lastFedAt = { Date() }
        brain.appeared(stageWidth: 120)
        brain.pet(); brain.debugStep(20)
        brain.feed(); brain.debugStep(40)
        brain.party(); brain.debugStep(20)
        brain.debugStep(400)
        XCTAssertLessThanOrEqual(brain.frame.x, 120 - PetSprite.width)
        brain.disappeared()
    }

    func testOutfitUnlocks() {
        XCTAssertEqual(PetSprite.Outfit.forLevel(1), .none)
        XCTAssertEqual(PetSprite.Outfit.forLevel(3), .sprout)
        XCTAssertEqual(PetSprite.Outfit.forLevel(6), .headphones)
        XCTAssertEqual(PetSprite.Outfit.forLevel(12), .crown)
    }

    func testDeepSleepStopsTickingAndPokeWakes() {
        let brain = PetBrain()
        brain.level = { 3 }
        brain.appeared()
        XCTAssertTrue(brain.isTicking)
        var sent = 0
        let sub = brain.frames.sink { _ in sent += 1 }
        brain.debugSleep()
        brain.debugStep(PetBrain.deepSleepTicks + 2)
        XCTAssertFalse(brain.isTicking, "deep sleep should stop the timer")
        XCTAssertTrue(brain.frame.particles.contains { $0.kind == .z }, "a still z stays above the head")
        XCTAssertGreaterThan(sent, 0, "frames reach the layer without SwiftUI")
        brain.poke()
        XCTAssertTrue(brain.isTicking, "poke wakes it up")
        brain.disappeared()
        XCTAssertFalse(brain.isTicking, "nothing ticks while nobody sees it")
        sub.cancel()
    }

    func testBitmapRendererDrawsThePet() {
        let w = 40, h = 20
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)
        PetCanvas.draw(PetBrain.Frame(pose: PetSprite.Pose()), in: c, stageWidth: CGFloat(w), height: CGFloat(h),
                       ink: CGColor(red: 1, green: 1, blue: 1, alpha: 1), roams: false, ground: 1)
        let px = c.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let alpha = { (x: Int, y: Int) in px[(y * w + x) * 4 + 3] }
        // Centered: the sprite box is x 12..<28, y 3..<19.
        let drawn = (0..<(w * h)).filter { px[$0 * 4 + 3] > 0 }
        XCTAssertGreaterThan(drawn.count, 100, "the body is filled")
        XCTAssertTrue(drawn.allSatisfy { (11..<29).contains($0 % w) && (2..<19).contains($0 / w) }, "stays in its box")
        XCTAssertEqual(alpha(20, 10), 255, "solid body between the eyes")
        XCTAssertLessThan(alpha(18, 13), 128, "eyes are cut out of the body")
    }
}
