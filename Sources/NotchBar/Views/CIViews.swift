import SwiftUI

// MARK: - Colors

/// GitHub's own dark-mode status colors, so CI reads like GitHub at a glance.
enum CIColor {
    static let pass = Color(red: 0x3F / 255, green: 0xB9 / 255, blue: 0x50 / 255)
    static let fail = Color(red: 0xF8 / 255, green: 0x51 / 255, blue: 0x49 / 255)
    static let run = Color(red: 0xE3 / 255, green: 0xB3 / 255, blue: 0x41 / 255)
    static let idle = Color.white.opacity(0.30)

    static func of(_ s: CIStage.State) -> Color {
        switch s {
        case .passed: return pass
        case .failed: return fail
        case .running: return run
        case .queued, .skipped: return idle
        }
    }
}

extension CIStatus {
    /// One state for the whole pipeline.
    var overall: CIStage.State {
        switch state {
        case .waiting: return .queued
        case .running: return .running
        case .passed: return .passed
        case .failed: return .failed
        }
    }
}

// MARK: - GitHub mark

/// The GitHub mark (Octicons `mark-github`, same path as the website).
struct GitHubMark: Shape {
    private static let base = SVGPath.parse("M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8Z")

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        return Self.base.applying(CGAffineTransform(a: s, b: 0, c: 0, d: s,
                                                    tx: rect.midX - 8 * s, ty: rect.midY - 8 * s))
    }
}

/// Tiny SVG path reader (M L H V C S A Z, absolute and relative). Enough for icon paths.
enum SVGPath {
    static func parse(_ d: String) -> Path {
        let re = try! NSRegularExpression(pattern: #"[MmLlHhVvCcSsAaZz]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?"#)
        let toks = re.matches(in: d, range: NSRange(d.startIndex..., in: d)).map { String(d[Range($0.range, in: d)!]) }
        var path = Path()
        var i = 0
        var cmd: Character = "M"
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCtrl: CGPoint?

        func isCmd(_ t: String) -> Bool { t.count == 1 && t.first!.isLetter }
        func num() -> CGFloat {
            guard i < toks.count, !isCmd(toks[i]) else { return 0 }
            defer { i += 1 }
            return CGFloat(Double(toks[i]) ?? 0)
        }
        func pt(_ rel: Bool) -> CGPoint {
            let x = num(), y = num()
            return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
        }

        while i < toks.count {
            if isCmd(toks[i]) {
                cmd = toks[i].first!; i += 1
                if cmd == "Z" || cmd == "z" {
                    path.closeSubpath(); cur = start; lastCtrl = nil
                    continue
                }
            }
            let before = i
            let rel = cmd.isLowercase
            switch cmd.uppercased().first! {
            case "M":
                cur = pt(rel); start = cur; path.move(to: cur); lastCtrl = nil
                cmd = rel ? "l" : "L"     // extra pairs after M are lines
            case "L":
                cur = pt(rel); path.addLine(to: cur); lastCtrl = nil
            case "H":
                let x = num(); cur.x = rel ? cur.x + x : x; path.addLine(to: cur); lastCtrl = nil
            case "V":
                let y = num(); cur.y = rel ? cur.y + y : y; path.addLine(to: cur); lastCtrl = nil
            case "C":
                let c1 = pt(rel), c2 = pt(rel), p = pt(rel)
                path.addCurve(to: p, control1: c1, control2: c2); lastCtrl = c2; cur = p
            case "S":
                let c1 = lastCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = pt(rel), p = pt(rel)
                path.addCurve(to: p, control1: c1, control2: c2); lastCtrl = c2; cur = p
            case "A":
                let rx = num(), ry = num(), rot = num(), large = num() != 0, sweep = num() != 0
                let p = pt(rel)
                arc(&path, from: cur, to: p, rx: rx, ry: ry, degrees: rot, large: large, sweep: sweep)
                cur = p; lastCtrl = nil
            default:
                i += 1
            }
            if i == before { i += 1 }   // never stall on bad input
        }
        return path
    }

    /// SVG elliptical arc → cubic curves (endpoint to center parameterization, SVG spec F.6.5).
    private static func arc(_ path: inout Path, from p0: CGPoint, to p: CGPoint, rx: CGFloat, ry: CGFloat,
                            degrees: CGFloat, large: Bool, sweep: Bool) {
        guard p0 != p else { return }
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0 else { path.addLine(to: p); return }
        let phi = degrees * .pi / 180, cp = cos(phi), sp = sin(phi)
        let dx = (p0.x - p.x) / 2, dy = (p0.y - p.y) / 2
        let x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var k = sqrt(max(0, num / den))
        if large == sweep { k = -k }
        let cx1 = k * rx * y1 / ry, cy1 = -k * ry * x1 / rx
        let cx = cp * cx1 - sp * cy1 + (p0.x + p.x) / 2
        let cy = sp * cx1 + cp * cy1 + (p0.y + p.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let ux = (x1 - cx1) / rx, uy = (y1 - cy1) / ry
        let vx = (-x1 - cx1) / rx, vy = (-y1 - cy1) / ry
        let t1 = angle(1, 0, ux, uy)
        var dt = angle(ux, uy, vx, vy)
        if !sweep && dt > 0 { dt -= 2 * .pi } else if sweep && dt < 0 { dt += 2 * .pi }
        let segs = max(1, Int(ceil(abs(dt) / (.pi / 2))))
        let delta = dt / CGFloat(segs)
        let t = 4 / 3 * tan(delta / 4)
        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * x * cp - ry * y * sp, y: cy + rx * x * sp + ry * y * cp)
        }
        var a = t1
        for _ in 0..<segs {
            let ca = cos(a), sa = sin(a), cb = cos(a + delta), sb = sin(a + delta)
            path.addCurve(to: map(cb, sb), control1: map(ca - t * sa, sa + t * ca), control2: map(cb + t * sb, sb - t * cb))
            a += delta
        }
    }
}

