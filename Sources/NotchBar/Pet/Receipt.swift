import AppKit
import SwiftUI

/// The lines printed on today's receipt. Only real numbers; empty rows are skipped.
struct ReceiptContent: Equatable {
    enum Line: Equatable {
        case title(String)
        case center(String)
        case row(String, String)
        case bold(String, String)
        case rule
        case gap
        case barcode(String)
    }

    var lines: [Line]
    var number: Int
    var signature: String

    static func make(day: DayLedger.Day, number: Int, petName: String, streak: Int, now: Date = Date()) -> ReceiptContent {
        var l: [Line] = []
        l.append(.title("NOTCHBAR"))
        l.append(.center("agent receipt"))
        l.append(.gap)
        l.append(.row(String(format: "#%04d", number), Self.date.string(from: now).uppercased()))
        l.append(.row("served by \(petName)", Self.time.string(from: now).lowercased()))
        l.append(.rule)

        if day.tasks == 0 && day.isEmpty {
            l.append(.gap)
            l.append(.center("no orders yet today"))
            l.append(.center("\(petName) is waiting for a prompt"))
            l.append(.gap)
        } else {
            for (agent, secs) in day.agentTime { l.append(.row(agent.name.uppercased(), Self.duration(secs))) }
            if !day.agentTime.isEmpty { l.append(.rule) }
            func add(_ label: String, _ n: Int, _ text: String? = nil) {
                if n > 0 { l.append(.row(label, text ?? n.formatted())) }
            }
            add("tasks shipped", day.tasks)
            add("files touched", day.files.count)
            if day.added + day.removed > 0 {
                l.append(.row("lines", "+\(day.added.formatted())  −\(day.removed.formatted())"))
            }
            add("commands run", day.commands)
            if day.testsPassed + day.testsFailed > 0 {
                l.append(.row("tests", day.testsFailed > 0 ? "\(day.testsPassed) ✓  \(day.testsFailed) ✗" : "\(day.testsPassed.formatted()) ✓"))
            }
            if day.allowed + day.denied > 0 {
                l.append(.row("you approved", day.denied > 0 ? "\(day.allowed)  denied \(day.denied)" : "\(day.allowed)"))
            }
            add("auto approved", day.autoAllowed)
            add("tokens", day.tokens, Fmt.tokens(day.tokens))
            l.append(.rule)
            if let cost = day.cost, cost > 0 {
                l.append(.bold("TOTAL", String(format: "$%.2f", cost)))
                l.append(.center("api value. your plan covers it"))
            } else {
                l.append(.bold("TOTAL", "\(day.tasks) task\(day.tasks == 1 ? "" : "s")"))
            }
            l.append(.rule)
            if let p = day.topProject { l.append(.row("top project", ToolInfo.clip(p, 18))) }
            if day.longest >= 60 { l.append(.row("longest task", Self.duration(day.longest))) }
            if streak >= 2 { l.append(.row("streak", "🔥 \(streak) days")) }
        }
        l.append(.gap)
        l.append(.barcode(day.signature))
        l.append(.gap)
        l.append(.center(quip(day: day, petName: petName, now: now)))
        l.append(.center("thank you for shipping"))
        l.append(.gap)
        l.append(.center("github.com/mumbaitrip2022/notchma"))
        return ReceiptContent(lines: l, number: number, signature: day.signature + petName + "\(streak)")
    }

    /// One line that sums up the day, picked from what actually happened.
    static func quip(day: DayLedger.Day, petName: String, now: Date) -> String {
        let hour = Calendar.current.component(.hour, from: now)
        let top = day.agentTime.first?.agent.shortName.lowercased()
        if day.tasks == 0 { return hour < 12 ? "fresh day. \(petName) is ready" : "\(petName) is starving fr 🍪" }
        if day.testsFailed > day.testsPassed && day.testsFailed > 0 { return "tests were not testing today 💀" }
        if hour >= 1 && hour < 5 { return "late night bestie. touch grass 🌙" }
        if day.denied >= 3 { return "you said no \(day.denied) times. boundaries 💅" }
        if day.added >= 1000 { return "1k+ lines. absolute cinema 🎬" }
        if day.testsPassed >= 50 { return "the test suite ate fr ✅" }
        if day.agentTime.count >= 2 { return "full squad showed up today 🤝" }
        if (day.cost ?? 0) >= 20 { return "big spender energy 💸" }
        if day.tasks >= 15 { return "agents on a mission today 🚀" }
        if let top { return "\(top) did the heavy lifting fr" }
        return "solid day. \(petName) approves ✨"
    }

    static func duration(_ s: Double) -> String {
        let m = max(1, Int((s / 60).rounded()))
        return m >= 60 ? "\(m / 60)h \(String(format: "%02d", m % 60))m" : "\(m)m"
    }

