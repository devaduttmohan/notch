import Foundation

/// What `notchctl claude` passes on from a Claude Code hook: only what Notch uses (tool inputs
/// and outputs can be large), with background tasks cut down to what Notch shows.
enum HookForward {
    static let kept = ["hook_event_name", "session_id", "cwd", "transcript_path", "message", "reason"]

    static func hook(_ hook: [String: Any]) -> [String: Any] {
        var out = hook.filter { kept.contains($0.key) }
        // At the end of a turn (Stop): what's still running in the background.
        if let tasks = hook["background_tasks"] as? [[String: Any]] {
            out["background_tasks"] = tasks.prefix(30).map(task)
        }
        // You sent a message (UserPromptSubmit): whether you typed it, never its text. What Claude
        // Code sends by itself (a background task's news, a compaction…) starts with a <tag>.
        if hook["hook_event_name"] as? String == "UserPromptSubmit", let prompt = hook["prompt"] as? String {
            let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            out["typed_prompt"] = !text.isEmpty && !text.hasPrefix("<")
        }
        // A command started in the background (PostToolUse): its id and description, as it starts.
        if let input = hook["tool_input"] as? [String: Any], input["run_in_background"] as? Bool == true,
           let id = (hook["tool_response"] as? [String: Any])?["backgroundTaskId"] as? String {
            let tool = hook["tool_name"] as? String ?? ""
            out["background_start"] = task(["id": id, "type": tool == "Bash" ? "shell" : tool.lowercased(),
                                             "description": input["description"] ?? ""])
        }
        return out
    }

    private static func task(_ entry: [String: Any]) -> [String: String] {
        func text(_ key: String, _ limit: Int) -> String { String((entry[key] as? String ?? "").prefix(limit)) }
        return ["id": text("id", 80), "type": text("type", 40), "description": text("description", 200), "status": text("status", 40)]
    }
}
