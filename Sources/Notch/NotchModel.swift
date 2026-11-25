import AppKit
import Combine
import SwiftUI

struct TimerInfo: Equatable {
    var endsAt: Date
    var duration: TimeInterval
}

/// The desktop music apps Notch follows.
enum MusicApp: String, CaseIterable, Sendable {
    case spotify, music

    var name: String { self == .spotify ? "Spotify" : "Apple Music" }
    var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
    /// The name AppleScript knows it by.
    var scriptName: String { self == .spotify ? "Spotify" : "Music" }
    /// The system-wide notification the app posts on every play/pause/track change.
    var notificationName: Notification.Name {
        Notification.Name(self == .spotify ? "com.spotify.client.PlaybackStateChanged" : "com.apple.Music.playerInfo")
    }
    @MainActor var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

struct NowPlaying: Equatable {
    enum Origin: Equatable {
        case demo
        case browser(tabId: Int)
        case app(MusicApp)
    }

    var title: String
    var artist: String
    var source: String          // "YouTube", "Spotify", "Demo", …
    var artworkURL: URL?
    var artworkImage: NSImage? = nil    // Apple Music hands over image data, not a URL
    var isPlaying: Bool
    var canSkip: Bool           // the player handles next/previous
    var canSeek: Bool = false
    var duration: TimeInterval? = nil   // nil: unknown, or a live stream
    var position: TimeInterval = 0      // the playhead as of `positionDate`
    var positionDate = Date()
    var rate: Double = 1
    var origin: Origin
    /// A video with a picture (from the browser), not sound alone: its art shows wide.
    var isVideo = false

    /// One entry per player in `NotchModel.players`.
    var key: String {
        switch origin {
        case .demo: "demo"
        case .browser: "browser"
        case .app(let app): app.rawValue
        }
    }

    /// Has a timeline to show (and maybe scrub).
    var hasTimeline: Bool { (duration ?? 0) > 0 }

    /// Where the playhead is at `date`, moving it along from the last report while playing.
    func playhead(at date: Date) -> TimeInterval {
        let elapsed = isPlaying ? max(0, date.timeIntervalSince(positionDate)) * rate : 0
        return min(duration ?? .infinity, position + elapsed)
    }
}

enum MediaAction: Equatable {
    case play, pause, nexttrack, previoustrack
    case seek(to: TimeInterval)

    /// The Media Session action name the extension expects.
    var name: String {
        switch self {
        case .play: "play"
        case .pause: "pause"
        case .nexttrack: "nexttrack"
        case .previoustrack: "previoustrack"
        case .seek: "seekto"
        }
    }
}

/// A brief drop-down, like the iPhone's AirPods or silent-mode banners. It shows for
/// `duration` seconds, then the island closes back to whatever it was showing.
struct Banner: Equatable, Identifiable {
    enum Tint: Equatable { case white, green, red, orange, claude, purple }
    enum Accessory: Equatable {
        case none
        case check
        case cross
        case battery(level: Int, charging: Bool)
        case count(Int)                       // how many are waiting
    }

    var id = UUID()
    var symbol: String
    var tint: Tint = .white
    var title: String
    var subtitle: String? = nil
    var accessory: Accessory = .none
    var duration: TimeInterval = 3.5
}

/// A Claude Code session waiting on you (needs permission, or idle waiting for input).
struct ClaudeWait: Equatable {
    var sessionID: String
    var project: String
    var message: String
    var since: Date
    var host: String? = nil       // the app it runs in ("Claude", "Warp", "Terminal"…), for "Open in …"
}

/// A Claude Code session finished a turn or ended. Unlike other banners it stays on the
/// notch until you've looked at it: hover the notch (it opens with the details), then move away.
struct ClaudeUpdate: Equatable, Identifiable {
    enum Kind: Equatable { case finished, ended }
    var id = UUID()
    var kind: Kind
    var sessions: [String]
    var headline: String          // "Claude finished", "Session ended", "3 Claude sessions ended"
    var project: String?          // nil when it covers several projects
    var message: String?          // the start of Claude's last reply, how long it ran, …
    var since = Date()
    var host: String? = nil       // the app the session runs in, for "Open in …"
    /// Had its seconds on the notch (Behaviour › Alerts › Hide after): unread in the open island only.
    var hidden = false

    /// The banner it shows as; `waiting` is how many updates there are in all.
    func banner(waiting: Int) -> Banner {
        Banner(id: id, symbol: "sparkle", tint: .claude,
               title: project.map { "\(headline) · \($0)" } ?? headline,
               subtitle: message,
               accessory: waiting > 1 ? .count(waiting) : (kind == .finished ? .check : .none),
               duration: .infinity)
    }
}

/// Claude Code work running in the background: a command, an agent, a watch… Its start comes
/// from the tool call that launched it; Claude Code's list at the end of each turn says what's
/// still running, and one that's left the list has finished (Claude Code doesn't say how).
struct BackgroundTask: Equatable, Identifiable {
    var id: String                  // Claude Code's task id
    var session: String
    var kind: String                // "shell", "subagent", "monitor", "workflow", …
    var title: String               // its description
    var project: String
    var started: Date?              // nil: first seen already running, so how long is unknown

    /// For the line under its name.
    var kindName: String {
        switch kind {
        case "shell": "command"
        case "subagent": "agent"
        case "monitor": "watching"
        case "": "task"
        default: kind
        }
    }
}

/// A calendar event worth showing: about to start, or under way.
struct Meeting: Equatable, Identifiable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var calendar: String
    var color: RGB
    var location: String?
    var joinURL: URL?
    var service: String?          // "Google Meet", "Zoom", "Teams", …
    /// Starting in the next couple of minutes or just started: it outranks music.
    var prominent = false

    func isLive(at date: Date) -> Bool { date >= start && date < end }
}

enum ProcessAction { case quit, forceQuit, snooze, ignore }

/// The meeting page's buttons: hide it until it starts, or skip it altogether.
enum MeetingAction { case dismiss, skip }

/// The Mac offline, or a VPN you use disconnected (from `NetworkWatch`), and since when.
struct NetworkTrouble: Equatable {
    enum Kind: Equatable {
        case offline
        case vpn(name: String, app: URL?)
    }
    static let offlineKey = "offline"
    var key: String                 // what Dismiss hides: offline, or that VPN
    var kind: Kind
    var since: Date

    var name: String {
        switch kind {
        case .offline: "offline"
        case .vpn(let name, _): name
        }
    }
    var title: String { kind == .offline ? "You're offline" : "\(name) is disconnected" }
    var symbol: String { kind == .offline ? "wifi.slash" : "shield.slash.fill" }
}

