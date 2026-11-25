import AppKit
import Combine
import EventKit

/// Your next meeting, from the calendars on this Mac (Calendar app accounts: iCloud, Google,
/// Exchange…), via EventKit. Nothing leaves the Mac.
///
/// - From `meetingLead` minutes before, the pill counts down; in the last two minutes (and
///   the first five of the meeting) it outranks music.
/// - When it starts: a banner and, if you like, a chime.
/// - During it: the time left.
/// - From the open island you can put one away: Dismiss hides it until it starts (once it has,
///   for the rest of it); Skip meeting hides it to its end, with no banner or chime.
/// Calendar access needs Notch to run as an app (bin/notch), so macOS asks on Notch's behalf.
@MainActor final class Meetings: ObservableObject {
    enum Access: Equatable {
        case notDetermined, granted, denied
        case unavailable          // running from `swift run`: macOS can't ask for Notch
    }

    struct CalendarInfo: Identifiable, Equatable {
        var id: String
        var title: String
        var account: String
        var color: RGB
    }

    @Published private(set) var access: Access
    @Published private(set) var calendars: [CalendarInfo] = []
    /// What's left of today and tomorrow morning, soonest first (the customiser lists it).
    @Published private(set) var upcoming: [Meeting] = []
    /// Meetings you're not joining, each until its end (the customiser can undo it).
    @Published private(set) var skipped: [String: Date] = [:]

    /// What the island should show (nil: nothing soon).
    var onChange: ((Meeting?) -> Void)?
    var onBanner: ((Banner) -> Void)?

    private let store = EKEventStore()
    private var observers: [any NSObjectProtocol] = []
    private var tick: Timer?
    private var announced: Set<String> = []
    /// Meetings dismissed from the island: hidden until this (the start, or the end).
    private var dismissed: [String: Date] = [:]
    private var shown: Meeting?
    private var settingsWatch: AnyCancellable?

    static var runningAsApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    init() {
        access = Self.currentAccess()
    }

