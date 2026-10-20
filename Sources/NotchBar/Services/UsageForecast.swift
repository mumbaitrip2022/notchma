import Foundation

/// Learns how fast each plan-limit window is being used and projects when it fills.
final class UsageForecast {
    private struct Sample { let at: Date; let pct: Double }
    private var samples: [String: [Sample]] = [:] // "agent|label|reset" → samples

    private func key(_ agent: Agent, _ w: UsageWindow) -> String {
        "\(agent.rawValue)|\(w.label)|\(Int(w.resetsAt?.timeIntervalSince1970 ?? 0))"
    }

    func record(_ agent: Agent, _ windows: [UsageWindow], now: Date = Date()) {
        for w in windows {
            let k = key(agent, w)
            var list = samples[k] ?? []
            if let last = list.last, last.pct == w.usedPercent, now.timeIntervalSince(last.at) < 60 { continue }
            list.append(Sample(at: now, pct: w.usedPercent))
            list.removeAll { now.timeIntervalSince($0.at) > 90 * 60 } // recent pace only
            samples[k] = list
        }
        // Forget windows that have already reset (the key ends with the reset time).
        samples = samples.filter { k, _ in
            guard let ts = Double(k.split(separator: "|").last ?? ""), ts > 0 else { return true }
            return Date(timeIntervalSince1970: ts) > now
        }
    }

    /// When the window will hit 100% at the current pace, if that's before it resets.
    func fullAt(_ agent: Agent, _ w: UsageWindow, now: Date = Date()) -> Date? {
        guard w.usedPercent < 100, let list = samples[key(agent, w)], list.count >= 2,
              let first = list.first, let last = list.last else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= 5 * 60 else { return nil } // need a few minutes of history
        // Least-squares slope (percent per second).
        let t0 = first.at.timeIntervalSince1970
        let xs = list.map { $0.at.timeIntervalSince1970 - t0 }, ys = list.map(\.pct)
        let n = Double(list.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for i in 0..<list.count { num += (xs[i] - mx) * (ys[i] - my); den += (xs[i] - mx) * (xs[i] - mx) }
        guard den > 0 else { return nil }
        let slope = num / den
        guard slope > 0 else { return nil }
        let eta = now.addingTimeInterval((100 - w.usedPercent) / slope)
        if let reset = w.resetsAt, eta >= reset { return nil }
        return eta
    }
}
