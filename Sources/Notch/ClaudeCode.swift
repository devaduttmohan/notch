import AppKit

/// Claude Code hook events (forwarded by `notchctl claude`) become notch activity:
/// - Notification (needs permission, or idle waiting for input): a "Needs you" pill that
///   stays until that session moves on (you reply, a tool runs, the session ends).
/// - Stop: "Claude finished" with the start of Claude's last message, but only when the
///   turn took a while, so quick answers don't ping you.
/// - SessionEnd: "Session ended" with how long it ran. Sessions that end together (quitting
///   the app) share one; /clear and resume aren't endings, so they're quiet.
/// Both stay on the notch until you hover it and move away (or press Dismiss).
@MainActor final class ClaudeCode {
    /// Turns shorter than this finish quietly.
    static let quietTurn: TimeInterval = 15
    /// A prompt this soon after Claude was last seen working is a message folded into the
    /// running turn (sent while Claude works, or a background task reporting back), not a new turn.
    static let midTurn: TimeInterval = 5

    private let model: NotchModel
    /// Holds the Mac awake while a turn runs.
    var keepAwake: KeepAwake?
    /// Where each session lives (its app, tab, folder), for "Open in …".
    private var hosts: [String: SessionHost] = [:]
    /// Where a session lives, as far as Notch knows (for tests and the log).
    func host(for session: String) -> SessionHost? { hosts[session] }
    private var turnStarted: [String: Date] = [:]
    /// When each session last showed signs of working (a prompt, a tool finishing).
    private var lastWorking: [String: Date] = [:]
    /// When each session last got a "Claude finished" banner.
    private var lastFinished: [String: Date] = [:]
    private var endedSessions: [(session: String, project: String, ran: TimeInterval?)] = []
    private var endedTimer: Timer?

    init(model: NotchModel) {
        self.model = model
    }

