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

    /// The banner it shows as; `waiting` is how many updates there are in all.
    func banner(waiting: Int) -> Banner {
        Banner(id: id, symbol: "sparkle", tint: .claude,
               title: project.map { "\(headline) · \($0)" } ?? headline,
               subtitle: message,
               accessory: waiting > 1 ? .count(waiting) : (kind == .finished ? .check : .none),
               duration: .infinity)
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
        case .meeting: .meeting
        case .process: .process
        case .nowPlaying: .music
        case .timer: .timer
        case .pullRequests: .pullRequests
        case .builds: .builds
        case .home: .home
        }
    }
}

/// News from Flock about your PRs. Like a Claude update it stays on the notch until you've
/// looked at the PR page; a newer one about the same PR replaces it.
struct PRUpdate: Equatable, Identifiable {
    var id = UUID()
    var prIDs: [String]
    var banner: Banner
    var since = Date()
}

enum PRAction {
    case open(URL)
    case rerun(PullRequest.Check, PullRequest)
    /// The failed check's page if one failed, otherwise the PR's checks.
    case details(PullRequest)
}

/// The kinds of thing the island shows; the open island has a page for each one that's live.
enum ActivityKind: Hashable {
    case claude, claudeUpdates, meeting, process, music, timer, pullRequests, builds, home

    var symbol: String {
        switch self {
        case .claude, .claudeUpdates: "sparkle"
        case .meeting: MeetingIcon.calendarName
        case .process: "flame.fill"
        case .music: "music.note"
        case .timer: "timer"
        case .pullRequests: PullRequestIcon.symbolName
        case .builds: "hammer.fill"
        case .home: "clock"
        }
    }
    var title: String {
        switch self {
        case .claude: "Claude"
        case .claudeUpdates: "Claude"
        case .meeting: "Meeting"
        case .process: "Process"
        case .music: "Music"
        case .timer: "Timer"
        case .pullRequests: "Pull requests"
        case .builds: "Builds"
        case .home: "Now"
        }
    }
}

/// What the notch is showing.
enum Activity: Equatable {
    case claude(ClaudeWait)
    case claudeUpdate(ClaudeUpdate)
    case meeting(Meeting)
    case process(RunawayProcess)
    case pullRequests(PRSummary)
    case builds(BuildSummary)
    case home
    case timer(TimerInfo)
    case nowPlaying(NowPlaying)
}

