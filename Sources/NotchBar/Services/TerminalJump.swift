import AppKit
import ApplicationServices

/// Brings you to the exact place an agent runs — tmux pane, iTerm/Terminal tab,
/// or the right Cursor/VS Code window — falling back gracefully to the app.
enum TerminalJump {
    private static let queue = DispatchQueue(label: "notchbar.jump", qos: .userInitiated)

    static let cursorBundle = "com.todesktop.230313mzl4w4u92"
    static let vscodeBundle = "com.microsoft.VSCode"

    static func jump(to s: Session) {
        let ref = Ref(session: s)
        queue.async {
            if let pane = ref.tmuxPane, let socket = ref.tmuxSocket { selectTmux(pane: pane, socket: socket) }

            var handled = false
            switch ref.terminalBundle {
            case "com.googlecode.iterm2":
                handled = runAppleScript(itermScript(guid: ref.itermGUID, tty: ref.tty))
            case "com.apple.Terminal":
                if let tty = ref.tty { handled = runAppleScript(terminalScript(tty: tty)) }
            case cursorBundle, vscodeBundle:
                handled = openFolder(ref.projectRoot, bundle: ref.terminalBundle!)
            default:
                break
            }
            DispatchQueue.main.async {
                guard !handled else { return }
                if let bundle = ref.terminalBundle, activate(bundle: bundle) {
                    raiseWindow(matching: ref.projectName, bundle: bundle)
                }
            }
        }
    }

    enum SubmitOutcome: Equatable { case typed, pasted, copied }

    /// What sending to an idle session will do, in plain words (for the UI).
    static func deliveryHint(for s: Session, pasteAllowed: Bool) -> String {
        let ref = Ref(session: s)
        let alive = s.pid > 1 && kill(s.pid, 0) == 0
        if alive && (ref.tmuxPane != nil || ref.terminalBundle == "com.googlecode.iterm2"
                     || (ref.terminalBundle == "com.apple.Terminal" && ref.tty != nil)) {
            return "Sends straight to its terminal"
        }
        let name = terminalName(ref.terminalBundle) ?? s.agent.shortName
        return pasteAllowed && Paster.canPaste ? "Pastes into \(name), then you press Return" : "Copies it, then jumps to \(name) to paste"
    }

    static func terminalName(_ bundle: String?) -> String? {
        switch bundle {
        case "dev.warp.Warp-Stable", "dev.warp.Warp": return "Warp"
        case "com.googlecode.iterm2": return "iTerm"
        case "com.apple.Terminal": return "Terminal"
        case "com.mitchellh.ghostty": return "Ghostty"
        case cursorBundle: return "Cursor"
        case vscodeBundle: return "VS Code"
        case "com.openai.codex": return "Codex"
        default: return nil
        }
    }

    /// Sends a prompt to an idle agent. Types it straight into the agent's own
    /// tmux pane / iTerm session / Terminal tab when that's possible — but only if
    /// the agent process is verified alive, so text never lands in a bare shell.
    /// Otherwise copies it, jumps there and (with Accessibility) pastes, never pressing Return.
    static func submit(_ text: String, to s: Session, pasteAllowed: Bool,
                       completion: @escaping (SubmitOutcome) -> Void) {
        let ref = Ref(session: s)
        let agentAlive = s.pid > 1 && kill(s.pid, 0) == 0
        // Agent prompts submit on Return, so send a single line.
        let line = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        queue.async {
            var typed = false
            if agentAlive && !line.isEmpty {
                if let pane = ref.tmuxPane, let socket = ref.tmuxSocket {
                    typed = tmuxSend(pane: pane, socket: socket, line: line)
                } else if ref.terminalBundle == "com.googlecode.iterm2" {
                    typed = runAppleScript(itermWriteScript(guid: ref.itermGUID, tty: ref.tty, line: line))
                } else if ref.terminalBundle == "com.apple.Terminal", let tty = ref.tty {
                    typed = runAppleScript(terminalWriteScript(tty: tty, line: line))
                }
            }
            DispatchQueue.main.async {
                if typed { completion(.typed); return } // stay where you are — no focus stealing
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                jump(to: s)
                if pasteAllowed && Paster.canPaste {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { Paster.paste() }
                    completion(.pasted)
                } else {
                    completion(.copied)
                }
            }
        }
    }