/// Your pull requests, as the island shows them: what's running, what's new.
struct PRSummary: Equatable {
    var prs: [PullRequest]                  // yours and review requests, newest activity first
    var unseen: Set<String>                 // PRs with something you haven't looked at yet
    var lastEvents: [String: PREvent]
    var mainRepo: String?

    var open: [PullRequest] { prs.filter { !$0.waitingOnMe } }
    var running: [PullRequest] { open.filter(\.running) }
    var needsYou: Bool { !unseen.isEmpty }
    /// Something to show in the pill: checks running, or news.
    var live: Bool { !running.isEmpty || needsYou }
    var checksDone: Int { running.reduce(0) { $0 + $1.checksDone } }
    var checksTotal: Int { running.reduce(0) { $0 + $1.checksTotal } }

    /// The PR page's list: PRs active in the last 7 days (anything with news or running checks
    /// counts): what's new first, then running, then the most recently active.
    var thisWeek: [PullRequest] {
        prs.filter { unseen.contains($0.id) || $0.running || $0.updatedAt >= Self.recentCutoff() }
            .sorted { a, b in
                let ka = (unseen.contains(a.id) ? 0 : a.running ? 1 : 2), kb = (unseen.contains(b.id) ? 0 : b.running ? 1 : 2)
                return ka != kb ? ka < kb : a.updatedAt > b.updatedAt
            }
    }

    /// Everything older, summed up under the list.
    var older: [PullRequest] {
        let recent = Set(thisWeek.map(\.id))
        return prs.filter { !recent.contains($0.id) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// A rolling week: seven days back from now.
    static func recentCutoff(_ now: Date = Date()) -> Date {
        now.addingTimeInterval(-7 * 86_400)
    }
}

extension Activity {
    var kind: ActivityKind {
        switch self {
        case .claude: .claude
        case .claudeUpdate: .claudeUpdates
        case .claudeBackground: .claudeBackground
        case .meeting: .meeting
        case .network: .network
        case .process: .process
        case .nowPlaying: .music
        case .timer: .timer
        case .pullRequests: .pullRequests
        case .builds: .builds
        case .load: .load
        case .home: .home
        }
    }
}

/// News from Flock about your PRs (or any PR news, when PR alerts are set to stay). Like a
/// Claude update it stays on the notch until you've looked at the PR page; a newer one from the
/// same source about the same PR replaces it.
struct PRUpdate: Equatable, Identifiable {
    var id = UUID()
    var prIDs: [String]
    var banner: Banner
    var since = Date()
    var source: AlertSource = .flock
    var hidden = false            // had its seconds on the notch; unread in the open island only
}

/// A build or command alert set to stay until seen: a build's until you've looked at the
/// builds page (or, without one, opened the island), a command's until you've opened the island.
struct Notice: Equatable, Identifiable {
    var id = UUID()
    var source: AlertSource       // .builds or .commands
    var banner: Banner
    var since = Date()
    var hidden = false
}

enum PRAction {
    case open(URL)
    case rerun(PullRequest.Check, PullRequest)
    /// The failed check's page if one failed, otherwise the PR's checks.
    case details(PullRequest)
}

/// The kinds of thing the island shows; the open island has a page for each one that's live.
enum ActivityKind: Hashable {
    case claude, claudeUpdates, claudeBackground, meeting, network, process, music, timer, pullRequests, builds, load, home

    var symbol: String {
        switch self {
        case .claude, .claudeUpdates, .claudeBackground: "sparkle"
        case .meeting: MeetingIcon.calendarName
        case .network: "wifi.slash"
        case .process: "flame.fill"
        case .music: "music.note"
        case .timer: "timer"
        case .pullRequests: PullRequestIcon.symbolName
        case .builds: "hammer.fill"
        case .load: "gauge.with.dots.needle.67percent"
        case .home: "clock"
        }
    }
    var title: String {
        switch self {
        case .claude: "Claude"
        case .claudeUpdates, .claudeBackground: "Claude"
        case .meeting: "Meeting"
        case .network: "Network"
        case .process: "Process"
        case .music: "Music"
        case .timer: "Timer"
        case .pullRequests: "Pull requests"
        case .builds: "Builds"
        case .load: "CPU & memory"
        case .home: "Now"
        }
    }
}

/// What the notch is showing.
enum Activity: Equatable {
    case claude(ClaudeWait)
    case claudeUpdate(ClaudeUpdate)
    case claudeBackground([BackgroundTask])
    case meeting(Meeting)
    case network(NetworkTrouble)
    case process(RunawayProcess)
    case pullRequests(PRSummary)
    case builds(BuildSummary)
    case load(LoadSnapshot)
    case home
    case timer(TimerInfo)
    case nowPlaying(NowPlaying)
}

@MainActor final class NotchModel: ObservableObject {
    @Published var layout: NotchLayout
    /// The pointer is on the island but it isn't open yet (Click / Hover & hold): it swells
    /// a little to say "click me".
    @Published var armed = false {
        didSet { if armed != oldValue { refreshStickyClock() } }
    }
    /// Nobody's at the Mac (screen locked, displays asleep, switched to another user): news set
    /// to hide by itself doesn't count its seconds.
    var away = false {
        didSet { if away != oldValue { refreshStickyClock() } }
    }
    /// The next or current meeting, kept up to date by `Meetings`.
    @Published var meeting: Meeting?
    /// The Mac offline, or a VPN you use down (from `NetworkWatch`).
    @Published var network: NetworkTrouble?
    /// A process working far too hard (from `SystemMonitor`).
    @Published var runaway: RunawayProcess?
    /// Keeping the Mac awake, and why (from `KeepAwake`).
    @Published var awake = AwakeState()
    /// Your pull requests (from `PRWatcher`).
    @Published var prSummary: PRSummary?
    /// Your Jenkins builds (from `JenkinsWatcher`).
    @Published var builds: BuildSummary?
    /// The Mac's CPU and memory, live (from `LoadMonitor`, while that module is on).
    @Published var load: LoadSnapshot?
    /// Set by the app: quit one of the apps on the CPU & memory page; that page is on screen
    /// (the monitor then looks every second).
    var loadQuit: ((LoadProcess) -> Void)?
    var loadPageShown: ((Bool) -> Void)?
    /// The Jenkins server, for the builds page's link.
    var jenkinsServer: URL?
    /// Set by the app: open a build's console (or Jenkins), and "you've seen the builds page".
    var buildAction: ((URL) -> Void)?
    var buildsSeen: (() -> Void)?
    /// The page the open island shows (nil: the most important one).
    @Published var page: ActivityKind? {
        didSet { trackVisibility() }
    }
    /// Set by the app.
    var processAction: ((ProcessAction, RunawayProcess) -> Void)?
    var meetingAction: ((MeetingAction, Meeting) -> Void)?
    var networkDismiss: (() -> Void)?
    var prAction: ((PRAction) -> Void)?
    /// You've looked at the PR page: what was new is now seen.
    var prsSeen: (() -> Void)?
    /// Brings a Claude session's app (and, where possible, its tab or window) to the front.
    var openClaudeSession: ((String) -> Void)?
    var toggleKeepAwake: (() -> Void)?
    /// The colour of the current album art (for the Ambient and Aurora backgrounds).
    @Published private(set) var artworkTint: RGB?
    /// The shown track's art: its width over its height, once loaded; and, for a video, the
    /// picture itself (the open island's backdrop).
    @Published private(set) var artworkAspect: CGFloat?
    @Published private(set) var videoStill: NSImage?
    /// A preview copy (the customiser's): no haptics, sounds or log lines.
    var quiet = false
    /// Set by the app: opens the customiser window.
    var openCustomiser: (() -> Void)?

    @Published var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            trackVisibility()
            if hovering { hoverStarted = Date() } else {
                acknowledgeClaudeUpdates()
                page = nil
                openPR = nil
                openPRChosen = false
                copyMenuPR = nil
            }
            refreshStickyClock()
        }
    }
    @Published var forcedState: NotchState? {    // --state flag, for development
        didSet { refreshStickyClock() }
    }
    @Published var timer: TimerInfo? {
        didSet { scheduleTimerCheck() }
    }
    /// Every player we know about, keyed by `NowPlaying.key`; `nowPlaying` picks one.
    @Published private(set) var players: [String: NowPlaying] = [:]
    /// Claude Code sessions waiting on you, newest first.
    @Published private(set) var claudeWaits: [ClaudeWait] = [] {
        didSet { refreshStickyClock() }
    }
    @Published private(set) var banner: Banner? {
        didSet { refreshStickyClock() }
    }
    /// Claude Code updates you haven't looked at yet, newest first.
    @Published private(set) var claudeUpdates: [ClaudeUpdate] = [] {
        didSet { refreshStickyClock() }
    }
    /// Flock's news about your PRs you haven't looked at yet, newest first.
    @Published private(set) var prUpdates: [PRUpdate] = [] {
        didSet { refreshStickyClock() }
    }
    /// Claude Code's background work, running now, in the order it started.
    @Published private(set) var backgroundTasks: [BackgroundTask] = []
    /// Build and command alerts set to stay until seen, newest first.
    @Published private(set) var notices: [Notice] = [] {
        didSet { refreshStickyClock() }
    }
    /// The section you last chose in the open island (a tab, a swipe, the bubble): the closed
    /// island keeps showing it, unless something needs you right now.
    @Published var pinned: ActivityKind?
    /// Bumped when the overlay is re-placed on a Space, so the view can grow back out of the notch.
    @Published var reappear = 0

