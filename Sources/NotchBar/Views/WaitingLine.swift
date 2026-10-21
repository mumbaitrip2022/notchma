import SwiftUI

/// "Waiting for you", said like an assistant. If the agent asked something, that
/// question leads; otherwise a few friendly lines rotate with a soft crossfade.
/// Ticks every 3.5s only while it's on screen.
struct WaitingLine: View {
    let session: Session
    var size: CGFloat = 11.5
    var weight: Font.Weight = .regular

    /// Casual, human lines. Each one still says exactly one thing: it's your move.
    static func vibes(_ agent: String) -> [String] {
        [
            "your move ✨",
            "ball's in your court 🎾",
            "\(agent) is all ears",
            "ready when you are, no rush",
            "the floor is yours 🎤",
            "\(agent) is lowkey waiting on you",
            "say the word and it's on",
            "what are we building next?",
            "one message away from the next win",
            "got an idea? \(agent) is listening",
        ]
    }

    static func phrases(for s: Session) -> [String] {
        let name = s.agent.shortName.lowercased()
        var vibes = vibes(name)
        // Each session gets its own order, so two waiting agents never chant in sync.
        var seed = UInt64(abs(s.id.hashValue))
        for i in stride(from: vibes.count - 1, to: 0, by: -1) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            vibes.swapAt(i, Int(seed >> 33) % (i + 1))
        }
        var lines: [String] = []
        if let q = s.question {
            if q.hasPrefix("Plan ready") {
                lines += ["the plan is ready, take a look 👀", "\(name) wants your sign off on the plan"]
            } else {
                lines += ["“\(q)”", "\(name) needs your call on this 👀"]
            }
        } else if let done = s.lastMessage.flatMap({ ToolInfo.firstLine(SessionStore.plain($0)) }), !done.isEmpty {
            lines.append("done cooking 🍳 " + ToolInfo.clip(done.prefix(1).lowercased() + done.dropFirst(), 64))
        }
        return lines + vibes.prefix(4)
    }

    var body: some View {
        let lines = Self.phrases(for: session)
        TimelineView(.periodic(from: .now, by: 3.5)) { ctx in
            // The question stays up twice as long as the friendly lines.
            let weighted = session.question != nil ? [lines[0]] + lines : lines
            let i = Int(ctx.date.timeIntervalSinceReferenceDate / 3.5) % weighted.count
            Text(weighted[i])
                .font(.system(size: size, weight: weight))
                .foregroundStyle(Color.waiting)
                .lineLimit(1)
                .truncationMode(.tail)
                .id(weighted[i])
                .transition(.opacity.combined(with: .offset(y: 3)))
                .animation(.easeInOut(duration: 0.45), value: i)
        }
    }
}