/// GitHub mark on a tile, with a live status badge in the corner.
struct GitHubTile: View {
    var state: CIStage.State?
    var size: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            .fill(Palette.surface3)
            .overlay(GitHubMark().fill(.white).frame(width: size * 0.58, height: size * 0.58))
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if let state, state != .queued, state != .skipped {
                    CIBadgeDot(state: state, size: size * 0.42)
                        .offset(x: size * 0.12, y: size * 0.12)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                        .id(state)
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.55), value: state)
    }
}

/// Round status dot: amber spinner, green check, red cross. Cut out from the tile with a black ring.
struct CIBadgeDot: View {
    let state: CIStage.State
    var size: CGFloat = 15
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().fill(CIColor.of(state))
            switch state {
            case .running:
                Circle().trim(from: 0, to: 0.62)
                    .stroke(Color.black.opacity(0.75), style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
                    .frame(width: size * 0.5, height: size * 0.5)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear { withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) { spin = true } }
            case .passed:
                Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .black)).foregroundStyle(.black)
            case .failed:
                Image(systemName: "xmark").font(.system(size: size * 0.46, weight: .black)).foregroundStyle(.black)
            default:
                EmptyView()
            }
        }
        .frame(width: size, height: size)
        .padding(2.5)
        .background(Circle().fill(Color.black))
    }
}

// MARK: - Pipeline

/// The CI pipeline as a row of nodes. Running nodes spin and light flows into them;
/// finished nodes pop with a ripple. With `replay`, a finished run lights up node by
/// node, then a shine sweeps across (or the broken node shakes).
struct CIPipeline: View {
    let stages: [CIStage]
    var replay = false
    var nodeSize: CGFloat = 14
    var labels = true

    @State private var born = Date()
    @State private var changed: [String: Date] = [:]
    @State private var awake = true

    static let lead = 0.3       // seconds before a replay starts
    static let step = 0.24      // seconds per node in a replay

    /// When a replay is over (including the shine).
    static func replayLength(_ n: Int) -> Double { lead + Double(max(n, 1)) * step + 1.1 }

