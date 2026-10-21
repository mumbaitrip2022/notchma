import AppKit
import SwiftUI

/// First-run tour, hosted by the pet. Six short steps; connecting agents and the
/// sample approval are real interactions, not slides.
struct TourView: View {
    @ObservedObject var ui: NotchUI
    @ObservedObject var prefs: Prefs
    @ObservedObject var ledger: DayLedger
    let pet: PetBrain
    var connectAll: () -> Void
    var setAgent: (Agent, Bool) -> Void
    var finish: () -> Void

    @State private var step = 0
    @State private var tried: Bool?          // the sample approval: allowed / denied
    @State private var forward = true
    private let steps = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BandRow(gap: ui.cameraGap) {
                Text(step == 0 ? "Welcome to NotchBar" : "Quick tour · \(step + 1) of \(steps)")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .contentTransition(.numericText())
            } trailing: {
                if step < steps - 1 {
                    Button("Skip") { finish() }
                        .buttonStyle(NBButtonStyle(kind: .plain, compact: true))
                }
            }
            .frame(height: max(ui.bandHeight, 30))
            .padding(.horizontal, 8)

            HStack(alignment: .top, spacing: 18) {
                petStage
                VStack(alignment: .leading, spacing: 10) {
                    page
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .opacity))
            }
            .padding(18)
            .frame(minHeight: 196, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.surface1))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            footer
        }
        .animation(NotchUI.motion, value: step)
        .onAppear { pet.poke() }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .init("NBTourStep"))) { n in
            if let s = n.object as? Int { go(s - step) }
        }
        #endif
    }

    // MARK: the pet

    private var petStage: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.surface3)
                PetView(brain: pet, pixel: 4, roams: false, ground: 2)
                    .frame(width: 96, height: 80)
                    .contentShape(Rectangle())
                    .onTapGesture { pet.pet() }
            }
            .frame(width: 104, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(ledger.petName)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.text2)
        }
        .help("Click to pet \(ledger.petName)")
    }

    // MARK: pages

    @ViewBuilder private var page: some View {
        switch step {
        case 0:
            title("hi, I'm \(ledger.petName) 👋")
            para("I live in your notch and keep an eye on Claude Code, Codex and Cursor, so you can stop babysitting terminals.")
            note(ledger.level == 0 ? "I'm still an egg. finish one task and I hatch 🐣" : "level \(ledger.level) and counting ✨")
        case 1:
            title("plug in your agents")
            VStack(spacing: 6) { ForEach(Agent.allCases) { agentRow($0) } }
            if Agent.allCases.contains(where: { NotchController.agentDetected($0) && !prefs.installed.contains($0) }) {
                Button { connectAll() } label: { Label("Connect all", systemImage: "bolt.fill") }
                    .buttonStyle(NBButtonStyle(kind: .primary, compact: true))
            }
            note("your other settings stay untouched, and a backup is kept next to each file")
        case 2:
            title("approve from anywhere")
            para("when an agent wants to run something, I pop open with the exact command. give this one a try:")
            sampleApproval
        case 3:
            title("glance, don't switch")
            VStack(alignment: .leading, spacing: 7) {
                MiniPill(kind: .working)
                MiniPill(kind: .asking)
                MiniPill(kind: .done)
            }
            note("hover to see every session · click to pin · click a session to jump to its terminal")
        case 4:
            title("your day, printed 🧾")
            para("click me in the header any time and I print today's receipt: tasks, tests, lines, tokens. post it, flex a little.")
            HStack(spacing: 8) {
                Image(systemName: "hand.point.up.left.fill").foregroundStyle(Palette.text3)
                Text("⌃⌥J jumps to whatever is waiting on you")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.text2)
            }
        default:
            title("you're all set ✨")
            PillToggle(label: "Open NotchBar at login",
                       isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.launchAtLogin = $0 }))
            PillToggle(label: "Soft sounds for approvals and done", isOn: $prefs.sounds)
            note("the tour and Report a Problem live in the gear menu")
        }
    }

    private func title(_ t: String) -> some View {
        Text(t).font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(.white)
    }

    private func para(_ t: String) -> some View {
        Text(t).font(.system(size: 12.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ t: String) -> some View {
        Text(t).font(.system(size: 11.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
    }

    private func agentRow(_ a: Agent) -> some View {
        let detected = NotchController.agentDetected(a)
        let on = prefs.installed.contains(a)
        return HStack(spacing: 10) {
            AgentTile(agent: a, size: 24)
            Text(a.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(detected ? .white : Palette.text3)
            Spacer(minLength: 6)
            if on {
                Label("connected", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.success)
                    .transition(.scale.combined(with: .opacity))
            } else if detected {
                Button("Connect") { setAgent(a, true) }
                    .buttonStyle(NBButtonStyle(kind: .secondary, compact: true))
            } else {
                Text("not installed").font(.system(size: 11.5)).foregroundStyle(Palette.text3)
            }
        }
        .animation(NotchUI.motion, value: on)
    }

    private var sampleApproval: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("$").foregroundStyle(Palette.text3)
                Text("npm test").foregroundStyle(.white)
                Spacer()
                Text("sample").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.text3)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().stroke(Palette.hairline))
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.code))
            if let tried {
                Label(tried ? "allowed. that's literally it" : "denied. the agent gets told no and moves on",
                      systemImage: tried ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tried ? Color.success : Palette.text2)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else {
                HStack(spacing: 8) {
                    Button { answer(false) } label: { HStack(spacing: 5) { Text("Deny"); Text("⌃⌥N").opacity(0.5) } }
                        .buttonStyle(NBButtonStyle(kind: .secondary, compact: true))
                    Button { answer(true) } label: { HStack(spacing: 5) { Text("Allow"); Text("⌃⌥Y").opacity(0.5) } }
                        .buttonStyle(NBButtonStyle(kind: .primary, compact: true))
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: tried)
    }

    private func answer(_ allow: Bool) {
        tried = allow
        if allow { pet.pet() }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<steps, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Color.white : Palette.surface3)
                        .frame(width: i == step ? 18 : 6, height: 6)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: step)
            Spacer()
            if step > 0 {
                Button("Back") { go(-1) }
                    .buttonStyle(NBButtonStyle(kind: .secondary, compact: true))
            }
            Button {
                if step == steps - 1 { finish() } else { go(1) }
            } label: {
                Text(step == 0 ? "Let's go" : step == steps - 1 ? "Start coding" : "Next")
            }
            .buttonStyle(NBButtonStyle(kind: .primary, compact: true))
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    private func go(_ delta: Int) {
        forward = delta > 0
        step = min(max(0, step + delta), steps - 1)
        if step == steps - 1 { pet.party() } else { pet.poke() }
    }
}