    /// Set by the app: sends play/pause/skip/seek to whichever player owns the track.
    var sendMediaAction: ((MediaAction, NowPlaying) -> Void)?

    private var lastChange: [String: Date] = [:]
    private var bannerQueue: [Banner] = []
    private var bannerTimer: Timer?
    private var bannerDeadline: Date?
    private var hoverStarted: Date?
    private var updatesShownAt: Date?
    private var updatesRead = false
    private var prsShownAt: Date?
    private var buildsShownAt: Date?
    private var prUpdatesRead = false
    private var buildNoticesRead = false
    /// The unread news on the closed notch that's counting its seconds (Alerts › Hide after),
    /// and how long each has been on screen so far.
    private var stickyClock: (id: UUID, since: Date, seconds: TimeInterval)?
    private var stickyTimer: Timer?
    private var stickyShown: [UUID: TimeInterval] = [:]
    /// Build and command alerts that have been the banner on the notch while you were there:
    /// only those are read by opening the island.
    private var noticesShown: Set<UUID> = []
    private var artworkTintKey: String?
    private var settingsWatch: AnyCancellable?
    private var settings: NotchSettings { SettingsStore.shared.value }
    private var ticker: Timer?

    init(layout: NotchLayout) {
        self.layout = layout
        // Size, roundness and display re-shape the island; switching a module off clears it.
        settingsWatch = SettingsStore.shared.$value.dropFirst().sink { [weak self] new in
            MainActor.assumeIsolated { self?.settingsChanged(new) }
        }
    }

    private func settingsChanged(_ new: NotchSettings) {
        if layout.size != new.size || layout.roundness != new.roundness {
            layout.size = new.size
            layout.roundness = new.roundness
        }
        if !new.claude { claudeWaits.removeAll(); claudeUpdates.removeAll() }
        if !new.claude || !new.claudeBackground { backgroundTasks.removeAll() }
        if !new.timers { timer = nil }
        if !new.meetings { meeting = nil }
        if !new.network { network = nil }
        if !new.systemHealth { runaway = nil }
        if !new.pullRequests {
            prUpdates.removeAll()
            if pinned == .pullRequests { pinned = nil }
        }
        if !new.builds {
            builds = nil
            notices.removeAll { $0.source == .builds }
            if pinned == .builds { pinned = nil }
        }
        if !new.commands { notices.removeAll { $0.source == .commands } }
        if !new.loadMonitor {
            load = nil
            if pinned == .load { pinned = nil }
        }
        // A changed Alerts setting applies to the news on the notch now: a source set back to
        // Until seen brings its hidden news back. (This runs before the store takes the new
        // value, so it's passed in.)
        let staying = Set(AlertSource.allCases.filter { new.hideAfter($0) == nil })
        if staying.contains(.claude), claudeUpdates.contains(where: \.hidden) {
            claudeUpdates = claudeUpdates.map { var update = $0; update.hidden = false; return update }
        }
        if prUpdates.contains(where: { $0.hidden && staying.contains($0.source) }) {
            prUpdates = prUpdates.map { var update = $0; if staying.contains(update.source) { update.hidden = false }; return update }
        }
        if notices.contains(where: { $0.hidden && staying.contains($0.source) }) {
            notices = notices.map { var notice = $0; if staying.contains(notice.source) { notice.hidden = false }; return notice }
        }
        refreshStickyClock(new)
    }

    // MARK: What to show

    /// The player to show: playing beats paused; between equals, the one that changed last.
    var nowPlaying: NowPlaying? {
        guard settings.music else { return nil }
        return players.values.max { a, b in
            if a.isPlaying != b.isPlaying { return b.isPlaying }
            return (lastChange[a.key] ?? .distantPast) < (lastChange[b.key] ?? .distantPast)
        }
    }