    private var r: CGFloat { nodeSize / 2 }
    private var canvasHeight: CGFloat { nodeSize + 20 }   // room for ripples

    var body: some View {
        TimelineView(.animation(paused: !awake)) { ctx in
            let t = ctx.date.timeIntervalSince(born)
            VStack(spacing: 1) {
                Canvas { g, size in draw(&g, size, t) }
                    .frame(height: canvasHeight)
                if labels && !stages.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(stages.enumerated()), id: \.element.id) { i, s in
                            let st = shown(i, t).state
                            Text(s.label)
                                .font(.system(size: nodeSize < 13 ? 9.5 : 10, weight: st == .running ? .semibold : .medium))
                                .monospacedDigit()
                                .foregroundStyle(labelColor(st, dim: dimmed(i)))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .truncationMode(.tail)
                                .padding(.horizontal, 1)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .onAppear {
            born = Date()
            settle()
        }
        .onChange(of: stages) { old, new in
            let before = Dictionary(old.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
            let now = Date()
            for s in new where before[s.id] != s.state && [.passed, .failed].contains(s.state) {
                changed[s.id] = now
            }
            awake = true
            settle()
        }
    }

    /// Keep animating only while something moves (CPU stays near zero otherwise).
    private func settle() {
        let busy = replay ? Self.replayLength(stages.count) + 0.2 : 1.2
        DispatchQueue.main.asyncAfter(deadline: .now() + busy) {
            let anyRunning = stages.isEmpty || stages.contains { $0.state == .running }
            let replaying = replay && Date().timeIntervalSince(born) < Self.replayLength(stages.count)
            let popping = changed.values.contains { Date().timeIntervalSince($0) < 1 }
            if !anyRunning && !replaying && !popping { awake = false } else { settle() }
        }
    }

    // MARK: timing

    private var failedIndex: Int? { stages.firstIndex { $0.state == .failed } }

    private func revealAt(_ i: Int) -> Double {
        if let f = failedIndex, i > f { return Self.lead + Double(f) * Self.step + 0.12 }
        return Self.lead + Double(i) * Self.step
    }

    /// The state to draw for node i at time t, and how long ago it changed (for the pop).
    private func shown(_ i: Int, _ t: Double) -> (state: CIStage.State, age: Double?) {
        let s = stages[i]
        if replay {
            let at = revealAt(i)
            if t < at {
                // The next node spins for a beat before it lands.
                return (t > at - Self.step && failedIndex.map { i <= $0 } ?? true ? .running : .queued, nil)
            }
            let quiet = failedIndex.map { i > $0 } ?? false
            return (s.state, quiet ? nil : t - at)
        }
        return (s.state, changed[s.id].map { Date().timeIntervalSince($0) })
    }

    private func dimmed(_ i: Int) -> Bool {
        guard let f = failedIndex, i > f else { return false }
        return stages[i].state != .running
    }

    private func labelColor(_ s: CIStage.State, dim: Bool) -> Color {
        if dim { return Palette.text3.opacity(0.6) }
        switch s {
        case .running: return CIColor.run
        case .failed: return CIColor.fail
        case .passed: return Palette.text2
        case .queued, .skipped: return Palette.text3
        }
    }

    // MARK: drawing

    private func draw(_ g: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let ghost = stages.isEmpty
        let n = ghost ? 4 : stages.count
        let col = size.width / CGFloat(n)
        let cy = size.height / 2
        let xs = (0..<n).map { (CGFloat($0) + 0.5) * col }

        // Track and flowing light between nodes.
        for i in 0..<(n - 1) {
            let a = xs[i] + r + 3, b = xs[i + 1] - r - 3
            guard b > a else { continue }
            let seg = Path(roundedRect: CGRect(x: a, y: cy - 1, width: b - a, height: 2), cornerRadius: 1)
            g.opacity = ghost ? 0.6 : (dimmed(i + 1) ? 0.45 : 1)
            g.fill(seg, with: .color(.white.opacity(0.12)))
            g.opacity = 1

            if ghost {
                flow(&g, a, b, cy, t, offset: Double(i) * 0.33, color: Palette.text2)
                continue
            }
            let right = shown(i + 1, t), left = shown(i, t)
            var fill: CGFloat = 0
            if replay {
                let start = revealAt(i + 1) - Self.step
                fill = CGFloat(min(1, max(0, (t - start) / Self.step)))
                if dimmed(i + 1) { fill = 0 }
            } else if [.passed, .failed, .running].contains(right.state) || (left.state == .passed && right.state == .skipped) {
                fill = 1
            }
            if fill > 0 {
                let color: Color = right.state == .failed && (!replay || t >= revealAt(i + 1)) ? CIColor.fail : CIColor.pass
                let done = Path(roundedRect: CGRect(x: a, y: cy - 1, width: (b - a) * fill, height: 2), cornerRadius: 1)
                g.fill(done, with: .color(right.state == .running && !replay ? CIColor.run.opacity(0.28) : color))
            }
            if right.state == .running {
                flow(&g, a, b, cy, t, offset: Double(i) * 0.21, color: CIColor.run)
            }
        }

        // Nodes.
        for i in 0..<n {
            let enter = min(1, max(0, (t - Double(i) * 0.05) / 0.32))
            let grow = backOut(enter)
            if ghost {
                ring(&g, CGPoint(x: xs[i], y: cy), r * grow, dashed: true, opacity: 0.5)
                continue
            }
            let (state, age) = shown(i, t)
            var c = CGPoint(x: xs[i], y: cy)
            g.opacity = dimmed(i) ? 0.45 : 1
            var scale = grow
            if let age, age < 0.36 { scale *= 1 + 0.26 * sin(.pi * age / 0.36) }
            if state == .failed, let age, age < 0.55 { c.x += sin(age * 46) * 3.2 * (1 - age / 0.55) }

            switch state {
            case .queued:
                ring(&g, c, r * scale, dashed: true, opacity: 0.55)
            case .skipped:
                g.fill(circle(c, r * scale), with: .color(.white.opacity(0.14)))
                var minus = Path()
                minus.move(to: CGPoint(x: c.x - r * 0.4, y: c.y)); minus.addLine(to: CGPoint(x: c.x + r * 0.4, y: c.y))
                g.stroke(minus, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            case .running:
                let rr = r * scale
                g.stroke(circle(c, rr - 1), with: .color(CIColor.run.opacity(0.18)), lineWidth: 2)
                let spin = Angle.radians(t * 2 * .pi / 0.9)
                g.stroke(circle(c, rr - 1),
                         with: .conicGradient(Gradient(colors: [CIColor.run.opacity(0), CIColor.run.opacity(0.15), CIColor.run]),
                                              center: c, angle: spin),
                         style: StrokeStyle(lineWidth: 2, lineCap: .round))
                let pulse = 0.5 + 0.5 * sin(t * 5)
                g.fill(circle(c, rr * (0.30 + 0.08 * pulse)), with: .color(CIColor.run.opacity(0.75 + 0.25 * pulse)))
            case .passed, .failed:
                let color = CIColor.of(state)
                let rr = r * scale
                if let age, age < 0.75 {
                    let q = easeOut(age / 0.75)
                    g.stroke(circle(c, rr + (state == .failed ? 13 : 10) * q),
                             with: .color(color.opacity(0.7 * (1 - q))), lineWidth: 1.6)
                }
                if state == .failed, replay, let age, age > 0.5 {
                    // A slow red breath on the node that broke.
                    let b = 0.5 + 0.5 * sin((age - 0.5) * 3.2)
                    g.fill(circle(c, rr + 3 + 2 * b), with: .color(color.opacity(0.10 + 0.12 * b)))
                }
                g.fill(circle(c, rr), with: .color(color))
                let k = age.map { min(1, max(0, ($0 - 0.04) / 0.26)) } ?? 1
                let mark = state == .passed ? check(c, rr) : cross(c, rr)
                g.stroke(mark.trimmedPath(from: 0, to: k), with: .color(.black.opacity(0.85)),
                         style: StrokeStyle(lineWidth: max(1.5, rr * 0.26), lineCap: .round, lineJoin: .round))
            }
            g.opacity = 1
        }

        // Victory shine: a band of light runs across the whole pipeline.
        if replay, !ghost, failedIndex == nil, stages.allSatisfy({ $0.state != .running && $0.state != .queued }) {
            let start = revealAt(n - 1) + 0.28
            let p = (t - start) / 0.85
            if p > 0, p < 1 {
                let x = -50 + (size.width + 100) * CGFloat(easeInOut(p))
                var shape = Path()
                for i in 0..<n { shape.addPath(circle(CGPoint(x: xs[i], y: cy), r + 1.5)) }
                shape.addRect(CGRect(x: xs[0], y: cy - 1.5, width: xs[n - 1] - xs[0], height: 3))
                g.drawLayer { l in
                    l.clip(to: shape)
                    l.blendMode = .plusLighter
                    l.fill(Path(CGRect(x: x - 40, y: 0, width: 80, height: size.height)),
                           with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0.85), .white.opacity(0)]),
                                                 startPoint: CGPoint(x: x - 40, y: 0), endPoint: CGPoint(x: x + 40, y: 0)))
                }
            }
        }
    }