    private static func tmuxSend(pane: String, socket: String, line: String) -> Bool {
        guard let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return false }
        guard run(tmux, ["-S", socket, "send-keys", "-t", pane, "-l", line], timeout: 3) != nil else { return false }
        return run(tmux, ["-S", socket, "send-keys", "-t", pane, "Enter"], timeout: 3) != nil
    }

    private static func itermWriteScript(guid: String?, tty: String?, line: String) -> String {
        let g = escape(guid ?? "-"), t = escape(tty ?? "-")
        return """
        tell application id "com.googlecode.iterm2"
          repeat with w in windows
            repeat with tb in tabs of w
              repeat with s in sessions of tb
                if (unique id of s is "\(g)") or (tty of s is "\(t)") then
                  tell s to write text "\(escape(line))"
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return "miss"
        """
    }

    private static func terminalWriteScript(tty: String, line: String) -> String {
        """
        tell application id "com.apple.Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(escape(tty))" then
                do script "\(escape(line))" in t
                return "ok"
              end if
            end repeat
          end repeat
        end tell
        return "miss"
        """
    }

    /// Everything needed off the main thread, captured up front.
    private struct Ref {
        let tty: String?
        let tmuxPane: String?
        let tmuxSocket: String?
        let itermGUID: String?
        let terminalBundle: String?
        let projectRoot: String
        let projectName: String

        init(session s: Session) {
            tty = s.tty
            tmuxPane = s.tmuxPane
            tmuxSocket = s.tmuxSocket?.split(separator: ",").first.map(String.init)
            itermGUID = s.itermSession?.split(separator: ":").last.map(String.init)
            projectRoot = s.projectRoot.isEmpty ? s.cwd : s.projectRoot
            projectName = s.projectName
            terminalBundle = Ref.bundle(for: s)
        }

        static func bundle(for s: Session) -> String? {
            switch s.termProgram {
            case "iTerm.app": return "com.googlecode.iterm2"
            case "Apple_Terminal": return "com.apple.Terminal"
            case "WarpTerminal":
                return ["dev.warp.Warp-Stable", "dev.warp.Warp"].first { isRunning($0) } ?? "dev.warp.Warp-Stable"
            case "ghostty": return "com.mitchellh.ghostty"
            case "vscode": return isRunning(cursorBundle) ? cursorBundle : vscodeBundle
            default: break
            }
            if !s.bundleID.isEmpty { return s.bundleID }
            return s.agent.fallbackBundleIDs.first
        }
    }

    // MARK: per-terminal strategies

    private static func selectTmux(pane: String, socket: String) {
        guard let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        for args in [["switch-client", "-t", pane], ["select-window", "-t", pane], ["select-pane", "-t", pane]] {
            _ = run(tmux, ["-S", socket] + args, timeout: 2)
        }
    }

    private static func itermScript(guid: String?, tty: String?) -> String {
        let g = escape(guid ?? "-"), t = escape(tty ?? "-")
        return """
        tell application id "com.googlecode.iterm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if (unique id of s is "\(g)") or (tty of s is "\(t)") then
                  select w
                  select t
                  select s
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return "miss"
        """
    }

    private static func terminalScript(tty: String) -> String {
        """
        tell application id "com.apple.Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(escape(tty))" then
                set selected of t to true
                set index of w to 1
                activate
                return "ok"
              end if
            end repeat
          end repeat
        end tell
        return "miss"
        """
    }

    /// Opening a folder in Cursor/VS Code focuses the window that already has it.
    private static func openFolder(_ path: String, bundle: String) -> Bool {
        guard !path.isEmpty, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return false }
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: config) { _, error in
            ok = error == nil
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 3)
        return ok
    }

    // MARK: helpers

    static func isRunning(_ bundle: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
    }

    @discardableResult
    static func activate(bundle: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return false }
        return app.activate()
    }

    /// With Accessibility permission, raise the window whose title mentions the project.
    private static func raiseWindow(matching name: String, bundle: String) {
        guard AXIsProcessTrusted(), !name.isEmpty,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for w in windows {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &title)
            if let t = title as? String, t.localizedCaseInsensitiveContains(name) {
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
                return
            }
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Runs AppleScript out of process (never blocks the UI); true if it reported "ok".
    private static func runAppleScript(_ script: String) -> Bool {
        run("/usr/bin/osascript", ["-e", script], timeout: 4)?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
    }

    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        guard let r = Shell.run(path, args, timeout: timeout), r.ok else { return nil }
        return r.stdout
    }
}

/// Types ⌘V into the frontmost app (needs Accessibility permission). Never presses Return.
enum Paster {
    static var canPaste: Bool { AXIsProcessTrusted() }

    static func paste() {
        guard canPaste, let src = CGEventSource(stateID: .combinedSessionState) else { return }
        let v: CGKeyCode = 9 // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
