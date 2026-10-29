import AppKit
import SwiftUI

/// Everything configurable, in one window (gear menu → Settings…, or ⌘,).
struct SettingsView: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var rules: RuleStore
    @ObservedObject var calendar: CalendarWatcher
    @ObservedObject var ledger: DayLedger
    @ObservedObject var updater: Updater
    var openUpdate: () -> Void = {}
    var openTour: () -> Void = {}
    var openReport: () -> Void = {}
    var setAgent: (Agent, Bool) -> Void
    var applyCursorMode: () -> Void
    var uninstall: () -> Void = {}

    @State private var axTrusted = Paster.canPaste

    private var updateStatus: String {
        if let r = updater.release { return "NotchBar \(r.version) is available" }
        switch updater.phase {
        case .checking: return "Checking…"
        case .upToDate: return "You're on the latest version (\(updater.current))"
        case let .failed(m): return m
        default: return "Version \(updater.current)"
        }
    }

    var body: some View {
        Form {
            Section("General") {
                Picker("Show on", selection: $prefs.screenMode) {
                    ForEach(Prefs.ScreenMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show CPU, memory and disk", isOn: $prefs.showVitals)
                Toggle("Sounds", isOn: $prefs.sounds)
                Toggle("Notch pet and daily receipt", isOn: $prefs.showPet)
                if prefs.showPet {
                    TextField("Pet's name", text: Binding(
                        get: { ledger.petName },
                        set: { let n = String($0.trimmingCharacters(in: .whitespaces).prefix(14)); if !n.isEmpty { ledger.petName = n.lowercased() } }))
                }
                Toggle("Launch at login", isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.launchAtLogin = $0 }))
            }

            Section {
                ForEach(Agent.allCases) { agent in
                    Toggle(isOn: Binding(get: { prefs.installed.contains(agent) }, set: { setAgent(agent, $0) })) {
                        HStack(spacing: 8) {
                            AgentGlyph(agent: agent, size: 13)
                            Text(agent.name)
                            if !NotchController.agentDetected(agent) {
                                Text("not found").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Toggle("Approve Cursor commands in the notch", isOn: $prefs.cursorApprovals)
                    .onChange(of: prefs.cursorApprovals) { _, _ in applyCursorMode() }
                    .disabled(!prefs.installed.contains(.cursor))
            } header: {
                Text("Agents")
            } footer: {
                Text("NotchBar trusts its own hooks in Codex for you, so Codex shows up right away. Cursor sends every shell command through hooks, so with notch approvals on, each one waits for you.")
            }

            Section {
                Toggle("Auto-allow read-only commands", isOn: $prefs.readOnlyDefaults)
                Stepper("Trust window: \(prefs.trustMinutes) minutes", value: $prefs.trustMinutes, in: 5...240, step: 5)
                if rules.rules.isEmpty {
                    Text("No always-allowed commands yet. You're offered one after approving the same command twice.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rules.rules) { rule in
                        HStack {
                            Text(rule.display).font(.system(.body, design: .monospaced))
                            Text("\(rule.projectName) · \(Agent(rawValue: rule.agent)?.shortName ?? rule.agent)")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("used \(rule.uses)×").foregroundStyle(.secondary).monospacedDigit()
                            Button("Remove") { rules.remove(rule) }
                        }
                    }
                }
            } header: {
                Text("Approvals")
            } footer: {
                Text("Read-only: git status/diff/log, ls, cat, grep… with no pipes or redirects. Trust windows and rules never cover destructive commands.")
            }

            Section {
                Toggle("Usage nudges (limit forecast, unused window, full context)", isOn: $prefs.nudges)
                Toggle("Meeting awareness", isOn: $prefs.calendarAware)
                    .onChange(of: prefs.calendarAware) { _, on in
                        if on && calendar.access != .granted { calendar.requestAccess { ok in if !ok { prefs.calendarAware = false } } }
                        calendar.check()
                    }
                if prefs.calendarAware && calendar.access == .denied {
                    Text("Calendar access is off for NotchBar in System Settings › Privacy & Security › Calendars.")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("During meetings, only approvals and urgent alerts show; the rest wait in a digest.")
            }

            Section {
                Toggle("Watch GitHub Actions after an agent pushes", isOn: $prefs.githubCI)
                GitHubConnectRow()
            } header: {
                Text("GitHub")
            } footer: {
                Text("Shows CI for the pushed commit and taps you when it passes or fails. Public repos work as is. Private repos use your GitHub CLI login, which NotchBar borrows and never stores. Only the repo name and commit go to GitHub.")
            }

            Section {
                Toggle("Check for updates automatically", isOn: $prefs.autoUpdate)
                HStack {
                    Text(updateStatus).foregroundStyle(.secondary)
                    Spacer()
                    if updater.release != nil {
                        Button("See what's new", action: openUpdate)
                    } else {
                        Button("Check now") { updater.check(manual: true) }
                            .disabled(updater.phase == .checking)
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Once a day NotchBar asks GitHub for the latest release. Nothing about you or your code is sent. Updates are checked against GitHub's checksum and their code signature before they're installed.")
            }

            Section("Shortcuts") {
                Toggle("⌃⌥J  Jump to the next thing waiting on you", isOn: $prefs.jumpShortcut)
                Toggle("⌃⌥V  Dictate your next prompt", isOn: $prefs.voice)
                LabeledContent("While a request is waiting", value: "⌃⌥Y allow · ⌃⌥N deny · ⌃⌥A always · ⌃⌥T trust")
            }

            Section {
                Picker("Start new tasks in", selection: $prefs.launchTerminal) {
                    ForEach(Launcher.availableTerminals, id: \.id) { Text($0.name).tag($0.id) }
                }
                Toggle("Paste drafts into the terminal", isOn: $prefs.autoPaste)
                HStack {
                    Text("Accessibility")
                    Spacer()
                    if axTrusted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant…") {
                            Paster.requestPermission()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { axTrusted = Paster.canPaste }
                        }
                    }
                }
            } header: {
                Text("Terminal")
            } footer: {
                Text("Accessibility lets NotchBar paste drafts (it never presses Return) and raise the right Warp/Ghostty window. Without it, drafts are copied and you paste.")
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("NotchBar \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show Tour", action: openTour)
                Button("Report a Problem…", action: openReport)
                Button("Uninstall NotchBar…", role: .destructive, action: uninstall)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(.bar)
        }
        .frame(width: 560, height: 680)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axTrusted = Paster.canPaste
        }
    }
}

/// Hosts SettingsView in a normal window (the app itself has no Dock icon).
final class SettingsWindowController {
    private var window: NSWindow?
    private let makeView: () -> AnyView

    init(makeView: @escaping () -> AnyView) { self.makeView = makeView }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "NotchBar Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: makeView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Who NotchBar talks to GitHub as, and a one-click way to sign in.
struct GitHubConnectRow: View {
    @ObservedObject private var auth = GitHubAuth.shared

    var body: some View {
        HStack(spacing: 10) {
            GitHubMark().fill(.primary).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch auth.status {
            case .checking:
                ProgressView().controlSize(.small)
            case .connected:
                Button("Refresh") { auth.refresh() }
            case .signedOut, .noCLI:
                Button("Connect GitHub") { auth.connect() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .onAppear { auth.refresh() }
    }

    private var title: String {
        switch auth.status {
        case .checking: return "Checking your GitHub login"
        case let .connected(user): return "Connected as @\(user)"
        case .signedOut: return "Not connected"
        case .noCLI: return "Not connected"
        }
    }

    private var detail: String {
        switch auth.status {
        case .checking: return " "
        case .connected: return "Private repos work too"
        case .signedOut: return "Public repos work. Connect for private ones"
        case .noCLI: return "Public repos work. Connect installs the GitHub CLI and signs you in"
        }
    }
}