    /// The compact pill: Claude waiting on you first, then playing media, a running timer,
    /// and paused media (the player stays, showing a play icon, so you can pick it back up).
    var compactActivity: Activity? { liveActivities.first }

    /// Everything going on, most important first: the pill shows the first, the bubble beside
    /// it the second. Things that need you lead; music outranks background work (a failed
    /// check doesn't take over your song; it shows in the bubble).
    var liveActivities: [Activity] {
        var list = priorityActivities
        // You chose PRs: they keep the pill even when nothing is running or new.
        if pinned == .pullRequests, settings.pullRequests, let prSummary, !prSummary.prs.isEmpty,
           !list.contains(where: { $0.kind == .pullRequests }) {
            list.append(.pullRequests(prSummary))
        }
        if pinned == .builds, settings.builds, let builds, !builds.all.isEmpty, !list.contains(where: { $0.kind == .builds }) {
            list.append(.builds(builds))
        }
        // CPU & memory, chosen: it keeps the pill while the Mac is calm too (set to When busy,
        // it otherwise shows only while busy). Set to Island only, it stays in the island.
        if pinned == .load, settings.loadMonitor, settings.loadPill != .never, let load,
           !list.contains(where: { $0.kind == .load }) {
            list.append(.load(load))
        }
        // The section you chose leads, after anything that needs you right now.
        if let pinned, let index = list.firstIndex(where: { $0.kind == pinned }) {
            let chosen = list.remove(at: index)
            let urgent = list.prefix { Self.isUrgent($0) }.count
            list.insert(chosen, at: urgent)
        }
        return list
    }

    /// Everything going on in plain priority order (no pinning): the open island's tabs keep
    /// this order, so choosing a tab never moves the tabs under your pointer.
    var priorityActivities: [Activity] {
        var list: [Activity] = []
        if let wait = claudeWaits.first { list.append(.claude(wait)) }
        if let meeting, meeting.prominent { list.append(.meeting(meeting)) }      // starting now beats music
        if let runaway { list.append(.process(runaway)) }
        if let network { list.append(.network(network)) }
        if let load = loadInPill, load.pressing { list.append(.load(load)) }   // the Mac is struggling: say so
        if let nowPlaying, nowPlaying.isPlaying { list.append(.nowPlaying(nowPlaying)) }
        if let meeting, !meeting.prominent { list.append(.meeting(meeting)) }
        if let timer { list.append(.timer(timer)) }
        if let builds, builds.live, settings.builds { list.append(.builds(builds)) }
        if !backgroundTasks.isEmpty, showsBackground { list.append(.claudeBackground(backgroundTasks)) }
        if let prSummary, prSummary.live, settings.pullRequests { list.append(.pullRequests(prSummary)) }
        if let load = loadInPill, !load.pressing { list.append(.load(load)) }  // calm ("Always"), or memory only elevated
        if let nowPlaying, !nowPlaying.isPlaying { list.append(.nowPlaying(nowPlaying)) }
        return list
    }

    /// CPU & memory, when the closed island should show it: always, or only while busy.
    private var loadInPill: LoadSnapshot? {
        guard settings.loadMonitor, let load else { return nil }
        switch settings.loadPill {
        case .always: return load
        case .busy: return load.busy ? load : nil
        case .never: return nil
        }
    }

    /// Claude waiting on you, a meeting starting now: these take the pill whatever you chose.
    static func isUrgent(_ activity: Activity) -> Bool {
        switch activity {
        case .claude: true
        case .meeting(let meeting): meeting.prominent
        default: false
        }
    }

    /// Sections the closed island can be pinned to.
    static let pinnable: Set<ActivityKind> = [.music, .pullRequests, .builds, .meeting, .timer, .process, .load]

    /// The bubble beside the pill: the next most important thing that's actually happening.
    /// Paused music never takes it (a lone ▶ beside your PRs is noise); it keeps its tab in
    /// the open island, and the pill when there's nothing else.
    var secondaryActivity: Activity? {
        bubbleCandidates.first
    }

    /// How many more beyond the pill and the bubble.
    var moreActivities: Int { max(0, bubbleCandidates.count - 1) }

    private var bubbleCandidates: [Activity] {
        liveActivities.dropFirst().filter { activity in
            if case let .nowPlaying(nowPlaying) = activity { return nowPlaying.isPlaying }
            return true
        }
    }

    /// The open island's pages: Claude first (opening it is how you read Claude's news), then
    /// everything live, then your PRs whenever you have any. With nothing going on: the clock.
    var pages: [Activity] {
        var list: [Activity] = []
        if let wait = claudeWaits.first { list.append(.claude(wait)) }
        // Unread news next, newest first: opening the island is how you read it.
        // What's on the notch first (hidden news has had its time there), then the newest.
        var news: [(onNotch: Bool, since: Date, page: Activity)] = []
        if let update = claudeUpdates.first {
            let shown = claudeUpdates.first { !$0.hidden }
            news.append((shown != nil, (shown ?? update).since, .claudeUpdate(update)))
        }
        if let update = prUpdates.first, let prSummary {
            let shown = prUpdates.first { !$0.hidden }
            news.append((shown != nil, (shown ?? update).since, .pullRequests(prSummary)))
        }
        if let notice = buildNews, let builds {
            news.append((!notice.hidden, notice.since, .builds(builds)))
        }
        list += news.sorted { $0.onNotch != $1.onNotch ? $0.onNotch : $0.since > $1.since }.map(\.page)
        list += priorityActivities.filter { activity in
            activity.kind != .claude && !list.contains { $0.kind == activity.kind }
                // Background work shows under Claude's page when there is one.
                && !(activity.kind == .claudeBackground && list.contains { [.claude, .claudeUpdates].contains($0.kind) })
        }
        // A section you chose that isn't live on its own still gets its tab. Not PRs or builds:
        // they always have theirs, in a fixed place below, so choosing one (which pins it)
        // never swaps them round.
        if let chosen = liveActivities.first(where: { $0.kind == pinned }), ![.pullRequests, .builds, .load].contains(chosen.kind),
           !list.contains(where: { $0.kind == chosen.kind }) {
            list.append(chosen)
        }
        if list.isEmpty { list.append(.home) }
        if let prSummary, settings.pullRequests, !prSummary.prs.isEmpty, !list.contains(where: { $0.kind == .pullRequests }) {
            list.append(.pullRequests(prSummary))
        }
        if let builds, settings.builds, !builds.all.isEmpty, !list.contains(where: { $0.kind == .builds }) {
            list.append(.builds(builds))
        }
        // CPU & memory always has its page, last, whatever the closed island does with it.
        if let load, settings.loadMonitor, !list.contains(where: { $0.kind == .load }) {
            list.append(.load(load))
        }
        return list
    }

