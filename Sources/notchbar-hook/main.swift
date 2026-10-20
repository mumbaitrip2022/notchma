// notchbar-hook — bridge between coding-agent hooks and NotchBar.app.
//
// Claude Code, Codex and Cursor run this for their hook events and pipe the
// event JSON to stdin. We normalise it, forward it to the app over a Unix
// socket and, for permission requests, wait for the user's answer.
//
// Fail-safe: if anything goes wrong (app not running, timeout, bad input) we
// hand the decision back to the agent's own approval flow, so nothing blocks.

import Darwin
import Foundation

signal(SIGPIPE, SIG_IGN)

let socketPath = NSHomeDirectory() + "/Library/Application Support/NotchBar/nb.sock"

// Tools whose "permission" is really a question for the user: leave them to the agent UI.
let passthroughTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

// Must stay below the `timeout` written by the installer (600s).
let replyTimeoutSeconds = 585

// MARK: - Arguments

var args = Array(CommandLine.arguments.dropFirst())
var agent = Agent.claude
let statusLineMode = args.contains("--statusline")
args.removeAll { $0 == "--statusline" }
if let i = args.firstIndex(of: "--agent"), i + 1 < args.count {
    agent = Agent(rawValue: args[i + 1]) ?? .claude
    args.removeSubrange(i...(i + 1))
}

if let cmd = args.first {
    // Targets: claude, codex, cursor, or cursor-approve (cursor with notch approvals).
    let tokens = args.count > 1 ? Array(args.dropFirst()) : ["claude"]
    let cursorApprovals = tokens.contains("cursor-approve")
    let targets: [Agent] = tokens.compactMap { Agent(rawValue: $0 == "cursor-approve" ? "cursor" : $0) }
    switch cmd {
    case "install":
        let ok = targets.allSatisfy {
            Installer.install(agent: $0, hookPath: Installer.selfPath(), cursorApprovals: cursorApprovals)
        }
        exit(ok ? 0 : 1)
    case "uninstall":
        let ok = targets.allSatisfy { Installer.uninstall(agent: $0) }
        exit(ok ? 0 : 1)
    case "status":
        for a in Agent.allCases { print("\(a.rawValue): \(Installer.isInstalled(agent: a) ? "installed" : "not installed")") }
        exit(0)
    default:
        fputs("usage: notchbar-hook [--agent claude|codex|cursor] [install|uninstall|status] [agents…]\n", stderr)
        exit(2)
    }
}

// MARK: - Statusline mode (Claude Code)
// Forwards model / context / cost / plan limits to the app, prints a compact line.

if statusLineMode {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    if let sid = j["session_id"] as? String {
        var ev: [String: Any] = ["hook_event_name": "StatusLine", "session_id": sid, "_agent": "claude",
                                 "_bundle_id": ProcessInfo.processInfo.environment["__CFBundleIdentifier"] ?? "",
                                 "_term_program": ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "",
                                 "_agent_pid": Int(findAgentPID(names: ["claude"]))]
        for k in ["cwd", "transcript_path", "model", "context_window", "cost", "rate_limits"] { ev[k] = j[k] }
        if var payload = try? JSONSerialization.data(withJSONObject: ev) {
            payload.append(0x0A)
            let fd = connectSocket(path: socketPath)
            if fd >= 0 { _ = writeAll(fd: fd, data: payload); close(fd) }
        }
    }
    var parts: [String] = []
    if let m = (j["model"] as? [String: Any])?["display_name"] as? String { parts.append(m) }
    if let c = (j["context_window"] as? [String: Any])?["used_percentage"] as? Double { parts.append("ctx \(Int(c))%") }
    if let rl = j["rate_limits"] as? [String: Any] {
        for (k, label) in [("five_hour", "5h"), ("seven_day", "week")] {
            if let u = (rl[k] as? [String: Any])?["used_percentage"] as? Double { parts.append("\(label) \(Int(u))%") }
        }
    }
    print(parts.joined(separator: " · "))
    exit(0)
}

// MARK: - Hook mode

let input = FileHandle.standardInput.readDataToEndOfFile()
let raw = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
let rawEvent = raw["hook_event_name"] as? String ?? ""

/// What we must print if the app can't answer.
func fallbackOutput() -> [String: Any]? {
    guard agent == .cursor else { return nil }
    switch rawEvent {
    case "beforeSubmitPrompt": return ["continue": true]
    case "beforeShellExecution", "beforeMCPExecution": return ["permission": "ask"]
    default: return nil
    }
}

