import Foundation

enum Agent: String, CaseIterable {
    case claude, codex, cursor

    /// Process names to look for when walking up the process tree.
    var processNames: Set<String> {
        switch self {
        case .claude: return ["claude"]
        case .codex: return ["codex", "Codex"]
        case .cursor: return [] // the IDE outlives conversations; rely on idle cleanup
        }
    }
}

/// Converts each agent's hook payload into one shape the app understands:
/// hook_event_name ∈ SessionStart, SessionEnd, UserPromptSubmit, PreToolUse,
/// PostToolUse, PermissionRequest, Notification, Stop, Interrupt.
enum Normalizer {
    static func normalize(_ e: [String: Any], agent: Agent) -> [String: Any]? {
        // Internal control messages (debug builds) pass straight through.
        if (e["hook_event_name"] as? String)?.hasPrefix("_") == true { return e }
        switch agent {
        case .claude, .codex: return codexOrClaude(e)
        case .cursor: return cursor(e)
        }
    }

    /// Last `limit` characters of a tool's output (enough to read test results),
    /// so huge outputs never travel over the socket.
    static func outputTail(_ response: Any?, limit: Int = 4000) -> String? {
        var text = ""
        if let r = response as? [String: Any] {
            for k in ["stdout", "stderr", "output", "content"] {
                if let s = r[k] as? String, !s.isEmpty { text += (text.isEmpty ? "" : "\n") + s }
            }
        } else if let s = response as? String {
            text = s
        }
        guard !text.isEmpty else { return nil }
        return text.count > limit ? String(text.suffix(limit)) : text
    }

    static func clipMessage(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s.count > 8000 ? String(s.prefix(8000)) + "…" : s
    }

    private static func codexOrClaude(_ e: [String: Any]) -> [String: Any]? {
        guard e["session_id"] is String else { return nil }
        var out = e
        if let r = e["tool_response"] {
            out["tool_response"] = nil
            if let tail = outputTail(r) { out["_output_tail"] = tail }
        }
        if let m = clipMessage(e["last_assistant_message"] as? String) { out["last_assistant_message"] = m }
        // Codex may send the shell command as an argv array.
        if var input = e["tool_input"] as? [String: Any], let argv = input["command"] as? [String] {
            input["command"] = argv.joined(separator: " ")
            out["tool_input"] = input
        }
        return out
    }

    private static func cursor(_ e: [String: Any]) -> [String: Any]? {
        guard let name = e["hook_event_name"] as? String,
              let sid = (e["conversation_id"] as? String) ?? (e["session_id"] as? String), !sid.isEmpty
        else { return nil }

        let roots = e["workspace_roots"] as? [String] ?? []
        var out: [String: Any] = [
            "session_id": sid,
            "cwd": (e["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? roots.first ?? "",
        ]

        func mcpInput() -> [String: Any] {
            if let s = e["tool_input"] as? String, let d = s.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { return obj }
            return e["tool_input"] as? [String: Any] ?? [:]
        }
        func mcpName() -> String {
            "mcp__\(e["mcp_server_name"] as? String ?? "mcp")__\(e["tool_name"] as? String ?? "tool")"
        }

        switch name {
        case "sessionStart":
            out["hook_event_name"] = "SessionStart"
        case "sessionEnd":
            out["hook_event_name"] = "SessionEnd"
        case "beforeSubmitPrompt":
            out["hook_event_name"] = "UserPromptSubmit"
            out["prompt"] = e["prompt"] as? String ?? ""
        case "beforeShellExecution":
            out["hook_event_name"] = "PermissionRequest"
            out["tool_name"] = "Bash"
            out["tool_input"] = ["command": e["command"] as? String ?? ""]
        case "beforeMCPExecution":
            out["hook_event_name"] = "PermissionRequest"
            out["tool_name"] = mcpName()
            out["tool_input"] = mcpInput()
        case "afterShellExecution":
            out["hook_event_name"] = "PostToolUse"
            out["tool_name"] = "Bash"
            out["tool_input"] = ["command": e["command"] as? String ?? ""]
            if let tail = outputTail(e["output"]) { out["_output_tail"] = tail }
        case "afterAgentThought":
            out["hook_event_name"] = "AgentThought"
            out["text"] = String((e["text"] as? String ?? "").prefix(2000))
        case "afterAgentResponse":
            out["hook_event_name"] = "AgentResponse"
            out["last_assistant_message"] = clipMessage(e["text"] as? String) ?? ""
        case "afterMCPExecution":
            out["hook_event_name"] = "PostToolUse"
            out["tool_name"] = mcpName()
            out["tool_input"] = mcpInput()
        case "afterFileEdit":
            out["hook_event_name"] = "PostToolUse"
            out["tool_name"] = "Edit"
            out["tool_input"] = ["file_path": e["file_path"] as? String ?? ""]
        case "postToolUse":
            out["hook_event_name"] = "PostToolUse"
            out["tool_name"] = e["tool_name"] as? String ?? "Tool"
            out["tool_input"] = e["tool_input"] as? [String: Any] ?? [:]
        case "postToolUseFailure":
            out["hook_event_name"] = "PostToolUseFailure"
            out["tool_name"] = e["tool_name"] as? String ?? "Tool"
            out["tool_input"] = e["tool_input"] as? [String: Any] ?? [:]
        case "stop":
            out["hook_event_name"] = "Stop"
            out["status"] = e["status"] as? String ?? "completed"
        default:
            return nil
        }
        return out
    }
}