    static func currentAccess() -> Access {
        guard runningAsApp else { return .unavailable }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied                      // denied, restricted, add-only
        }
    }

    func start() {
        observers.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        // Woke from sleep, or the clock jumped: look again.
        for name in [NSWorkspace.didWakeNotification, NSNotification.Name.NSSystemClockDidChange] {
            let center = name == NSWorkspace.didWakeNotification ? NSWorkspace.shared.notificationCenter : .default
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            })
        }
        // Lead time, calendars switched off, the module itself: look again once it's saved.
        settingsWatch = SettingsStore.shared.$value.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.evaluate() } }
        }
        reload()
        if access == .granted { log("meetings: " + summary) }
        else { log("meetings: calendar access \(access)") }
    }

    /// "7 calendars (Google 4, On My Mac 3), 3 events coming up, 2 with a call link".
    private var summary: String {
        let accounts = Dictionary(grouping: calendars, by: \.account).sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value.count)" }.joined(separator: ", ")
        let calls = upcoming.filter { $0.joinURL != nil }.count
        return "\(calendars.count) calendar\(calendars.count == 1 ? "" : "s")" + (accounts.isEmpty ? "" : " (\(accounts))")
            + ", \(upcoming.count) event\(upcoming.count == 1 ? "" : "s") coming up, \(calls) with a call link"
    }

    /// Shows macOS's "Notch would like to access your calendars" prompt.
    func requestAccess() {
        guard Self.runningAsApp else { return }
        Task { [weak self] in
            guard let self else { return }
            let granted = (try? await self.store.requestFullAccessToEvents()) ?? false
            self.access = Self.currentAccess()
            log("meetings: calendar access \(granted ? "granted" : "not granted")")
            self.reload()
        }
    }

    /// Calendars or settings changed.
    func reload() {
        access = Self.currentAccess()
        guard access == .granted else {
            calendars = []
            upcoming = []
            publish(nil)
            return
        }
        let before = Set(calendars.map(\.id))
        calendars = store.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "Other",
                                color: RGB(nsColor: $0.color)) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        evaluate()
        // An account added or removed in Internet Accounts (not the first load: start() says that).
        if !before.isEmpty, before != Set(calendars.map(\.id)) { log("meetings: calendars changed, now " + summary) }
    }

    /// Picks what to show now, and schedules the next look for the next moment that matters.
    func evaluate() {
        tick?.invalidate()
        let settings = SettingsStore.shared.value
        guard access == .granted else { return publish(nil) }
        let now = Date()
        let enabled = store.calendars(for: .event).filter { !settings.hiddenCalendars.contains($0.calendarIdentifier) }
        let events: [Meeting] = enabled.isEmpty ? [] : store
            .events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-8 * 3600),
                                                       end: now.addingTimeInterval(30 * 3600), calendars: enabled))
            .filter { !$0.isAllDay && $0.status != .canceled && !Self.declined($0) }
            .map(Self.meeting(from:))
            .filter { !settings.videoMeetingsOnly || $0.joinURL != nil }
            .sorted { $0.start < $1.start }
        upcoming = Array(events.filter { $0.end > now }.prefix(6))

        // What you've put away from the island isn't shown, and gets no banner when it starts.
        let shown = showable(events, at: now)
        let pick = settings.meetings ? Self.pick(from: shown, now: now, settings: settings) : nil
        publish(pick)

        // Starting now: a banner (and a chime) once.
        if settings.meetings, let starting = Self.startingNow(in: shown, at: now),
           !announced.contains(starting.id) {
            announced.insert(starting.id)
            if settings.meetingChime { Sounds.play("Ping") }
            onBanner?(Banner(symbol: (starting.joinURL == nil ? MeetingIcon.calendarName : MeetingIcon.videoName) + ".fill", tint: .green,
                             title: starting.title,
                             subtitle: "Starting now" + (starting.service.map { " · \($0)" } ?? ""), duration: 6))
        }

        // Look again at the next boundary (pill appears, turns urgent, starts, ends), or in a minute.
        let lead = TimeInterval(settings.meetingLead * 60)
        let boundaries = events.flatMap { [$0.start - lead, $0.start - 120, $0.start, $0.start + 300, $0.end] }
            .filter { $0 > now }
        let next = min(boundaries.min()?.timeIntervalSince(now) ?? 60, 60)
        tick = Timer.scheduledTimer(withTimeInterval: max(next + 0.05, 1), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
    }

    // MARK: Putting one away

    /// Dismiss: hidden until it starts, then back with its banner. Once it's under way, hidden
    /// for the rest of it.
    func dismiss(_ meeting: Meeting) {
        let now = Date()
        dismissed[Self.key(meeting)] = now < meeting.start ? meeting.start : meeting.end
        log("meetings: dismissed \"\(meeting.title)\" " + (now < meeting.start ? "until it starts" : "for the rest of it"))
        evaluate()
    }

    /// Skip meeting: hidden to its end, with no banner or chime when it starts.
    func skip(_ meeting: Meeting) {
        skipped[Self.key(meeting)] = meeting.end
        log("meetings: not joining \"\(meeting.title)\"")
        evaluate()
    }

    /// The customiser's undo: remind me after all.
    func unskip(_ meeting: Meeting) {
        skipped[Self.key(meeting)] = nil
        log("meetings: joining \"\(meeting.title)\" after all")
        evaluate()
    }

    /// What of `events` to show: not what you've put away. Forgets what's over.
    func showable(_ events: [Meeting], at now: Date) -> [Meeting] {
        dismissed = dismissed.filter { $0.value > now }
        if skipped.contains(where: { $0.value <= now }) { skipped = skipped.filter { $0.value > now } }
        return events.filter { skipped[Self.key($0)] == nil && dismissed[Self.key($0)] == nil }
    }

    func isSkipped(_ meeting: Meeting) -> Bool { skipped[Self.key(meeting)] != nil }

    /// What and when, so the same meeting in two calendars is put away together (and one moved
    /// to another time comes back).
    private static func key(_ meeting: Meeting) -> String {
        "\(meeting.title)@\(meeting.start.timeIntervalSince1970)-\(meeting.end.timeIntervalSince1970)"
    }

    /// Started in the last 45 seconds: the one to announce.
    static func startingNow(in events: [Meeting], at now: Date) -> Meeting? {
        events.first { $0.start <= now && now.timeIntervalSince($0.start) < 45 }
    }

    /// About to start beats under way; under way shows its time left (if wanted).
    static func pick(from events: [Meeting], now: Date, settings: NotchSettings) -> Meeting? {
        let lead = TimeInterval(settings.meetingLead * 60)
        let next = events.first { $0.start > now && $0.start.timeIntervalSince(now) <= lead }
        let live = events.last { $0.isLive(at: now) }
        var pick: Meeting?
        if let next, next.start.timeIntervalSince(now) <= 120 { pick = next }
        else if let live, settings.meetingTimeLeft || now.timeIntervalSince(live.start) < 300 { pick = live }
        else { pick = next }
        if var chosen = pick {
            chosen.prominent = chosen.start.timeIntervalSince(now) <= 120 && now.timeIntervalSince(chosen.start) < 300
            pick = chosen
        }
        return pick
    }

    private func publish(_ meeting: Meeting?) {
        guard meeting != shown else { return }
        if meeting?.id != shown?.id {
            log("meetings: " + (meeting.map { "showing \"\($0.title)\" at \($0.start.formatted(date: .omitted, time: .shortened))" } ?? "nothing soon"))
        }
        shown = meeting
        onChange?(meeting)
    }

    // MARK: Reading events

    private static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }

    static func meeting(from event: EKEvent) -> Meeting {
        let texts = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        let link = texts.lazy.compactMap(joinLink(in:)).first
        return Meeting(id: "\(event.eventIdentifier ?? UUID().uuidString)@\(event.startDate.timeIntervalSince1970)",
                       title: event.title?.isEmpty == false ? event.title! : "Untitled meeting",
                       start: event.startDate, end: event.endDate,
                       calendar: event.calendar?.title ?? "Calendar",
                       color: RGB(nsColor: event.calendar?.color ?? .systemBlue),
                       location: event.location.flatMap { $0.isEmpty || $0.hasPrefix("http") ? nil : $0 },
                       joinURL: link?.url, service: link?.service)
    }

    /// Video call links people paste into invites, best known first.
    static let services: [(name: String, pattern: String)] = [
        ("Google Meet", #"https://meet\.google\.com/[a-z]{3,4}-[a-z]{3,4}-[a-z]{3,4}"#),
        ("Zoom", #"https://(?:[\w-]+\.)?zoom\.us/(?:j|my|w|s)/[\w./?=&%-]+"#),
        ("Teams", #"https://teams\.(?:microsoft|live)\.com/(?:l/meetup-join|meet)/[^\s<>"]+"#),
        ("Webex", #"https://[\w-]+\.webex\.com/[^\s<>"]+"#),
        ("Slack huddle", #"https://app\.slack\.com/huddle/[^\s<>"]+"#),
        ("Amazon Chime", #"https://chime\.aws/\d+"#),
        ("Whereby", #"https://whereby\.com/[^\s<>"]+"#),
    ]

    static func joinLink(in text: String) -> (service: String, url: URL)? {
        for service in services {
            guard let range = text.range(of: service.pattern, options: [.regularExpression, .caseInsensitive]),
                  let url = URL(string: String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)>"))) else { continue }
            return (service.name, url)
        }
        return nil
    }

    // MARK: Opening things

    static func openCalendarApp() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openInternetAccounts() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension RGB {
    init(nsColor: NSColor) {
        let color = nsColor.usingColorSpace(.deviceRGB) ?? .systemBlue
        self.init(red: Double(color.redComponent), green: Double(color.greenComponent), blue: Double(color.blueComponent))
    }
}
