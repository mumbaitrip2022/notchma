import AppKit
import SwiftUI

/// "Start a new agent": project · agent · worktree · when · prompt.
struct LauncherView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: NotchUI
    @ObservedObject var prefs: Prefs
    @ObservedObject var launcher: Launcher

    @State private var project: String = ""
    @State private var agent: Agent = .claude
    @State private var worktree = false
    @State private var atReset = false
    @State private var prompt = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BandRow(gap: ui.cameraGap) {
                Button { ui.page = .home } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26).contentShape(Circle())
                }
                .buttonStyle(CircleIconButtonStyle())
                Text("New task").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            } trailing: {
                EmptyView()
            }
            .frame(height: max(ui.bandHeight, 30))
            .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 12) {
                row("Project") {
                    Menu {
                        ForEach(prefs.recentProjects, id: \.self) { p in
                            Button((p as NSString).lastPathComponent) { project = p }
                        }
                        if !prefs.recentProjects.isEmpty { Divider() }
                        Button("Choose folder…", action: chooseFolder)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill").foregroundStyle(Palette.text2)
                            Text(project.isEmpty ? "Choose a project" : (project as NSString).lastPathComponent)
                                .foregroundStyle(project.isEmpty ? Palette.text3 : .white)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Palette.text3)
                        }
                        .font(.system(size: 12.5, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                row("Agent") {
                    HStack(spacing: 6) {
                        ForEach(Agent.allCases) { a in
                            let available = launcher.cli[a] != nil
                            Button { agent = a } label: {
                                HStack(spacing: 6) {
                                    AgentGlyph(agent: a, size: 12, tinted: agent == a)
                                    Text(a.shortName)
                                }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(agent == a ? Color.black : (available ? Color.white : Palette.text3))
                                .padding(.horizontal, 10).frame(height: 26)
                                .background(Capsule().fill(agent == a ? Color.white : Palette.surface3))
                            }
                            .buttonStyle(.plain)
                            .disabled(!available)
                            .help(available ? "Start \(a.name)"
                                  : (launcher.cliChecked ? "\(Launcher.commands[a] ?? a.rawValue) isn't installed" : "Checking…"))
                        }
                    }
                }

                row("Options") {
                    HStack(spacing: 14) {
                        Toggle("Own worktree", isOn: $worktree)
                            .help("Run in a separate git worktree on a new branch, so parallel agents don't collide")
                            .disabled(Git.root(at: project) == nil)
                        if let reset = nextReset {
                            Toggle("Start at reset (\(Fmt.clock(reset)))", isOn: $atReset)
                                .help("Start automatically when \(agent.shortName)'s usage window resets")
                        }
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text2)
                }

                TextField("What should it do?", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(2...6)
                    .focused($focused)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.code))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(focused ? Color.white.opacity(0.25) : Palette.hairline, lineWidth: 1))

                HStack {
                    if !launcher.scheduled.isEmpty {
                        Text("\(launcher.scheduled.count) scheduled").font(.system(size: 11.5)).foregroundStyle(Palette.text3)
                    }
                    Spacer()
                    Button(action: start) {
                        Text(atReset && nextReset != nil ? "Schedule" : "Start").frame(minWidth: 70)
                    }
                    .buttonStyle(NBButtonStyle(kind: .primary))
                    .disabled(!canStart)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.surface1))

            if !launcher.scheduled.isEmpty {
                VStack(spacing: 6) {
                    ForEach(launcher.scheduled) { r in
                        HStack(spacing: 8) {
                            AgentGlyph(agent: r.agentValue, size: 12)
                            Text(r.projectName).fontWeight(.semibold).foregroundStyle(.white)
                            Text(ToolInfo.firstLine(r.prompt)).foregroundStyle(Palette.text2).lineLimit(1)
                            Spacer()
                            if let at = r.startAt { Text(Fmt.clock(at)).foregroundStyle(Palette.text3).monospacedDigit() }
                            Button { launcher.cancel(r.id) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).foregroundStyle(Palette.text3)
                        }
                        .font(.system(size: 11.5))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface1))
            }
        }
        .onAppear {
            if project.isEmpty { project = prefs.recentProjects.first ?? "" }
            if !launcher.cliChecked { launcher.refreshCLIs() }
            focused = true
        }
        .onChange(of: launcher.cli) { _, cli in
            if cli[agent] == nil, let first = Agent.allCases.first(where: { cli[$0] != nil }) { agent = first }
        }
        .onChange(of: focused) { _, f in ui.editing = f }
        .onDisappear { ui.editing = false }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.text3).frame(width: 56, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private var nextReset: Date? {
        store.activeLimits.first { $0.0 == agent }?.1.compactMap(\.resetsAt).filter { $0 > Date() }.min()
    }

    private var canStart: Bool {
        !project.isEmpty && FileManager.default.fileExists(atPath: project) && launcher.cli[agent] != nil
    }

    private func start() {
        guard canStart else { return }
        let r = LaunchRequest(agent: agent.rawValue, project: project, prompt: prompt,
                              worktree: worktree && Git.root(at: project) != nil,
                              startAt: atReset ? nextReset?.addingTimeInterval(60) : nil)
        launcher.submit(r)
        prefs.noteProject(project)
        prompt = ""
        focused = false
        ui.page = .home
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            project = url.path
            prefs.noteProject(url.path)
        }
    }
}
