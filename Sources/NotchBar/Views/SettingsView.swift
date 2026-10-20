import AppKit
import SwiftUI

/// Everything configurable, in one window (gear menu → Settings…, or ⌘,).
struct SettingsView: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var rules: RuleStore
    @ObservedObject var calendar: CalendarWatcher
    var setAgent: (Agent, Bool) -> Void
    var applyCursorMode: () -> Void
    var uninstall: () -> Void = {}

    @State private var axTrusted = Paster.canPaste

    var body: some View {
        Form {
            Section("General") {
                Picker("Show on", selection: $prefs.screenMode) {
                    ForEach(Prefs.ScreenMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Sounds", isOn: $prefs.sounds)
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
                Text("Codex asks you to trust new hooks once: run /hooks in Codex. Cursor sends every shell command through hooks, so with notch approvals on, each one waits for you.")
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

            Section("Shortcuts") {
                Toggle("⌃⌥J — jump to the next thing waiting on you", isOn: $prefs.jumpShortcut)
                Toggle("⌃⌥V — dictate your next prompt", isOn: $prefs.voice)
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