    /// A comet of light running along a connector.
    private func flow(_ g: inout GraphicsContext, _ a: CGFloat, _ b: CGFloat, _ cy: CGFloat, _ t: Double,
                      offset: Double, color: Color) {
        let len = b - a
        let tail: CGFloat = min(22, len * 0.7)
        let p = CGFloat((t / 0.95 + offset).truncatingRemainder(dividingBy: 1))
        let head = a + (len + tail) * p
        g.drawLayer { l in
            l.clip(to: Path(CGRect(x: a, y: cy - 2, width: len, height: 4)))
            l.fill(Path(roundedRect: CGRect(x: head - tail, y: cy - 1, width: tail, height: 2), cornerRadius: 1),
                   with: .linearGradient(Gradient(colors: [color.opacity(0), color]),
                                         startPoint: CGPoint(x: head - tail, y: cy), endPoint: CGPoint(x: head, y: cy)))
            l.fill(circle(CGPoint(x: head, y: cy), 1.6), with: .color(color))
        }
    }

    private func ring(_ g: inout GraphicsContext, _ c: CGPoint, _ rr: CGFloat, dashed: Bool, opacity: Double) {
        g.stroke(circle(c, max(0, rr - 0.75)), with: .color(.white.opacity(0.5 * opacity)),
                 style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [2.2, 2.0] : []))
    }

    private func circle(_ c: CGPoint, _ rr: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr))
    }

    private func check(_ c: CGPoint, _ rr: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: c.x - rr * 0.42, y: c.y + rr * 0.02))
        p.addLine(to: CGPoint(x: c.x - rr * 0.12, y: c.y + rr * 0.32))
        p.addLine(to: CGPoint(x: c.x + rr * 0.44, y: c.y - rr * 0.30))
        return p
    }

    private func cross(_ c: CGPoint, _ rr: CGFloat) -> Path {
        let k = rr * 0.34
        var p = Path()
        p.move(to: CGPoint(x: c.x - k, y: c.y - k)); p.addLine(to: CGPoint(x: c.x + k, y: c.y + k))
        p.move(to: CGPoint(x: c.x + k, y: c.y - k)); p.addLine(to: CGPoint(x: c.x - k, y: c.y + k))
        return p
    }

    private func easeOut(_ x: Double) -> Double { 1 - pow(1 - min(1, max(0, x)), 3) }
    private func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    private func backOut(_ x: Double) -> CGFloat {
        let c1 = 1.70158, c3 = c1 + 1
        return CGFloat(1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2))
    }
}