    private static let date: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM yyyy"; return f
    }()
    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
}

// MARK: - Paper

enum Thermal {
    static let paper = Color(red: 0.957, green: 0.945, blue: 0.914)   // #F4F1E9
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.11)
    static let faint = Color(red: 0.11, green: 0.11, blue: 0.11).opacity(0.55)
    static let width: CGFloat = 252
}

/// A printed receipt: the pet logo, the lines, a barcode and a torn edge.
struct ReceiptPaper: View {
    let content: ReceiptContent
    let pose: PetSprite.Pose

    var body: some View {
        VStack(spacing: 0) {
            PetCanvas(frame: PetBrain.Frame(pose: pose), pixel: 2, ink: Thermal.ink, accent: nil, roams: false, ground: 0)
                .frame(width: 40, height: 28)
                .padding(.top, 10)
            VStack(spacing: 1.5) {
                ForEach(Array(content.lines.enumerated()), id: \.offset) { _, line in row(line) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 18)
        }
        .frame(width: Thermal.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Thermal.paper)
        .clipShape(TornEdge())
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder private func row(_ line: ReceiptContent.Line) -> some View {
        let mono = Font.system(size: 10, weight: .medium, design: .monospaced)
        switch line {
        case let .title(t):
            Text(t.map(String.init).joined(separator: " "))
                .font(.system(size: 15, weight: .heavy, design: .monospaced))
                .foregroundStyle(Thermal.ink)
                .padding(.bottom, 1)
        case let .center(t):
            Text(t).font(mono).foregroundStyle(Thermal.faint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
        case let .row(a, b):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(a).lineLimit(1)
                Spacer(minLength: 4)
                Text(b).lineLimit(1).monospacedDigit()
            }
            .font(mono)
            .foregroundStyle(Thermal.ink)
        case let .bold(a, b):
            HStack(alignment: .firstTextBaseline) {
                Text(a)
                Spacer(minLength: 4)
                Text(b).monospacedDigit()
            }
            .font(.system(size: 13, weight: .heavy, design: .monospaced))
            .foregroundStyle(Thermal.ink)
            .padding(.vertical, 1)
        case .rule:
            DottedRule().frame(height: 7)
        case .gap:
            Color.clear.frame(height: 3)
        case let .barcode(seed):
            VStack(spacing: 3) {
                Barcode(seed: seed).frame(height: 26)
                Text(String(format: "%04d %@", content.number, String(UInt(bitPattern: seed.stableHash) % 100_000_000)))
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(Thermal.faint)
            }
        }
    }
}

struct DottedRule: View {
    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = 0
            while x < size.width {
                ctx.fill(Path(CGRect(x: x, y: size.height / 2 - 0.5, width: 2, height: 1)), with: .color(Thermal.faint))
                x += 4
            }
        }
    }
}

/// Bars generated from the day's numbers, so every day's receipt is different.
struct Barcode: View {
    let seed: String
    var body: some View {
        Canvas { ctx, size in
            var h = UInt64(bitPattern: Int64(seed.stableHash))
            var x: CGFloat = 0
            var dark = true
            while x < size.width {
                h = h &* 6364136223846793005 &+ 1442695040888963407
                let w = CGFloat(1 + Int((h >> 33) % 3))
                if dark { ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(Thermal.ink)) }
                x += w
                dark.toggle()
            }
        }
    }
}

/// Flat top, zig-zag torn bottom.
struct TornEdge: Shape {
    var tooth: CGFloat = 5
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - tooth))
        let n = Int(r.width / (tooth * 2))
        let step = r.width / CGFloat(max(n, 1))
        for i in 0..<n {
            let x0 = r.maxX - CGFloat(i) * step
            p.addLine(to: CGPoint(x: x0 - step / 2, y: r.maxY))
            p.addLine(to: CGPoint(x: x0 - step, y: r.maxY - tooth))
        }
        p.closeSubpath()
        return p
    }
}

extension String {
    /// FNV-1a: stable across launches (unlike `hashValue`).
    var stableHash: Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(bitPattern: UInt(h))
    }
}

// MARK: - Printing

/// The paper feeding out of the slot, line by line, with a dot-matrix chatter.
struct ReceiptPrinter: View {
    let content: ReceiptContent
    let pose: PetSprite.Pose
    /// Animate this print (new numbers since you last saw it), or show it already out.
    let animate: Bool
    var sound = true
    var onPrinting: (Bool) -> Void = { _ in }