    /// The open island: the page you picked; otherwise unread news first, otherwise whatever
    /// the closed pill was showing (the section you chose).
    var expandedActivity: Activity? {
        let pages = pages
        if let page, let chosen = pages.first(where: { $0.kind == page }) { return chosen }
        if let first = pages.first, [.claude, .claudeUpdates].contains(first.kind) || !prUpdates.isEmpty
            || buildNews != nil { return first }
        if let pill = liveActivities.first?.kind, let match = pages.first(where: { $0.kind == pill }) { return match }
        return pages.first
    }

    /// The newest build alert waiting to be seen, when there's a builds page to see it on.
    private var buildNews: Notice? {
        guard let builds, settings.builds, !builds.all.isEmpty else { return nil }
        return notices.first { $0.source == .builds }
    }

    /// How tall the PR page's content is (measured by the view), so the island can fit it.
    @Published var prContentHeight: CGFloat = 0
    /// The same for the CPU & memory page.
    @Published var loadContentHeight: CGFloat = 0
    /// The same for Claude's page while background work is listed on it.
    @Published var claudeContentHeight: CGFloat = 0

    /// The PR row that's open on the PR page. Until you choose, the newest PR with news.
    @Published private(set) var openPR: String?
    private var openPRChosen = false

    func openPRRow(in summary: PRSummary) -> String? {
        openPRChosen ? openPR : summary.thisWeek.first { summary.unseen.contains($0.id) }?.id
    }

    /// Open a PR row, or close it if it's the open one.
    func togglePR(_ id: String) {
        let current = prSummary.flatMap(openPRRow)
        openPR = current == id ? nil : id
        openPRChosen = true
        copyMenuPR = nil
    }

    /// The open row whose Copy ▾ list is showing.
    @Published var copyMenuPR: String?

    /// Which way the last page change went (+1 forward, -1 back), so pages slide the right way.
    @Published private(set) var pageStep = 1

    /// Show a page (a tab, a swipe, or the bubble you opened the island from). It becomes the
    /// section the closed island shows.
    func select(page kind: ActivityKind) {
        if Self.pinnable.contains(kind) { pinned = kind }
        let kinds = pages.map(\.kind)
        let from = expandedActivity.map(\.kind).flatMap { kinds.firstIndex(of: $0) } ?? 0
        let to = kinds.firstIndex(of: kind) ?? from
        pageStep = to >= from ? 1 : -1
        page = kind
    }

    /// Next or previous page (two-finger swipe).
    func turnPage(by step: Int) {
        let kinds = pages.map(\.kind)
        guard kinds.count > 1 else { return }
        let current = expandedActivity.map(\.kind).flatMap { kinds.firstIndex(of: $0) } ?? 0
        let next = min(max(current + step, 0), kinds.count - 1)
        guard next != current else { return }
        select(page: kinds[next])
        if !quiet { Haptics.tap(.alignment) }
    }

    /// Which open-panel layout to use: taller with a timeline, taller still for the PR list.
    var expandedKind: ExpandedKind {
        switch expandedActivity {
        case let .nowPlaying(nowPlaying) where nowPlaying.hasTimeline: return .media
        case .pullRequests:
            // The island hugs the list: taller when a row opens in a full list (rather than
            // dropping a row out of sight), shorter when there are only a few.
            guard prContentHeight > 0 else { return .list }
            return .listFit((prContentHeight + layout.geometry.notchSize.height + 16).rounded(.up))   // + camera row, padding
        case .builds(let summary):
            // Sized to its rows (up to three): a header, each row, and its bar (stages for a
            // pipeline, time for anything else that's running).
            let rows = summary.all.prefix(3).reduce(CGFloat(20)) { height, build in
                let running = build.building && !build.queued
                let bar: CGFloat = running || !build.stages.isEmpty ? 12 : 0
                return height + 44 + bar + (running && !build.stages.isEmpty ? 18 : 0)   // + the stage line under a running pipeline
            }
            return .listFit((rows + layout.geometry.notchSize.height + 16).rounded(.up))
        case .load:
            guard loadContentHeight > 0 else { return .list }
            return .listFit((loadContentHeight + layout.geometry.notchSize.height + 16).rounded(.up))
        case .claude, .claudeUpdate, .claudeBackground:
            // Claude's page grows to fit the background work listed on it.
            guard !backgroundTasks.isEmpty, showsBackground, claudeContentHeight > 0 else { return .standard }
            return .listFit((claudeContentHeight + layout.geometry.notchSize.height + 16).rounded(.up))
        default: return .standard
        }
    }

    /// The layout as drawn right now: the closed pill is a little wider while it shows CPU &
    /// memory (two readings, "23%" and "14.2 GB", where others show a glyph and one value).
    var liveLayout: NotchLayout {
        var live = layout
        if case .load = compactActivity { live.pillExtra = 14 }
        return live
    }

    /// Notes how long the Claude-updates and PR pages have been on screen: half a second or
    /// more counts as read (cleared once you move away).
    func trackVisibility() {
        let now = Date()
        let shown = hovering ? expandedActivity?.kind : nil
        if shown == .claudeUpdates { updatesShownAt = updatesShownAt ?? now }
        else if let since = updatesShownAt {
            if now.timeIntervalSince(since) >= 0.5 { updatesRead = true }
            updatesShownAt = nil
        }
        if shown == .pullRequests { prsShownAt = prsShownAt ?? now }
        else if let since = prsShownAt {
            if now.timeIntervalSince(since) >= 0.5 { prsSeen?(); prUpdatesRead = true }
            prsShownAt = nil
        }
        loadPageShown?(shown == .load)
        if shown == .builds { buildsShownAt = buildsShownAt ?? now }
        else if let since = buildsShownAt {
            if now.timeIntervalSince(since) >= 0.5 { buildsSeen?(); buildNoticesRead = true }
            buildsShownAt = nil
        }
    }

    /// Hover wins; otherwise the resting state.
    var state: NotchState {
        if let forcedState { return forcedState }
        if hovering { return .expanded }
        return restingState
    }

    /// Without the pointer: a passing banner, then "Claude needs you" (it's urgent, and you
    /// act on it in Claude anyway), then unread Claude updates as a banner that stays, then
    /// any activity; otherwise invisible.
    var restingState: NotchState {
        if banner != nil { return .banner }
        if claudeWaits.isEmpty, stickyLead != nil { return .banner }
        return compactActivity == nil ? .idle : .compact
    }