    func handle(_ hook: [String: Any], ancestors: [Int] = [], appSession: String? = nil) {
        let event = hook["hook_event_name"] as? String ?? ""
        let session = hook["session_id"] as? String ?? "unknown"
        let project = Self.projectName(hook["cwd"] as? String)
        let now = Date()
        if hosts[session] == nil, !ancestors.isEmpty,
           let host = SessionHost.resolve(ancestors: ancestors, folder: hook["cwd"] as? String, appSession: appSession) {
            hosts[session] = host
            log("claude: \(project) runs in \(host.name)" + (host.tty.map { " (\($0))" } ?? "")
                + (appSession != nil ? " (its own session link)" : ""))
        } else if let appSession, hosts[session] != nil, hosts[session]?.appSession != appSession {
            hosts[session]?.appSession = appSession     // known from before this build: learns the link now
        }
        let host = hosts[session]?.name
        switch event {
        case "Notification":
            let message = (hook["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Waiting for you"
            model.claudeNeedsYou(ClaudeWait(sessionID: session, project: project, message: message, since: now, host: host))
            keepAwake?.claudeIdle(session: session)          // blocked on you: nothing to stay awake for
            log("claude: \(project) needs you — \(message)")
        case "UserPromptSubmit":
            let working = lastWorking[session].map { now.timeIntervalSince($0) < Self.midTurn } ?? false
            if !working { turnStarted[session] = now }
            lastWorking[session] = now
            model.claudeResumed(session: session)
            keepAwake?.claudeWorking(session: session, project: project)
        case "PreToolUse", "PostToolUse":
            lastWorking[session] = now
            model.claudeResumed(session: session)
            keepAwake?.claudeWorking(session: session, project: project)
        case "Stop":
            lastWorking[session] = nil
            model.claudeResumed(session: session)
            keepAwake?.claudeIdle(session: session)
            let took = turnStarted.removeValue(forKey: session).map { now.timeIntervalSince($0) }
            if let took, took < Self.quietTurn {
                return log("claude: \(project) finished in \(CommandAlerts.duration(took)) (quiet)")
            }
            let said = (hook["transcript_path"] as? String).flatMap(Self.lastAssistantLine)
            lastFinished[session] = now
            model.claudeUpdate(ClaudeUpdate(kind: .finished, sessions: [session], headline: "Claude finished",
                                            project: project,
                                            message: said ?? took.map { "after \(CommandAlerts.duration($0))" },
                                            host: host))
        case "SessionEnd":
            turnStarted[session] = nil
            lastWorking[session] = nil
            model.claudeResumed(session: session)
            keepAwake?.claudeIdle(session: session)
            let reason = hook["reason"] as? String ?? "other"
            log("claude: \(project) session ended (\(reason))")
            if reason == "clear" || reason == "resume" { return }         // it carries on as a new session
            // Just announced "finished" (a one-shot `claude -p` run)? That already said it.
            if let finished = lastFinished.removeValue(forKey: session), now.timeIntervalSince(finished) < 10 { return }
            let ran = (hook["transcript_path"] as? String).flatMap(Self.sessionStart).map { now.timeIntervalSince($0) }
            sessionEnded(session, project: project, ran: ran)
        default:
            break
        }
    }

    /// "Open in …": the session's app, tab or window. Unknown hosts fall back to the Claude app.
    func open(session: String) {
        if let host = hosts[session] {
            SessionJump.open(host)
        } else if let claude = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            SessionJump.bringForward(claude)
        }
    }

    /// Collects endings for a moment, so quitting the app with five sessions open is one banner.
    private func sessionEnded(_ session: String, project: String, ran: TimeInterval?) {
        endedSessions.append((session, project, ran))
        endedTimer?.invalidate()
        endedTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.announceEndedSessions() }
        }
    }

    private func announceEndedSessions() {
        let ended = endedSessions
        endedSessions = []
        guard let first = ended.first else { return }
        if ended.count == 1 {
            let ran = first.ran.flatMap { $0 > 0 && $0 < 86_400 ? " · ran \(CommandAlerts.duration($0))" : nil } ?? ""
            model.claudeUpdate(ClaudeUpdate(kind: .ended, sessions: [first.session], headline: "Session ended",
                                            project: first.project, message: "Claude Code\(ran)",
                                            host: hosts[first.session]?.name))
        } else {
            var projects: [String] = []
            for entry in ended where !projects.contains(entry.project) { projects.append(entry.project) }
            model.claudeUpdate(ClaudeUpdate(kind: .ended, sessions: ended.map(\.session),
                                            headline: "\(ended.count) Claude sessions ended", project: nil,
                                            message: projects.joined(separator: ", ")))
        }
    }

    /// The working folder's name ("~" for your home folder).
    nonisolated static func projectName(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "Claude Code" }
        if cwd == FileManager.default.homeDirectoryForCurrentUser.path { return "~" }
        return (cwd as NSString).lastPathComponent
    }

    /// The first line of Claude's last message, from the session transcript (JSON lines).
    /// Best effort: reads only the end of the file, and gives up quietly if the format differs.
    nonisolated static func lastAssistantLine(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 512_000 ? size - 512_000 : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  let message = entry["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            guard let said = texts.last?.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty else { continue }
            var first = String(said.split(whereSeparator: \.isNewline).first ?? Substring(said))
            first = first.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            first = first.trimmingCharacters(in: CharacterSet(charactersIn: "#-* ").union(.whitespaces))
            return first.count > 90 ? String(first.prefix(88)) + "…" : first
        }
        return nil
    }

    /// When the session began: the first timestamp in its transcript.
    nonisolated static func sessionStart(_ path: String) -> Date? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64_000), let text = String(data: data, encoding: .utf8) else { return nil }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in text.split(separator: "\n").prefix(200) {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let stamp = entry["timestamp"] as? String else { continue }
            if let date = format.date(from: stamp) { return date }
        }
        return nil
    }
}