@MainActor final class NotchModel: ObservableObject {
    @Published var layout: NotchLayout
    /// The pointer is on the island but it isn't open yet (Click / Hover & hold): it swells
    /// a little to say "click me".
    @Published var armed = false
    /// The next or current meeting, kept up to date by `Meetings`.
    @Published var meeting: Meeting?
    /// A process working far too hard (from `SystemMonitor`).
    @Published var runaway: RunawayProcess?
    /// Keeping the Mac awake, and why (from `KeepAwake`).
    @Published var awake = AwakeState()
    /// Your pull requests (from `PRWatcher`).
    @Published var prSummary: PRSummary?
    /// Your Jenkins builds (from `JenkinsWatcher`).
    @Published var builds: BuildSummary?
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
    var prAction: ((PRAction) -> Void)?
    /// You've looked at the PR page: what was new is now seen.
    var prsSeen: (() -> Void)?
    /// Brings a Claude session's app (and, where possible, its tab or window) to the front.
    var openClaudeSession: ((String) -> Void)?
    var toggleKeepAwake: (() -> Void)?
    /// The colour of the current album art (for the Ambient and Aurora backgrounds).
    @Published private(set) var artworkTint: RGB?
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
        }
    }
    @Published var forcedState: NotchState?      // --state flag, for development
    @Published var timer: TimerInfo? {
        didSet { scheduleTimerCheck() }
    }
    /// Every player we know about, keyed by `NowPlaying.key`; `nowPlaying` picks one.
    @Published private(set) var players: [String: NowPlaying] = [:]
    /// Claude Code sessions waiting on you, newest first.
    @Published private(set) var claudeWaits: [ClaudeWait] = []
    @Published private(set) var banner: Banner?
    /// Claude Code updates you haven't looked at yet, newest first.
    @Published private(set) var claudeUpdates: [ClaudeUpdate] = []
    /// Flock's news about your PRs you haven't looked at yet, newest first.
    @Published private(set) var prUpdates: [PRUpdate] = []
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
        if !new.timers { timer = nil }
        if !new.meetings { meeting = nil }
        if !new.systemHealth { runaway = nil }
        if !new.pullRequests {
            prUpdates.removeAll()
            if pinned == .pullRequests { pinned = nil }
        }
        if !new.builds {
            builds = nil
            if pinned == .builds { pinned = nil }
        }
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
        if let nowPlaying, nowPlaying.isPlaying { list.append(.nowPlaying(nowPlaying)) }
        if let meeting, !meeting.prominent { list.append(.meeting(meeting)) }
        if let timer { list.append(.timer(timer)) }
        if let builds, builds.live, settings.builds { list.append(.builds(builds)) }
        if let prSummary, prSummary.live, settings.pullRequests { list.append(.pullRequests(prSummary)) }
        if let nowPlaying, !nowPlaying.isPlaying { list.append(.nowPlaying(nowPlaying)) }
        return list
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
    static let pinnable: Set<ActivityKind> = [.music, .pullRequests, .builds, .meeting, .timer, .process]

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
        var news: [(Date, Activity)] = []
        if let update = claudeUpdates.first { news.append((update.since, .claudeUpdate(update))) }
        if let update = prUpdates.first, let prSummary { news.append((update.since, .pullRequests(prSummary))) }
        list += news.sorted { $0.0 > $1.0 }.map(\.1)
        list += priorityActivities.filter { activity in activity.kind != .claude && !list.contains { $0.kind == activity.kind } }
        // A section you chose that isn't live on its own still gets its tab. Not PRs or builds:
        // they always have theirs, in a fixed place below, so choosing one (which pins it)
        // never swaps them round.
        if let chosen = liveActivities.first(where: { $0.kind == pinned }), ![.pullRequests, .builds].contains(chosen.kind),
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
        return list
    }

    /// The open island: the page you picked; otherwise unread news first, otherwise whatever
    /// the closed pill was showing (the section you chose).
    var expandedActivity: Activity? {
        let pages = pages
        if let page, let chosen = pages.first(where: { $0.kind == page }) { return chosen }
        if let first = pages.first, [.claude, .claudeUpdates].contains(first.kind) || !prUpdates.isEmpty { return first }
        if let pill = liveActivities.first?.kind, let match = pages.first(where: { $0.kind == pill }) { return match }
        return pages.first
    }

    /// How tall the PR page's content is (measured by the view), so the island can fit it.
    @Published var prContentHeight: CGFloat = 0

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
        default: return .standard
        }
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
        if shown == .builds { buildsShownAt = buildsShownAt ?? now }
        else if let since = buildsShownAt {
            if now.timeIntervalSince(since) >= 0.5 { buildsSeen?() }
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
        if claudeWaits.isEmpty, !claudeUpdates.isEmpty || !prUpdates.isEmpty { return .banner }
        return compactActivity == nil ? .idle : .compact
    }

    /// The banner on screen: a passing one, or the newest unread Claude update.
    var displayedBanner: Banner? {
        banner ?? stickyBanner
    }

    /// The newest unread update (Claude's or Flock's), with a count when several wait.
    var stickyBanner: Banner? {
        let waiting = claudeUpdates.count + prUpdates.count
        let claude = claudeUpdates.first, pr = prUpdates.first
        if let pr, claude.map({ pr.since > $0.since }) ?? true {
            var shown = pr.banner
            shown.id = pr.id
            shown.duration = .infinity
            if waiting > 1 { shown.accessory = .count(waiting) }
            return shown
        }
        return claude?.banner(waiting: waiting)
    }

    // MARK: Banners

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
        if !quiet { log("claude update: \(update.banner(waiting: 1).title)\(update.message.map { " — \($0)" } ?? "") (stays until you look)") }
        if !quiet { Haptics.tap(.alignment) }
    }

    func clearClaudeUpdates() {
        claudeUpdates.removeAll()
    }

    /// The menu's Clear Updates: Claude's waiting news and "needs you", and Flock's news.
    func clearUpdates() {
        claudeWaits.removeAll()
        claudeUpdates.removeAll()
        prUpdates.removeAll()
    }

    /// Moving away from the open notch after it showed your Claude updates counts as having
    /// read them. A brush past (under half a second) doesn't, and neither does an update that
    /// arrived in the last half second.
    private func acknowledgeClaudeUpdates() {
        let now = Date()
        defer { hoverStarted = nil; updatesRead = false; prUpdatesRead = false }
        guard forcedState == nil else { return }
        if updatesRead { claudeUpdates.removeAll { now.timeIntervalSince($0.since) >= 0.5 } }
        if prUpdatesRead { prUpdates.removeAll { now.timeIntervalSince($0.since) >= 0.5 } }
    }

    /// Flock news that stays until you've looked (a newer one about the same PR replaces it).
    func prUpdate(_ update: PRUpdate) {
        prUpdates.removeAll { !Set($0.prIDs).isDisjoint(with: update.prIDs) }
        prUpdates.insert(update, at: 0)
        if prUpdates.count > 20 { prUpdates.removeLast(prUpdates.count - 20) }
        if !quiet {
            log("pr update: \(update.banner.title)\(update.banner.subtitle.map { " — \($0)" } ?? "") (stays until you look)")
            Haptics.tap(.alignment)
        }
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

    /// Works out the colour of the shown track's art (once per cover).
    private func refreshArtworkTint() {
        guard let shown = nowPlaying else { return }
        let key = shown.artworkURL?.absoluteString
            ?? shown.artworkImage.map { "image-\(ObjectIdentifier($0).hashValue)" }
            ?? "none"
        guard key != artworkTintKey else { return }
        artworkTintKey = key
        if let image = shown.artworkImage {
            artworkTint = ArtworkColor.dominant(of: image)
        } else if let url = shown.artworkURL, url.scheme == "https" {
            Task { [weak self] in
                let data = try? await URLSession.shared.data(from: url).0
                let tint = data.flatMap(ArtworkColor.dominant(of:))
                guard let self, self.artworkTintKey == key else { return }
                self.artworkTint = tint
            }
        } else {
            artworkTint = nil
        }
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
    }
}