    /// The banner on screen: a passing one, or the newest unread Claude update.
    var displayedBanner: Banner? {
        banner ?? stickyBanner
    }

    /// The newest unread update (Claude's, a PR's, a build's or a command's) that hasn't had
    /// its seconds on the notch, with a count when several wait.
    var stickyBanner: Banner? { stickyLead?.banner }

    /// All unread news, hidden or not: what the menu bar and Clear Updates count.
    var unreadNews: Int { claudeUpdates.count + prUpdates.count + notices.count }

    /// The news the closed notch shows, and its own time (for Auto).
    private var stickyLead: (id: UUID, source: AlertSource, banner: Banner, own: TimeInterval)? {
        let waiting = unreadNews
        var lead: (id: UUID, source: AlertSource, banner: Banner, own: TimeInterval, since: Date)?
        // Newest first; on a tie, Claude's.
        func consider(_ id: UUID, _ source: AlertSource, _ since: Date, _ own: TimeInterval, _ banner: () -> Banner) {
            if lead.map({ since > $0.since }) ?? true { lead = (id, source, banner(), own, since) }
        }
        if let claude = claudeUpdates.first(where: { !$0.hidden }) {
            consider(claude.id, .claude, claude.since, 10) { claude.banner(waiting: waiting) }
        }
        for item in [prUpdates.first { !$0.hidden }.map { ($0.id, $0.source, $0.since, $0.banner) },
                     notices.first { !$0.hidden }.map { ($0.id, $0.source, $0.since, $0.banner) }] {
            guard let (id, source, since, banner) = item else { continue }
            consider(id, source, since, banner.duration) {
                var shown = banner
                shown.id = id
                shown.duration = .infinity
                if waiting > 1 { shown.accessory = .count(waiting) }
                return shown
            }
        }
        return lead.map { ($0.id, $0.source, $0.banner, $0.own) }
    }