func finish(_ out: [String: Any]?) -> Never {
    if let out, let data = try? JSONSerialization.data(withJSONObject: out) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }
    exit(0)
}

guard var event = Normalizer.normalize(raw, agent: agent) else { finish(fallbackOutput()) }

let env = ProcessInfo.processInfo.environment
event["_agent"] = agent.rawValue
event["_term_program"] = env["TERM_PROGRAM"] ?? ""
event["_bundle_id"] = env["__CFBundleIdentifier"] ?? ""
let agentPID = findAgentPID(names: agent.processNames)
event["_agent_pid"] = Int(agentPID)
// Exact terminal identity, so the app can jump to the right tab/pane.
if let tty = ttyName(of: agentPID > 1 ? agentPID : getppid()) { event["_tty"] = tty }
if let pane = env["TMUX_PANE"], !pane.isEmpty { event["_tmux_pane"] = pane }
if let tmux = env["TMUX"], !tmux.isEmpty { event["_tmux"] = tmux }
if let s = env["ITERM_SESSION_ID"], !s.isEmpty { event["_iterm_session"] = s }

let eventName = event["hook_event_name"] as? String ?? ""
let toolName = event["tool_name"] as? String ?? ""
let wantsReply = eventName == "PermissionRequest" && !passthroughTools.contains(toolName)
event["_await"] = wantsReply

guard var payload = try? JSONSerialization.data(withJSONObject: event) else { finish(fallbackOutput()) }
payload.append(0x0A)

let fd = connectSocket(path: socketPath)
if fd < 0 { finish(fallbackOutput()) }

guard writeAll(fd: fd, data: payload) else { close(fd); finish(fallbackOutput()) }
if !wantsReply { close(fd); finish(fallbackOutput()) }

// Wait for the decision line.
var tv = timeval(tv_sec: replyTimeoutSeconds, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

var reply = Data()
var buf = [UInt8](repeating: 0, count: 4096)
while true {
    let n = read(fd, &buf, buf.count)
    if n <= 0 { break }
    reply.append(buf, count: n)
    if reply.contains(0x0A) { break }
}
close(fd)

guard let line = reply.split(separator: 0x0A).first,
      let answer = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
      let behavior = answer["behavior"] as? String
else { finish(fallbackOutput()) }

let message = (answer["message"] as? String) ?? "Denied from NotchBar."

switch agent {
case .cursor:
    switch behavior {
    case "allow": finish(["permission": "allow"])
    case "deny": finish(["permission": "deny", "user_message": message, "agent_message": message])
    default: finish(["permission": "ask"])
    }
case .claude, .codex:
    switch behavior {
    case "allow":
        finish(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]])
    case "deny":
        finish(["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                       "decision": ["behavior": "deny", "message": message]]])
    default:
        finish(nil) // no decision → the agent shows its normal prompt
    }
}

// MARK: - Helpers

func connectSocket(path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return -1 }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var sndTimeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sndTimeout, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
    let bytes = Array(path.utf8)
    guard bytes.count <= maxLen else { close(fd); return -1 }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    if rc != 0 { close(fd); return -1 }
    return fd
}

func writeAll(fd: Int32, data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return false }
        var off = 0
        while off < raw.count {
            let n = write(fd, base + off, raw.count - off)
            if n <= 0 { return false }
            off += n
        }
        return true
    }
}

/// Walk up the process tree to the agent process (used to notice when it exits).
/// Returns 0 if not found, so the app falls back to idle-based cleanup.
func findAgentPID(names: Set<String>) -> pid_t {
    guard !names.isEmpty else { return 0 }
    var pid = getppid()
    for _ in 0..<8 {
        guard pid > 1, let info = procInfo(pid) else { break }
        if names.contains(info.name) { return pid }
        pid = info.ppid
    }
    return 0
}

/// "/dev/ttys003" for a process's controlling terminal, if it has one.
func ttyName(of pid: pid_t) -> String? {
    var kp = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
    let dev = kp.kp_eproc.e_tdev
    guard dev != UInt32.max, dev != 0, let name = devname(dev, S_IFCHR) else { return nil }
    let s = String(cString: name)
    return s.isEmpty || s == "??" ? nil : "/dev/" + s
}

func procInfo(_ pid: pid_t) -> (name: String, ppid: pid_t)? {
    var kp = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw -> String in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    return (name, kp.kp_eproc.e_ppid)
}
