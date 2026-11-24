import AppKit
import CoreServices

/// Spotify and Apple Music, the desktop apps.
///
/// - Reading: both apps announce every play/pause/track change with a system-wide
///   notification anyone can listen to, so following them needs no permission.
/// - Controls (play/pause, skip, seek) use AppleScript; macOS asks once per app.
/// - Artwork and the exact playhead are also read with AppleScript, but only once that
///   permission exists, so following along never triggers a surprise prompt.
@MainActor final class DesktopMusic {
    var onUpdate: ((MusicApp, NowPlaying?) -> Void)?

    private var current: [MusicApp: NowPlaying] = [:]
    private var observers: [any NSObjectProtocol] = []

    func start() {
        let center = DistributedNotificationCenter.default()
        for app in MusicApp.allCases {
            observers.append(center.addObserver(forName: app.notificationName, object: nil, queue: .main) { [weak self] note in
                let broadcast = Broadcast(note.userInfo)
                MainActor.assumeIsolated { self?.received(broadcast, from: app) }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let app = MusicApp.allCases.first(where: { $0.bundleID == bundleID }) else { return }
                self?.set(app, nil)                       // the app quit
            }
        })
        // Already playing when Notch starts? Only knowable by asking, and only if allowed.
        for app in MusicApp.allCases where app.isRunning { refresh(app) }
    }

    // MARK: Following along

    /// The fields Notch uses from an app's announcement, copied out of its untyped userInfo.
    private struct Broadcast: Sendable {
        var state: String
        var title: String?
        var artist: String?
        var milliseconds: Double?        // Spotify: "Duration", Music: "Total Time"
        var position: Double?            // Spotify only: "Playback Position" (seconds)

        init(_ info: [AnyHashable: Any]?) {
            let info = info ?? [:]
            state = (info["Player State"] as? String ?? "").lowercased()
            title = info["Name"] as? String
            artist = info["Artist"] as? String
            milliseconds = (info["Duration"] as? Double) ?? (info["Total Time"] as? Double)
            position = info["Playback Position"] as? Double
        }
    }

    private func received(_ broadcast: Broadcast, from app: MusicApp) {
        let state = broadcast.state
        guard state == "playing" || state == "paused",
              let title = broadcast.title, !title.isEmpty else {
            set(app, nil)                                 // stopped, or nothing loaded
            return
        }
        let previous = current[app]
        let sameTrack = previous?.title == title
        let now = Date()
        let duration = broadcast.milliseconds.map { $0 / 1000 }
        let position: TimeInterval
        if let reported = broadcast.position {
            position = reported                           // Spotify includes the playhead
        } else if let previous, sameTrack {
            position = previous.playhead(at: now)         // Music doesn't: carry on from where we were
        } else {
            position = 0                                  // a new track starts from the top
        }
        set(app, NowPlaying(title: title,
                            artist: broadcast.artist ?? "",
                            source: app.name,
                            artworkURL: sameTrack ? previous?.artworkURL : nil,
                            artworkImage: sameTrack ? previous?.artworkImage : nil,
                            isPlaying: state == "playing",
                            canSkip: true,
                            canSeek: (duration ?? 0) > 0,
                            duration: (duration ?? 0) > 0 ? duration : nil,
                            position: position,
                            positionDate: now,
                            origin: .app(app)))
        if !sameTrack || broadcast.position == nil { refresh(app) }   // artwork, exact playhead
    }

    private func set(_ app: MusicApp, _ nowPlaying: NowPlaying?) {
        let before = current[app]
        if before?.title != nowPlaying?.title || before?.isPlaying != nowPlaying?.isPlaying {
            log("\(app.name): " + (nowPlaying.map { "\($0.isPlaying ? "playing" : "paused") \"\($0.title)\"" } ?? "stopped"))
        }
        current[app] = nowPlaying
        onUpdate?(app, nowPlaying)
    }

    /// Ask the app directly, but only if we're already allowed to (never prompts).
    private func refresh(_ app: MusicApp) {
        guard app.isRunning, Self.permission(app) == noErr, let reply = Self.query(app) else { return }
        guard reply.state == "playing" || reply.state == "paused" else { return set(app, nil) }
        var nowPlaying = current[app] ?? NowPlaying(title: reply.title, artist: reply.artist, source: app.name,
                                                    artworkURL: nil, isPlaying: false, canSkip: true, origin: .app(app))
        nowPlaying.title = reply.title
        nowPlaying.artist = reply.artist
        nowPlaying.isPlaying = reply.state == "playing"
        nowPlaying.duration = reply.duration > 0 ? reply.duration : nil
        nowPlaying.canSeek = reply.duration > 0
        nowPlaying.position = reply.position
        nowPlaying.positionDate = Date()
        if let url = reply.artworkURL { nowPlaying.artworkURL = url }
        if let image = reply.artworkImage { nowPlaying.artworkImage = image }
        set(app, nowPlaying)
    }

    // MARK: Controls

    func perform(_ action: MediaAction, on app: MusicApp) {
        let verb: String
        switch action {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .nexttrack: verb = "next track"
        case .previoustrack: verb = "previous track"
        case .seek(let time): verb = "set player position to \(time)"
        }
        let script = "tell application \"\(app.scriptName)\" to \(verb)"
        // Off the main thread: the first time, macOS asks for permission and waits for the answer.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.refresh(app) }   // artwork, now that we may be allowed
            }
        }
    }

    // MARK: AppleScript

    /// noErr: allowed. Anything else (not asked yet, denied, app not running): don't touch it.
    nonisolated static func permission(_ app: MusicApp) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: app.bundleID)
        guard let descriptor = target.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(descriptor, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
    }

    private struct Reply {
        var state: String
        var title = ""
        var artist = ""
        var duration: TimeInterval = 0
        var position: TimeInterval = 0
        var artworkURL: URL?
        var artworkImage: NSImage?
    }

    private static func query(_ app: MusicApp) -> Reply? {
        // Spotify gives duration in ms and artwork as a URL; Music in seconds and as image data.
        let source = app == .spotify ? """
            tell application "Spotify"
              if player state is stopped then return {"stopped"}
              set t to current track
              return {player state as string, name of t, artist of t, (duration of t) / 1000, player position, artwork url of t}
            end tell
            """ : """
            tell application "Music"
              if player state is stopped then return {"stopped"}
              set t to current track
              set art to missing value
              try
                set art to raw data of artwork 1 of t
              end try
              return {player state as string, name of t, artist of t, duration of t, player position, art}
            end tell
            """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else { return nil }
        let state = result.atIndex(1)?.stringValue ?? "stopped"
        guard result.numberOfItems >= 6 else { return Reply(state: state) }
        var reply = Reply(state: state)
        reply.title = result.atIndex(2)?.stringValue ?? ""
        reply.artist = result.atIndex(3)?.stringValue ?? ""
        reply.duration = result.atIndex(4)?.doubleValue ?? 0
        reply.position = result.atIndex(5)?.doubleValue ?? 0
        if let art = result.atIndex(6) {
            if app == .spotify, let text = art.stringValue, let url = URL(string: text), url.scheme == "https" {
                reply.artworkURL = url
            } else if app == .music, art.descriptorType != typeType, let image = NSImage(data: art.data) {
                reply.artworkImage = image
            }
        }
        return reply
    }
}