// MARK: - Banner

/// The CI banner: GitHub tile, headline, timer and the live (or replayed) pipeline.
struct CIBannerView: View {
    let banner: Banner
    let ci: CIStatus
    let onTap: () -> Void
    /// A finished run plays back first, then says how it went.
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                GitHubTile(state: revealed || !ci.isFinished ? ci.overall : .running, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(revealed || !ci.isFinished ? banner.title : "\(projectPrefix)CI")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .contentTransition(.interpolate)
                    subtitle
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    CIElapsed(ci: ci)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(revealed ? CIColor.of(ci.overall) : Palette.text2)
                    Text(String(ci.sha.prefix(7)))
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.text3)
                }
            }
            CIPipeline(stages: ci.stages, replay: ci.isFinished, nodeSize: 14)
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onAppear {
            guard ci.isFinished else { revealed = true; return }
            // Say how it went once the replay reaches the last node (or the one that broke).
            let last = ci.stages.firstIndex { $0.state == .failed } ?? max(ci.stages.count - 1, 0)
            let at = CIPipeline.lead + Double(last) * CIPipeline.step + (ci.overall == .failed ? 0.45 : 0.25)
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.7)) { revealed = true }
            }
        }
    }

    private var projectPrefix: String {
        banner.title.components(separatedBy: " CI").first.map { $0 + " " } ?? ""
    }

    @ViewBuilder private var subtitle: some View {
        if revealed || !ci.isFinished {
            Text(banner.subtitle)
                .foregroundStyle(Palette.text2)
                .transition(.blurReplace)
        } else {
            Text("checking \(ci.stages.count) stage\(ci.stages.count == 1 ? "" : "s")")
                .foregroundStyle(Palette.text3)
                .transition(.blurReplace)
        }
    }
}

