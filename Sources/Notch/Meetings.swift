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

    /// What the island should show (nil: nothing soon).
    var onChange: ((Meeting?) -> Void)?
    var onBanner: ((Banner) -> Void)?

    private let store = EKEventStore()
    private var observers: [any NSObjectProtocol] = []
    private var tick: Timer?
    private var announced: Set<String> = []
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

        let pick = settings.meetings ? Self.pick(from: events, now: now, settings: settings) : nil
        publish(pick)

        // Starting now: a banner (and a chime) once.
        if settings.meetings, let starting = events.first(where: { $0.start <= now && now.timeIntervalSince($0.start) < 45 }),
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