    /// News set to hide by itself (Alerts › Hide after) counts its seconds only while it's the
    /// banner on the closed notch and you're there: not behind a passing banner or "Claude
    /// needs you", not while the island is open or the pointer rests on it, not while you're
    /// away. Then it leaves the notch, still unread in the open island.
    private func refreshStickyClock(_ current: NotchSettings? = nil) {
        let now = Date()
        let unread = Set(claudeUpdates.map(\.id) + prUpdates.map(\.id) + notices.map(\.id))
        noticesShown.formIntersection(unread)
        let onNotch = forcedState == nil && !hovering && !away && banner == nil && claudeWaits.isEmpty ? stickyLead : nil
        if let onNotch, notices.contains(where: { $0.id == onNotch.id }) { noticesShown.insert(onNotch.id) }
        var timed: (id: UUID, seconds: TimeInterval)?
        if let lead = onNotch, !armed, let hideAfter = (current ?? settings).hideAfter(lead.source) {
            timed = (lead.id, hideAfter > 0 ? hideAfter : (lead.own.isFinite && lead.own > 0 ? lead.own : 10))
        }
        if let clock = stickyClock, let timed, clock.id == timed.id, clock.seconds == timed.seconds { return }
        if stickyClock == nil, timed == nil { return }
        if let clock = stickyClock {
            stickyShown[clock.id, default: 0] += now.timeIntervalSince(clock.since) / Motion.debugSlowdown
        }
        stickyTimer?.invalidate()
        stickyTimer = nil
        stickyClock = nil
        stickyShown = stickyShown.filter { unread.contains($0.key) }
        guard let timed else { return }
        stickyClock = (timed.id, now, timed.seconds)
        let left = max(0, timed.seconds - stickyShown[timed.id, default: 0])
        stickyTimer = Timer.scheduledTimer(withTimeInterval: left * Motion.debugSlowdown, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideSticky(timed.id) }
        }
    }

    /// Its seconds are up: off the notch, and so is any older news set to hide (the badge
    /// counted it; it waits, unread, in the open island). A command's has nothing to show
    /// there, so it goes.
    private func hideSticky(_ id: UUID) {
        stickyTimer = nil
        stickyClock = nil
        let since = claudeUpdates.first { $0.id == id }?.since ?? prUpdates.first { $0.id == id }?.since
            ?? notices.first { $0.id == id }?.since
        guard let since else { return refreshStickyClock() }
        let current = settings
        func due(_ itemSince: Date, _ source: AlertSource) -> Bool { itemSince <= since && current.hideAfter(source) != nil }
        if claudeUpdates.contains(where: { !$0.hidden && due($0.since, .claude) }) {
            claudeUpdates = claudeUpdates.map { var update = $0; if due(update.since, .claude) { update.hidden = true }; return update }
        }
        if prUpdates.contains(where: { !$0.hidden && due($0.since, $0.source) }) {
            prUpdates = prUpdates.map { var update = $0; if due(update.since, update.source) { update.hidden = true }; return update }
        }
        if notices.contains(where: { !$0.hidden && due($0.since, $0.source) }) {
            notices = notices.compactMap { notice in
                guard due(notice.since, notice.source) else { return notice }
                if notice.source == .commands { return nil }
                var hidden = notice
                hidden.hidden = true
                return hidden
            }
        }
        // Brought back (set to stay again), they start their time afresh.
        let hidden = Set(claudeUpdates.filter(\.hidden).map(\.id) + prUpdates.filter(\.hidden).map(\.id) + notices.filter(\.hidden).map(\.id))
        stickyShown = stickyShown.filter { !hidden.contains($0.key) }
    }

    // MARK: Banners

    /// An alert from a source in Behaviour › Alerts (not Claude's: `claudeUpdate`). Set to
    /// hide after some seconds, a PR, build or command alert passes like any banner, for those
    /// seconds; Flock's, and any set to stay, wait as news until you've looked.
    func alert(_ banner: Banner, from source: AlertSource, about prIDs: [String] = []) {
        let current = settings
        // Not from a module that's off (a look that was under way when it was switched off).
        guard [.pullRequests, .flock].contains(source) ? current.pullRequests
                : source == .builds ? current.builds : source == .commands ? current.commands : true else { return }
        let hideAfter = current.hideAfter(source)
        switch source {
        case .claude:
            show(banner)                  // not used: Claude's news comes through `claudeUpdate`
        case .flock:
            prUpdate(PRUpdate(prIDs: prIDs, banner: banner, source: .flock))
        case .pullRequests, .builds, .commands:
            if let hideAfter {
                var passing = banner
                if hideAfter > 0 { passing.duration = hideAfter }    // Auto: its own time
                show(passing)
            } else if source == .pullRequests {
                prUpdate(PRUpdate(prIDs: prIDs, banner: banner, source: .pullRequests))
            } else {
                notice(Notice(source: source, banner: banner))
            }
        }
    }

    /// A build or command alert that stays until seen.
    func notice(_ notice: Notice) {
        notices.insert(notice, at: 0)
        if notices.count > 20 { notices.removeLast(notices.count - 20) }
        if !quiet {
            log("notice: \(notice.banner.title)\(notice.banner.subtitle.map { " — \($0)" } ?? "") (stays until you look)")
            Haptics.tap(.alignment)
        }
    }

    func show(_ banner: Banner) {
        if !quiet { log("banner: \(banner.title)\(banner.subtitle.map { " — \($0)" } ?? "")") }
        if self.banner == nil { present(banner) } else { bannerQueue.append(banner) }
    }

    private func present(_ banner: Banner) {
        self.banner = banner
        if !quiet { Haptics.tap(.alignment) }
        dismissBanner(after: banner.duration)
    }

    private func dismissBanner(after seconds: TimeInterval) {
        bannerTimer?.invalidate()
        bannerDeadline = Date().addingTimeInterval(seconds * Motion.debugSlowdown)
        bannerTimer = Timer.scheduledTimer(withTimeInterval: seconds * Motion.debugSlowdown, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissBanner() }
        }
    }

    /// Fills in a banner that's showing (or waiting its turn), e.g. headphone battery levels
    /// that arrive a moment after the "Connected" banner. The change animates in place, and
    /// the banner stays up long enough to read it.
    func updateBanner(_ id: UUID, subtitle: String?, accessory: Banner.Accessory) {
        if var current = banner, current.id == id {
            current.subtitle = subtitle
            current.accessory = accessory
            banner = current
            let remaining = bannerDeadline.map { $0.timeIntervalSinceNow / Motion.debugSlowdown } ?? 0
            if remaining < 2.2 { dismissBanner(after: 2.2) }
        } else if let index = bannerQueue.firstIndex(where: { $0.id == id }) {
            bannerQueue[index].subtitle = subtitle
            bannerQueue[index].accessory = accessory
        }
    }

    func dismissBanner() {
        bannerTimer?.invalidate()
        bannerTimer = nil
        bannerDeadline = nil
        banner = nil
        guard !bannerQueue.isEmpty else { return }
        let next = bannerQueue.removeFirst()
        // A beat between banners, so the island visibly closes and opens again. (Not when a
        // Claude update holds it open: then the next one simply blurs in.)
        let beat = restingState == .banner ? 0 : 0.45
        DispatchQueue.main.asyncAfter(deadline: .now() + beat * Motion.debugSlowdown) { [weak self] in
            MainActor.assumeIsolated { self?.present(next) }
        }
    }

    // MARK: Claude Code

    func claudeNeedsYou(_ wait: ClaudeWait) {
        claudeWaits.removeAll { $0.sessionID == wait.sessionID }
        claudeWaits.insert(wait, at: 0)
        if !quiet { Haptics.tap(.levelChange) }
    }

    func claudeResumed(session: String) {
        claudeWaits.removeAll { $0.sessionID == session }
    }

    func dismissClaude() {
        if !claudeWaits.isEmpty { claudeWaits.removeFirst() }
    }

    /// A newer update from the same session replaces its older one.
    func claudeUpdate(_ update: ClaudeUpdate) {
        claudeUpdates.removeAll { !Set($0.sessions).isDisjoint(with: update.sessions) }
        claudeUpdates.insert(update, at: 0)
        if claudeUpdates.count > 20 { claudeUpdates.removeLast(claudeUpdates.count - 20) }
        if !quiet { log("claude update: \(update.banner(waiting: 1).title)\(update.message.map { " — \($0)" } ?? "") \(Self.lasts(settings.hideAfter(.claude)))") }
        if !quiet { Haptics.tap(.alignment) }
    }

    func clearClaudeUpdates() {
        claudeUpdates.removeAll()
    }

    /// The menu's Clear Updates: Claude's waiting news and "needs you", PR news, and build and
    /// command alerts waiting to be seen.
    func clearUpdates() {
        claudeWaits.removeAll()
        claudeUpdates.removeAll()
        prUpdates.removeAll()
        notices.removeAll()
    }

    /// Moving away from the open notch after it showed your Claude updates counts as having
    /// read them. A brush past (under half a second) doesn't, and neither does an update that
    /// arrived in the last half second.
    private func acknowledgeClaudeUpdates() {
        let now = Date()
        let opened = hoverStarted.map { now.timeIntervalSince($0) >= 0.5 } ?? false
        defer { hoverStarted = nil; updatesRead = false; prUpdatesRead = false; buildNoticesRead = false }
        guard forcedState == nil else { return }
        if updatesRead { claudeUpdates.removeAll { now.timeIntervalSince($0.since) >= 0.5 } }
        if prUpdatesRead { prUpdates.removeAll { now.timeIntervalSince($0.since) >= 0.5 } }
        // A build's alert: seen on the builds page, or (with no such page) by opening the island
        // after it was on the notch; a command's: by opening the island after it was on the notch.
        let buildsPage = pages.contains { $0.kind == .builds }
        let read = notices.filter { notice in
            guard now.timeIntervalSince(notice.since) >= 0.5 else { return false }
            let openedAfter = opened && noticesShown.contains(notice.id)
            return notice.source == .builds ? buildNoticesRead || (openedAfter && !buildsPage) : openedAfter
        }.map(\.id)
        if !read.isEmpty { notices.removeAll { read.contains($0.id) } }
    }

    /// PR news that stays until you've looked: Flock's, and any when PR alerts are set to stay.
    /// A newer one from the same source about the same PR replaces it.
    func prUpdate(_ update: PRUpdate) {
        prUpdates.removeAll { $0.source == update.source && !Set($0.prIDs).isDisjoint(with: update.prIDs) }
        prUpdates.insert(update, at: 0)
        if prUpdates.count > 20 { prUpdates.removeLast(prUpdates.count - 20) }
        if !quiet {
            log("pr update: \(update.banner.title)\(update.banner.subtitle.map { " — \($0)" } ?? "") \(Self.lasts(settings.hideAfter(update.source)))")
            Haptics.tap(.alignment)
        }
    }

    // MARK: Claude's background work

    /// Claude Code on, and its background tasks too (Customise › Modules).
    private var showsBackground: Bool { settings.claude && settings.claudeBackground }

    /// A task launched in the background (from its tool call): it shows with its time from now.
    func backgroundStarted(_ task: BackgroundTask) {
        guard showsBackground, !backgroundTasks.contains(where: { $0.id == task.id }) else { return }
        if !quiet { log("claude: \(task.project) started \"\(task.title)\" in the background (\(task.kindName))") }
        backgroundTasks.append(task)
        if backgroundTasks.count > 30 { backgroundTasks.removeFirst(backgroundTasks.count - 30) }
    }

    /// A session's list at the end of a turn: what's on it is running (keeping the times already
    /// known); what of that session's isn't has finished.
    func backgroundRunning(session: String, _ tasks: [BackgroundTask]) {
        guard showsBackground else { return }
        let listed = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [BackgroundTask] = backgroundTasks.compactMap { known in
            guard known.session == session else { return known }
            guard var still = listed[known.id] else { return nil }
            still.started = known.started ?? still.started
            return still
        }
        for task in tasks where !next.contains(where: { $0.id == task.id }) { next.append(task) }
        if next.count > 30 { next.removeFirst(next.count - 30) }
        if !quiet {
            for gone in backgroundTasks where gone.session == session && listed[gone.id] == nil {
                log("claude: \(gone.project) background \"\(gone.title)\" finished")
            }
        }
        if next != backgroundTasks { backgroundTasks = next }
    }

    /// A session ended: its background work went with it.
    func backgroundEnded(session: String) {
        if backgroundTasks.contains(where: { $0.session == session }) { backgroundTasks.removeAll { $0.session == session } }
    }

    /// Jumped to a session from its update: that update is read.
    func openedClaudeSession(_ session: String) {
        claudeUpdates.removeAll { $0.sessions.contains(session) }
    }

    // MARK: Timer

    func startTimer(minutes: Double) {
        guard settings.timers else { return }
        timer = TimerInfo(endsAt: Date().addingTimeInterval(minutes * 60), duration: minutes * 60)
    }

    func addTime(minutes: Double) {
        guard var timer else { return }
        timer.endsAt.addTimeInterval(minutes * 60)
        timer.duration += minutes * 60
        self.timer = timer
    }

    func stopTimer() {
        timer = nil
    }

    private func scheduleTimerCheck() {
        ticker?.invalidate()
        ticker = nil
        guard timer != nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTimer() }
        }
    }

    private func checkTimer() {
        guard let timer, Date() >= timer.endsAt else { return }
        if !quiet { Sounds.play("Glass") }
        self.timer = nil
        show(Banner(symbol: "timer", tint: .orange, title: "Time's up", subtitle: "Focus timer finished", accessory: .check))
    }

    // MARK: Media

    /// A player reported in (nil: it stopped or went away).
    func updatePlayer(_ key: String, _ update: NowPlaying?) {
        let old = players[key]
        if let update {
            if old == nil || old?.isPlaying != update.isPlaying || old?.title != update.title {
                lastChange[key] = Date()
            }
            players[key] = update
        } else {
            players[key] = nil
            lastChange[key] = nil
        }
        refreshArtworkTint()
    }

    /// Works out the colour of the shown track's art, its shape, and for a video the picture
    /// itself (once per cover).
    private func refreshArtworkTint() {
        guard let shown = nowPlaying else { return }
        let key = (shown.artworkURL?.absoluteString
            ?? shown.artworkImage.map { "image-\(ObjectIdentifier($0).hashValue)" }
            ?? "none") + (shown.isVideo ? " video" : "")
        guard key != artworkTintKey else { return }
        artworkTintKey = key
        artworkAspect = nil
        videoStill = nil
        if let image = shown.artworkImage {
            artworkTint = ArtworkColor.dominant(of: image)
            artworkAspect = Self.aspect(of: image)
            if shown.isVideo { videoStill = image }
        } else if let url = shown.artworkURL, url.scheme == "https" {
            Task { [weak self] in
                let data = try? await URLSession.shared.data(from: url).0
                let tint = data.flatMap(ArtworkColor.dominant(of:))
                let image = data.flatMap(NSImage.init(data:))
                guard let self, self.artworkTintKey == key else { return }
                self.artworkTint = tint
                self.artworkAspect = image.flatMap(Self.aspect(of:))
                if shown.isVideo { self.videoStill = image }
            }
        } else {
            artworkTint = nil
        }
    }

    private static func aspect(of image: NSImage) -> CGFloat? {
        image.size.height > 0 ? image.size.width / image.size.height : nil
    }

    /// A video's picture shows wide (16:9), unless the picture itself is about square (a
    /// song's cover, on a site that plays music through a video element).
    func wideArtwork(_ playing: NowPlaying) -> Bool {
        playing.isVideo && (artworkAspect ?? 16.0 / 9) >= 1.3
    }

    /// Whether the closed pill's art shows wide (a video's picture).
    var compactArtworkWide: Bool {
        if case .nowPlaying(let playing)? = compactActivity { return wideArtwork(playing) }
        return false
    }

    /// The open island's backdrop: the playing video's still, while its page is open.
    var cinemaStill: NSImage? {
        guard state == .expanded, case .nowPlaying(let playing)? = expandedActivity, wideArtwork(playing) else { return nil }
        return videoStill
    }

    /// From the browser bridge. nil means nothing is playing in the browser.
    func browserUpdate(_ update: NowPlaying?) {
        updatePlayer("browser", update)
    }

    func startDemoMusic() {
        updatePlayer("demo", NowPlaying(title: "Sample Track", artist: "Demo Artist", source: "Demo",
                                        artworkURL: nil, isPlaying: true, canSkip: false, canSeek: true,
                                        duration: 214, position: 37, origin: .demo))
    }

    func clearDemoMusic() {
        updatePlayer("demo", nil)
    }

    func togglePlayPause() {
        perform(nowPlaying?.isPlaying == true ? .pause : .play)
    }

    func perform(_ action: MediaAction) {
        guard var current = nowPlaying else { return }
        if current.origin != .demo { sendMediaAction?(action, current) }
        // Show the result straight away; the player confirms a moment later.
        let now = Date()
        switch action {
        case .play, .pause:
            current.position = current.playhead(at: now)
            current.positionDate = now
            current.isPlaying = action == .play
        case .seek(let time):
            current.position = max(0, min(time, current.duration ?? time))
            current.positionDate = now
        case .nexttrack, .previoustrack:
            return
        }
        updatePlayer(current.key, current)
    }

    func clearAll() {
        stopTimer()
        clearDemoMusic()
        claudeWaits.removeAll()
        claudeUpdates.removeAll()
        prUpdates.removeAll()
        notices.removeAll()
        backgroundTasks.removeAll()
    }

    /// For the log: how long a piece of news stays on the notch.
    private static func lasts(_ hideAfter: TimeInterval?) -> String {
        hideAfter.map { "(on the notch for \(Int($0)) s)" } ?? "(stays until you look)"
    }
}