/// "4m 12s", ticking while the run is going.
struct CIElapsed: View {
    let ci: CIStatus

    var body: some View {
        if ci.isFinished {
            Text(Self.format(ci.elapsed)).monospacedDigit()
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(Self.format(ci.elapsed)).monospacedDigit().contentTransition(.numericText())
            }
        }
    }

    static func format(_ s: TimeInterval) -> String {
        let s = max(0, Int(s))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

// MARK: - Card (expanded notch)

/// CI for a session's last push, under its row. Click to open the run on GitHub.
struct CICard: View {
    let ci: CIStatus
    @State private var hover = false

    var body: some View {
        Button {
            if let url = ci.url { NSWorkspace.shared.open(url) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    GitHubMark().fill(Color.white.opacity(0.85)).frame(width: 13, height: 13)
                    Text(headline)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(ci.overall == .queued ? Palette.text2 : CIColor.of(ci.overall))
                        .lineLimit(1)
                        .contentTransition(.interpolate)
                    Text(meta)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.text3)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    CIElapsed(ci: ci)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.text3)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Palette.text3)
                        .opacity(hover ? 1 : 0.4)
                }
                CIPipeline(stages: ci.stages, nodeSize: 12)
                if let caption {
                    HStack(spacing: 5) {
                        Image(systemName: ci.overall == .failed ? "exclamationmark.circle.fill" : "play.fill")
                            .font(.system(size: ci.overall == .failed ? 9.5 : 7))
                            .foregroundStyle(ci.overall == .failed ? CIColor.fail : CIColor.run)
                        Text(caption)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.text2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contentTransition(.interpolate)
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(hover ? 0.07 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.3), value: ci)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { hover = h } }
        .help("Open this run on GitHub")
    }

    private var headline: String {
        switch ci.state {
        case .waiting: return "Waiting for GitHub"
        case .running: return "CI running"
        case .passed: return "All checks passed"
        case let .failed(job): return "\(job ?? "CI") failed"
        }
    }

    private var meta: String {
        [ci.branch, String(ci.sha.prefix(7))].compactMap { $0 }.joined(separator: " · ")
    }

    private var caption: String? {
        switch ci.state {
        case .failed: return ci.failedStep.map { "broke at \($0)" }
        case .running, .waiting: return ci.step
        default: return nil
        }
    }

    private var borderColor: Color {
        switch ci.overall {
        case .failed: return CIColor.fail.opacity(0.35)
        case .passed: return CIColor.pass.opacity(0.22)
        case .running: return CIColor.run.opacity(0.18)
        default: return Color.white.opacity(0.06)
        }
    }
}