    @State private var fed: CGFloat = 0
    @State private var height: CGFloat = 300
    @State private var drop: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            PrinterSlot().zIndex(1)
            ReceiptPaper(content: content, pose: pose)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
                .offset(y: -(1 - fed) * height + drop)
                .frame(height: height + 4, alignment: .top)
                .clipped()
                .padding(.top, -3)
        }
        // Prints once each time the notch opens; later changes update the paper in place.
        .task { await run() }
    }

    private func run() async {
        guard animate, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { fed = 1; return }
        fed = 0
        onPrinting(true)
        try? await Task.sleep(for: .milliseconds(260)) // let the notch finish opening
        if sound { PrinterSound.play() }
        let steps = 34
        for i in 1...steps {
            withAnimation(.linear(duration: 0.035)) { fed = CGFloat(i) / CGFloat(steps) }
            try? await Task.sleep(for: .milliseconds(38))
            if Task.isCancelled { fed = 1; onPrinting(false); return }
        }
        // Torn off: the paper drops a hair and settles.
        // (No rotation or shadow here: either one stops text drawing inside the notch panel.)
        withAnimation(.easeOut(duration: 0.08)) { drop = 4 }
        try? await Task.sleep(for: .milliseconds(90))
        withAnimation(.spring(response: 0.45, dampingFraction: 0.45)) { drop = 0 }
        onPrinting(false)
    }
}

/// The slot the paper comes out of.
struct PrinterSlot: View {
    var body: some View {
        ZStack {
            Capsule().fill(Palette.surface3)
            Capsule().fill(Color.black).frame(height: 2).padding(.horizontal, 8)
        }
        .frame(width: Thermal.width + 18, height: 8)
    }
}

// MARK: - Sound

/// A short dot-matrix printer sound, synthesized once (no audio files shipped).
enum PrinterSound {
    private static let sound: NSSound? = {
        let rate = 22_050, seconds = 1.35
        let n = Int(Double(rate) * seconds)
        var samples = [Int16](repeating: 0, count: n)
        var seed: UInt32 = 0x9E3779B9
        func noise() -> Double {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            return Double(Int32(bitPattern: seed)) / Double(Int32.max)
        }
        // Print-head strikes: quick noisy clicks, grouped like lines of text.
        let strike = Int(Double(rate) * 0.0045), gap = Int(Double(rate) * 0.019)
        var i = 0, k = 0
        while i < n {
            let lineBreak = k % 14 == 13
            let amp = (lineBreak ? 0.10 : 0.30) * (0.75 + 0.25 * noise())
            for j in 0..<min(strike, n - i) {
                let env = exp(-Double(j) / Double(strike) * 3.5)
                samples[i + j] = Int16(max(-1, min(1, noise() * amp * env)) * 32_000)
            }
            i += lineBreak ? gap * 3 : gap
            k += 1
        }
        // Fade the tail.
        for j in max(0, n - 2000)..<n { samples[j] = Int16(Double(samples[j]) * Double(n - j) / 2000) }
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + n * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(n * 2))
        samples.forEach { put($0) }
        let s = NSSound(data: data)
        s?.volume = 0.3
        return s
    }()

    static func play() { sound?.stop(); sound?.play() }
}

// MARK: - Sharing

/// The image people post: the notch, the pet on the printer, today's receipt.
struct ReceiptShareCard: View {
    let content: ReceiptContent
    let pose: PetSprite.Pose
    let petName: String
    let level: Int

    var body: some View {
        VStack(spacing: 0) {
            // The notch the receipt prints from.
            Color.black.frame(width: 200, height: 26)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 13, bottomTrailingRadius: 13))
            PetCanvas(frame: PetBrain.Frame(pose: pose), pixel: 3.5, ink: .white, roams: false, ground: 0)
                .frame(width: 70, height: 56)
                .padding(.top, 18)
            PrinterSlot().zIndex(1)
            ReceiptPaper(content: content, pose: pose)
                .padding(.top, -3)
            HStack(spacing: 6) {
                Text("\(petName) · lvl \(max(level, 1))")
                    .foregroundStyle(.white.opacity(0.8))
                Text("printed from my notch").foregroundStyle(.white.opacity(0.45))
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.top, 16)
        }
        .padding(.horizontal, 44)
        .padding(.bottom, 26)
        .background(Color(white: 0.06))
        .environment(\.colorScheme, .dark)
    }
}

enum ReceiptExport {
    @MainActor
    static func image(_ card: ReceiptShareCard) -> NSImage? {
        let r = ImageRenderer(content: card)
        r.scale = 3
        return r.nsImage
    }

    static func png(_ img: NSImage) -> Data? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    @discardableResult
    static func copy(_ img: NSImage) -> Bool {
        guard let data = png(img) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
        return true
    }

    static func save(_ img: NSImage, day: String) -> URL? {
        guard let data = png(img) else { return nil }
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let url = dir.appendingPathComponent("NotchBar receipt \(day).png")
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        return url
    }
}