/// A solid switch that reads clearly even when the notch isn't the active window.
struct PillToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 10) {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? Color.white : Palette.surface3)
                    Circle().fill(isOn ? Color.black : Color.white.opacity(0.85))
                        .padding(2.5)
                }
                .frame(width: 32, height: 19)
                Text(label).font(.system(size: 12.5)).foregroundStyle(.white)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: isOn)
    }
}

/// A small static picture of the collapsed notch, for the tour.
struct MiniPill: View {
    enum Kind { case working, asking, done }
    let kind: Kind

    var body: some View {
        HStack(spacing: 7) {
            switch kind {
            case .working:
                Image(systemName: "asterisk").font(.system(size: 11, weight: .heavy)).foregroundStyle(Color.claude)
                Text("checkout").fontWeight(.semibold).foregroundStyle(.white)
                Text("running the tests").foregroundStyle(Palette.text2)
                Spacer(minLength: 4)
                Text("3/5").monospacedDigit().foregroundStyle(Palette.text2)
            case .asking:
                Circle().fill(Color.approval).frame(width: 7, height: 7)
                Text("api").fontWeight(.semibold).foregroundStyle(.white)
                Text("wants to run a command").foregroundStyle(Color.approval)
                Spacer(minLength: 4)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.black, Color.success)
                Text("landing").fontWeight(.semibold).foregroundStyle(.white)
                Text("done").foregroundStyle(Color.success)
                Spacer(minLength: 4)
            }
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 12)
        .frame(width: 280, height: 26)
        .background(NotchShape(topRadius: 5, bottomRadius: 13).fill(Color.black))
    }
}
