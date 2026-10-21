import AppKit
import SwiftUI

/// "A new NotchBar is here": what's new, and a one-tap update you watch happen.
struct UpdateView: View {
    @ObservedObject var updater: Updater
    @ObservedObject var ui: NotchUI
    let pet: PetBrain
    private var justInstalled: Updater.Installed? { updater.justInstalled }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BandRow(gap: ui.cameraGap) {
                Button { ui.page = .home } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26).contentShape(Circle())
                }
                .buttonStyle(CircleIconButtonStyle())
                .disabled(updater.isBusy)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            } trailing: {
                EmptyView()
            }
            .frame(height: max(ui.bandHeight, 30))
            .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 14) {
                hero
                if !highlights.isEmpty { whatsNew }
                actions
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.surface1))
        }
        .onAppear { pet.poke() }
        .onChange(of: updater.isBusy) { _, busy in pet.printing = busy }
        .onDisappear { pet.printing = false }
    }

    private var title: String {
        if justInstalled != nil && updater.release == nil { return "What's new" }
        return updater.release == nil ? "Updates" : "New version"
    }

    private var highlights: [String] {
        if let r = updater.release { return r.highlights }
        if let j = justInstalled {
            return j.notes.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("- ") }.prefix(6)
                .map { String($0.dropFirst(2)).replacingOccurrences(of: "**", with: "") }
        }
        return []
    }

    // MARK: parts

    private var hero: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.surface3)
                PetView(brain: pet, pixel: 3, roams: false, ground: 2)
                    .frame(width: 72, height: 60)
                    .offset(x: -8)
            }
            .frame(width: 72, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(updater.current).foregroundStyle(updater.release == nil ? Color.white : Palette.text3)
                    if let r = updater.release {
                        Image(systemName: "arrow.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.text3)
                        Text(r.version).foregroundStyle(.white)
                    }
                }
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.text2)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        if let r = updater.release {
            let mb = r.size > 0 ? String(format: " · %.1f MB", Double(r.size) / 1_000_000) : ""
            return r.headline + mb
        }
        if let j = justInstalled, j.version == updater.current { return "you're on the newest NotchBar ✨" }
        switch updater.phase {
        case .checking: return "checking GitHub…"
        case .upToDate: return "you're on the latest ✨"
        default: return "NotchBar checks for updates once a day"
        }
    }

    private var whatsNew: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("WHAT'S NEW")
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Palette.text3)
            ForEach(Array(highlights.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "sparkle").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.text3)
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch updater.phase {
        case .available:
            HStack(spacing: 8) {
                Button { updater.install() } label: { Label("Update and restart", systemImage: "arrow.down.circle.fill") }
                    .buttonStyle(NBButtonStyle(kind: .primary))
                Button("Later") { ui.page = .home }
                    .buttonStyle(NBButtonStyle(kind: .secondary))
                Spacer()
                if let r = updater.release {
                    Button { NSWorkspace.shared.open(r.pageURL) } label: {
                        HStack(spacing: 4) { Text("Release notes"); Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold)) }
                    }
                    .buttonStyle(NBButtonStyle(kind: .plain, compact: true))
                }
            }
        case let .downloading(p):
            progress(p, "downloading \(Int(p * 100))%")
        case .verifying:
            progress(1, "checking it's the real deal 🔍")
        case .installing:
            progress(1, "swapping in the new version")
        case .relaunching:
            progress(1, "see you in a sec 👋")
        case let .failed(message):
            VStack(alignment: .leading, spacing: 10) {
                Text(message).font(.system(size: 12)).foregroundStyle(Color.danger)
                HStack(spacing: 8) {
                    if updater.release != nil {
                        Button("Try again") { updater.install() }.buttonStyle(NBButtonStyle(kind: .primary))
                    }
                    Button("Open release page") {
                        NSWorkspace.shared.open(updater.release?.pageURL
                            ?? URL(string: "https://github.com/\(Updater.repo)/releases/latest")!)
                    }
                    .buttonStyle(NBButtonStyle(kind: .secondary))
                }
            }
        case .checking:
            HStack(spacing: 8) {
                ActivityRing(color: .white, size: 13).frame(width: 13, height: 13)
                Text("checking…").font(.system(size: 12)).foregroundStyle(Palette.text2)
            }
        case .idle, .upToDate:
            Button { updater.check(manual: true) } label: { Label("Check for updates", systemImage: "arrow.clockwise") }
                .buttonStyle(NBButtonStyle(kind: .secondary))
        }
    }

    private func progress(_ p: Double, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.surface3)
                    Capsule().fill(Color.white).frame(width: max(8, g.size.width * p))
                }
            }
            .frame(height: 8)
            .animation(.easeOut(duration: 0.25), value: p)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Palette.text2)
                .contentTransition(.numericText())
        }
    }
}

/// Header chip while an update waits: a little gift with the version.
struct UpdateChip: View {
    let version: String
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                Image(systemName: "gift.fill").font(.system(size: 10.5, weight: .bold))
                Text(version).monospacedDigit()
            }
        }
        .buttonStyle(NBButtonStyle(kind: .secondary, compact: true))
        .help("NotchBar \(version) is ready. Click to see what's new")
    }
}
