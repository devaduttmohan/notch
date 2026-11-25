import CoreServices
import Foundation

/// The Claude app notes when you last looked at each of its Code sessions: a session file's
/// `lastFocusedAt`, which it sets when the session's view becomes visible (you switch to it, or
/// bring its window back). So opening a session yourself after its "Claude finished" arrived
/// reads that update, as Open in Claude does.
///
/// Light by design: macOS says when a file in the folder changes (no polling); with no such
/// update waiting, nothing is read; otherwise only the first 4 KB of the changed file (the
/// session id and the focus time are in its first kilobyte; the whole file is ~500 KB).
/// The folder and field are the Claude app's own, not a published interface: if they move,
/// this stops (logged once) and updates are read as before, from the island.
@MainActor final class ClaudeAppFocus {
    nonisolated static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions").path

    /// Updates about one session, waiting to be read: session → when it arrived.
    var waiting: () -> [String: Date] = { [:] }
    /// You looked at this session at this time.
    var onFocus: ((String, Date) -> Void)?

    private let path: String
    private var stream: FSEventStreamRef?
    private var unreadableLogged = false

    init(folder: String = ClaudeAppFocus.folder) {
        path = folder
    }

    func start() {
        guard FileManager.default.fileExists(atPath: path) else {
            return log("claude: no Claude app sessions folder, so opening a session there can't read its update")
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, { _, info, _, paths, _, _ in
            guard let info else { return }
            let watch = Unmanaged<ClaudeAppFocus>.fromOpaque(info).takeUnretainedValue()
            let changed = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray) as? [String] ?? []
            MainActor.assumeIsolated { watch.changed(changed) }
        }, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Files changed: for a session with an update waiting, did you look at it since?
    func changed(_ paths: [String]) {
        let waiting = waiting()
        guard !waiting.isEmpty else { return }
        for file in Set(paths) {
            let name = (file as NSString).lastPathComponent
            guard name.hasPrefix("local_"), name.hasSuffix(".json"),
                  let handle = FileHandle(forReadingAtPath: file) else { continue }
            let head = (try? handle.read(upToCount: 4096)) ?? Data()
            try? handle.close()
            guard let (session, focused) = Self.focus(in: head) else {
                if !head.isEmpty, !unreadableLogged {
                    unreadableLogged = true
                    log("claude: the Claude app's session files no longer start with the session and its focus time; opening a session there won't read its update")
                }
                continue
            }
            if let since = waiting[session], focused >= since { onFocus?(session, focused) }
        }
    }

    /// The session id and the time you last focused it, from the start of a session file.
    nonisolated static func focus(in head: Data) -> (session: String, focusedAt: Date)? {
        let text = String(decoding: head, as: UTF8.self)
        guard let session = text.firstMatch(of: #/"cliSessionId"\s*:\s*"([^"]+)"/#)?.output.1,
              let millis = text.firstMatch(of: #/"lastFocusedAt"\s*:\s*(\d+)/#)?.output.1,
              let value = Double(millis) else { return nil }
        return (String(session), Date(timeIntervalSince1970: value / 1000))
    }
}
