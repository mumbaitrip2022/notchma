import AppKit
import SwiftUI

/// "Report a problem": you describe it, NotchBar adds the boring details, you see every
/// word before anything leaves your Mac, and GitHub opens with the issue filled in.
struct ReportView: View {
    @ObservedObject var ui: NotchUI
    @ObservedObject var prefs: Prefs
    let pet: PetBrain
    /// A crash report macOS wrote for NotchBar, if there is a recent one.
    let crash: Diagnostics.Crash?

    @State private var what = ""
    @State private var parts = Diagnostics.Parts()
    @State private var showPreview = false
    @State private var feedback: String?
    @FocusState private var focused: Bool

    private var report: String {
        Diagnostics.report(what: what, parts: parts, prefs: prefs, crash: crash)
    }

    private var title: String {
        let first = what.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if !first.isEmpty { return String(first.prefix(80)) }
        return crash != nil ? "NotchBar crashed" : "Problem report"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BandRow(gap: ui.cameraGap) {
                Button { ui.page = .home } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26).contentShape(Circle())
                }
                .buttonStyle(CircleIconButtonStyle())
                Text("Report a problem").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            } trailing: {
                EmptyView()
            }
            .frame(height: max(ui.bandHeight, 30))
            .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 12) {
                if let crash { crashCard(crash) }

                TextField(crash != nil ? "What were you doing when it crashed? (optional)"
                                       : "What happened, and what did you expect?",
                          text: $what, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(3...7)
                    .focused($focused)
                    .padding(11)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.code))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(focused ? Color.white.opacity(0.25) : Palette.hairline, lineWidth: 1))

                VStack(alignment: .leading, spacing: 7) {
                    Text("ADD TO THE REPORT")
                        .font(.system(size: 10.5, weight: .bold)).tracking(0.8).foregroundStyle(Palette.text3)
                    HStack(spacing: 6) {
                        chip("Mac and app info", "desktopcomputer", $parts.includeEnvironment)
                        chip("Recent activity", "list.bullet.rectangle", $parts.includeActivity)
                        if crash != nil { chip("Crash details", "exclamationmark.triangle", $parts.includeCrash) }
                    }
                    Text("Activity is event names and timings only. Never your prompts, commands, code or file paths.")
                        .font(.system(size: 11)).foregroundStyle(Palette.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button { withAnimation(NotchUI.motion) { showPreview.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(showPreview ? 90 : 0))
                        Text(showPreview ? "Hide what's shared" : "See exactly what's shared")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.text2)
                }
                .buttonStyle(.plain)
                if showPreview {
                    CodeBox(estimate: 160, maxHeight: 170, header: nil) {
                        Text(report)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.8))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.opacity)
                }

                HStack(spacing: 8) {
                    Button(action: openIssue) { Label("Open GitHub issue", systemImage: "arrow.up.right.square.fill") }
                        .buttonStyle(NBButtonStyle(kind: .primary))
                    Button(action: copy) { Label("Copy", systemImage: "doc.on.doc") }
                        .buttonStyle(NBButtonStyle(kind: .secondary))
                    Spacer(minLength: 6)
                    if let feedback {
                        Text(feedback).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.success)
                            .transition(.opacity)
                    }
                }
                Text("Nothing is sent until you press Submit on GitHub. No GitHub account? Copy it and send it any way you like.")
                    .font(.system(size: 11)).foregroundStyle(Palette.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.surface1))
        }
        .animation(NotchUI.motion, value: feedback)
        .onChange(of: focused) { _, f in ui.editing = f }
        .onDisappear { if focused { ui.editing = false } }
        .onAppear {
            parts.includeCrash = crash != nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true }
        }
    }

    private func crashCard(_ c: Diagnostics.Crash) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PetCanvas(frame: PetBrain.Frame(pose: PetSprite.Pose(eyes: .wide, mouth: .open, ears: false)),
                      pixel: 2, ink: .white, roams: false, ground: 1)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text("NotchBar crashed \(Self.ago(c.date)) 😵")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(c.summary.isEmpty ? "macOS saved a crash report. It's included below." : c.summary)
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Palette.text2)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.danger.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.danger.opacity(0.25), lineWidth: 1))
    }

    private func chip(_ label: String, _ icon: String, _ on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: on.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(on.wrappedValue ? Color.black : Palette.text2)
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(on.wrappedValue ? Color.white : Palette.surface3))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: on.wrappedValue)
    }

    private func openIssue() {
        guard let url = Diagnostics.issueURL(title: title, body: report) else { return }
        // GitHub links have a size limit: keep the full text on the clipboard too.
        copyText()
        NSWorkspace.shared.open(url)
        DiagLog.log("report opened on GitHub")
        say("opened GitHub. full report is on your clipboard too")
        pet.pet()
    }

    private func copy() {
        copyText()
        say("copied ✨")
    }

    private func copyText() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("## " + title + "\n\n" + report, forType: .string)
    }

    private func say(_ t: String) {
        feedback = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if feedback == t { feedback = nil } }
    }

    static func ago(_ d: Date) -> String {
        let m = Int(Date().timeIntervalSince(d) / 60)
        if m < 2 { return "just now" }
        if m < 60 { return "\(m) min ago" }
        if m < 60 * 24 { return "\(m / 60)h ago" }
        return "on " + DateFormatter.localizedString(from: d, dateStyle: .short, timeStyle: .none)
    }
}
