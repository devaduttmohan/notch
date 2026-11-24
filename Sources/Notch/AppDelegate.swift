import AppKit
import Combine

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: NotchModel?
    private var controller: NotchController?
    private var bridge: BrowserBridge?
    private var desktopMusic: DesktopMusic?
    private var alerts: AlertServer?
    private var claude: ClaudeCode?
    private var system: SystemEvents?
    private var meetings: Meetings?
    private var customiser: Customiser?
    private var monitor: SystemMonitor?
    private let prs = PRWatcher()
    private let keepAwake = KeepAwake()
    private let load = LoadMonitor()
    private var keepAwakeItem: NSMenuItem?
    private var timerItem: NSMenuItem?
    private var clearItem: NSMenuItem?
    private var updateItem: NSMenuItem?
    private var settingsWatch: AnyCancellable?
    private var statusItem: NSStatusItem?
    private var statusIcon: StatusIcon?
    private var statusWatch: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("starting \(Meetings.runningAsApp ? "from \(Bundle.main.bundlePath)" : "from swift run")")
        LoginItem.followMove()
        NSApp.mainMenu = Self.mainMenu()
        let model = NotchModel(layout: NotchLayout.current())
        self.model = model
        controller = NotchController(model: model)
        startMusicSources(for: model)
        startAlerts(for: model)
        startSystemEvents(for: model)
        startMeetings(for: model)
        startHealthAndKeepAwake(for: model)
        startPullRequests(for: model)
        startBuilds(for: model)
        startLoad(for: model)
        startUpdates(for: model)
        model.openCustomiser = { [weak self] in self?.openCustomiser() }
        model.openClaudeSession = { [weak self] session in self?.claude?.open(session: session) }
        setUpStatusItem()
        applyLaunchArguments(to: model)
    }

    /// Your next meeting from the Calendar app's calendars.
    private func startMeetings(for model: NotchModel) {
        let meetings = Meetings()
        meetings.onChange = { [weak model] meeting in model?.meeting = meeting }
        meetings.onBanner = { [weak model] banner in model?.show(banner) }
        meetings.start()
        self.meetings = meetings
        customiser = Customiser(meetings: meetings, keepAwake: keepAwake, prs: prs)
    }

    @objc private func openCustomiser() {
        customiser?.show()
    }

    /// Runaway processes, low disk, heat; and keeping the Mac awake while work runs.
    private func startHealthAndKeepAwake(for model: NotchModel) {
        let monitor = SystemMonitor()
        monitor.onRunaway = { [weak model] process in model?.runaway = process }
        monitor.onBanner = { [weak model] banner in model?.show(banner) }
        model.processAction = { [weak monitor] action, process in
            switch action {
            case .quit: monitor?.quit(process)
            case .forceQuit: monitor?.forceQuit(process)
            case .snooze: monitor?.snooze(process)
            case .ignore: monitor?.ignore(process)
            }
        }
        monitor.start()
        self.monitor = monitor

        keepAwake.onChange = { [weak model] state in model?.awake = state }
        keepAwake.start()
        model.toggleKeepAwake = { [weak self] in self?.toggleKeepAwake() }
        claude?.keepAwake = keepAwake
        settingsWatch = SettingsStore.shared.$value.dropFirst().sink { [weak self] new in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.keepAwake.settingsChanged(new)
                let before = SettingsStore.shared.value          // (the sink fires just before the change)
                if new.builds != before.builds {
                    DispatchQueue.main.async {
                        if new.builds { JenkinsWatcher.shared.start() }
                        JenkinsWatcher.shared.onChange?()
                    }
                }
                if new.loadMonitor != before.loadMonitor {
                    DispatchQueue.main.async { new.loadMonitor ? self.load.start() : self.load.stop() }
                }
                if new.pullRequests != before.pullRequests || new.prIgnoredAuthors != before.prIgnoredAuthors {
                    DispatchQueue.main.async {
                        self.prs.onChange?()
                        if new.pullRequests && !before.pullRequests { self.prs.refresh() }
                    }
                }
            }
        }
    }

    /// Your PRs through `gh`: the bubble/pill, the PR page, banners for what changed.
    private func startPullRequests(for model: NotchModel) {
        prs.onChange = { [weak self, weak model] in
            guard let self, let model else { return }
            model.prSummary = self.prs.summary()
        }
        prs.onEvents = { [weak self, weak model] events in
            guard let self, let model else { return }
            // Flock's news stays until you've looked; everything else passes like any banner.
            let flock = events.filter(\.fromFlock)
            if let banner = PRBanner.banner(for: events.filter { !$0.fromFlock }, mainRepo: self.prs.mainRepo) {
                model.show(banner)
            }
            if let banner = PRBanner.banner(for: flock, mainRepo: self.prs.mainRepo) {
                model.prUpdate(PRUpdate(prIDs: flock.map(\.pr.id), banner: banner))
            }
        }
        model.prAction = { [weak self] action in
            switch action {
            case .open(let url): NSWorkspace.shared.open(url)
            case .rerun(let check, let pr): self?.prs.rerun(check, in: pr)
            case .details(let pr):
                NSWorkspace.shared.open(pr.failedChecks.first?.url ?? pr.url.appendingPathComponent("checks"))
            }
        }
        model.prsSeen = { [weak self] in self?.prs.markSeen() }
        prs.start()
    }

    /// Jenkins builds you start: a pill with their progress, a banner when they end.
    private func startBuilds(for model: NotchModel) {
        let jenkins = JenkinsWatcher.shared
        jenkins.isAway = { [weak self] in !(self?.prs.away.isEmpty ?? true) }
        jenkins.gitHubLogin = { [weak self] in self?.prs.login }
        jenkins.onChange = { [weak model] in
            guard let model else { return }
            let settings = SettingsStore.shared.value
            model.jenkinsServer = JenkinsWatcher.serverURL(settings.jenkinsURL)
            model.builds = settings.builds && jenkins.phase == .signedIn ? jenkins.summary : nil
        }
        jenkins.onFinished = { [weak model] build in model?.show(BuildBanner.banner(for: build)) }
        model.buildAction = { NSWorkspace.shared.open($0) }
        model.buildsSeen = { jenkins.markSeen() }
        prs.onPush = { jenkins.lookSoon() }
        jenkins.start()
    }

    /// New versions from GitHub: a banner when one appears, Update in Customise › About, and
    /// "Updated to …" once the new one is running.
    private func startUpdates(for model: NotchModel) {
        let updater = Updater.shared
        updater.isAway = { [weak self] in !(self?.prs.away.isEmpty ?? true) }
        updater.onFound = { [weak model] release in
            model?.show(Banner(symbol: "arrow.down.circle.fill", tint: .green, title: "Notch \(release.version) is available",
                               subtitle: "Update in Customise › About", duration: 7))
        }
        if let current = updater.currentVersion {
            let before = SettingsStore.shared.value.lastRunVersion
            if !before.isEmpty, Updater.isNewer(current, than: before) {
                log("update: now running \(current) (was \(before))")
                model.show(Banner(symbol: "checkmark.seal.fill", tint: .green, title: "Updated to Notch \(current)",
                                  subtitle: "What's new is in Customise › About", duration: 6))
            }
            if before != current { SettingsStore.shared.value.lastRunVersion = current }
        }
        updater.start()
    }

    @objc private func openUpdates() {
        customiser?.show(pane: .about)
    }

    /// CPU & memory, live: the pill (always or when busy) and its page in the open island.
    private func startLoad(for model: NotchModel) {
        load.isAway = { [weak self] in !(self?.prs.away.isEmpty ?? true) }
        load.processes = { [weak self] limit in self?.monitor?.topProcesses(limit) ?? [] }
        load.onChange = { [weak model] snapshot in
            model?.load = SettingsStore.shared.value.loadMonitor ? snapshot : nil
        }
        model.loadQuit = { [weak self] process in self?.monitor?.quit(process) }
        model.loadPageShown = { [weak self] shown in self?.load.setFast(shown) }
        if SettingsStore.shared.value.loadMonitor { load.start() }
    }

    @objc private func toggleKeepAwake() {
        keepAwake.toggleManual()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        keepAwakeItem?.state = keepAwake.manual ? .on : .off
        // The timer item says what it will do; it's hidden when timers are switched off.
        timerItem?.title = model?.timer == nil ? "Start Focus Timer (25 min)" : "Stop Focus Timer"
        timerItem?.isHidden = !SettingsStore.shared.value.timers
        // Clear Updates only when there's something to clear: Claude's and Flock's waiting news.
        let waiting = (model?.claudeWaits.count ?? 0) + (model?.claudeUpdates.count ?? 0) + (model?.prUpdates.count ?? 0)
        clearItem?.isEnabled = waiting > 0
        clearItem?.title = waiting > 0 ? "Clear \(waiting) Update\(waiting == 1 ? "" : "s")" : "Clear Updates"
        // A new version of Notch: say which, and open where you can install it.
        let release = Updater.shared.hasUpdate ? Updater.shared.available : nil
        updateItem?.isHidden = release == nil
        updateItem?.title = release.map { "Update to Notch \($0.version)…" } ?? "Update Notch…"
    }

    /// Browser tabs (via ChromeExtension/) and the Spotify / Apple Music apps. Controls go
    /// back to whichever player owns the track.
    private func startMusicSources(for model: NotchModel) {
        let bridge = BrowserBridge()
        bridge.onUpdate = { [weak model] nowPlaying in model?.browserUpdate(nowPlaying) }
        bridge.start()
        self.bridge = bridge

        let desktop = DesktopMusic()
        desktop.onUpdate = { [weak model] app, nowPlaying in model?.updatePlayer(app.rawValue, nowPlaying) }
        desktop.start()
        desktopMusic = desktop

        model.sendMediaAction = { [weak bridge, weak desktop] action, nowPlaying in
            switch nowPlaying.origin {
            case .browser(let tabId): bridge?.send(action, tabId: tabId)
            case .app(let app): desktop?.perform(action, on: app)
            case .demo: break
            }
        }
    }

    /// `notchctl say | run | claude` arrive over a private local socket.
    private func startAlerts(for model: NotchModel) {
        let claude = ClaudeCode(model: model)
        let alerts = AlertServer()
        alerts.onMessage = { [weak self, weak model, weak claude] message in
            let settings = SettingsStore.shared.value
            // `notchctl run`: hold the Mac awake from start to finish.
            if message["type"] as? String == "run-start", let id = message["id"] as? String {
                self?.keepAwake.commandStarted(id: id, command: message["command"] as? String ?? "a command")
                return
            }
            if message["type"] as? String == "run", let id = message["id"] as? String {
                self?.keepAwake.commandFinished(id: id)
            }
            if message["type"] as? String == "claude", let hook = message["hook"] as? [String: Any] {
                if settings.claude {
                    claude?.handle(hook, ancestors: message["ancestors"] as? [Int] ?? [], appSession: message["appSession"] as? String)
                }
            } else if settings.commands, let banner = CommandAlerts.banner(for: message) {
                model?.show(banner)
            }
        }
        alerts.start()
        self.alerts = alerts
        self.claude = claude
    }

    /// Charging, low battery, headphones.
    private func startSystemEvents(for model: NotchModel) {
        let system = SystemEvents()
        system.onBanner = { [weak model] banner in model?.show(banner) }
        system.onBannerUpdate = { [weak model] id, subtitle, accessory in
            model?.updateBanner(id, subtitle: subtitle, accessory: accessory)
        }
        system.start()
        self.system = system
    }

    /// Development flags:  --demo timer|music|claude|done|ended|build|charging|airpods|meeting
    ///                     --state …   --slow N   --customise [appearance|motion|behaviour|modules|meetings|about]
    private func applyLaunchArguments(to model: NotchModel) {
        let args = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let slow = value(after: "--slow").flatMap(Double.init), slow >= 1 {
            Motion.debugSlowdown = slow          // e.g. --slow 5 plays animations 5x slower
        }
        if let demo = value(after: "--demo") { preview(demo, on: model) }
        if args.contains("--customise") {
            customiser?.show(pane: value(after: "--customise").flatMap(Pane.init(rawValue:)) ?? .appearance)
        }
        switch value(after: "--state") {
        case "idle": model.forcedState = .idle
        case "compact": model.forcedState = .compact
        case "expanded": model.forcedState = .expanded
        case "banner": model.forcedState = .banner
        default: break
        }
    }

    private func preview(_ name: String, on model: NotchModel) {
        switch name {
        case "timer": model.startTimer(minutes: 25)
        case "music": model.startDemoMusic()
        case "claude":
            model.claudeNeedsYou(ClaudeWait(sessionID: "preview", project: "Notch",
                                            message: "Claude needs your permission to use Bash", since: Date()))
        case "done":
            model.claudeUpdate(ClaudeUpdate(kind: .finished, sessions: ["preview-done"], headline: "Claude finished",
                                            project: "Notch", message: "Added charging and headphone banners"))
        case "charging":
            model.show(Banner(symbol: "bolt.fill", tint: .green, title: "Charging",
                              accessory: .battery(level: 76, charging: true), duration: 3))
        case "airpods":
            // Like the real thing: "Connected" first, then the battery arrives and fills in.
            let banner = Banner(symbol: "airpodspro", title: "AirPods Pro", subtitle: "Connected", duration: 4)
            model.show(banner)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 * Motion.slowdown) { [weak model] in
                MainActor.assumeIsolated {
                    model?.updateBanner(banner.id, subtitle: "L 80% · R 75% · Case 40%",
                                        accessory: .battery(level: 75, charging: false))
                }
            }
        case "ended":
            model.claudeUpdate(ClaudeUpdate(kind: .ended, sessions: ["preview-ended"], headline: "Session ended",
                                            project: "Notch", message: "Claude Code · ran 1h 12m"))
        case "build":
            model.show(Banner(symbol: "terminal.fill", tint: .green, title: "swift build finished",
                              subtitle: "took 21s", accessory: .check, duration: 4.5))
        case "meeting":
            model.meeting = Meeting(id: "demo", title: "Design review", start: Date().addingTimeInterval(4 * 60),
                                    end: Date().addingTimeInterval(34 * 60), calendar: "Work",
                                    color: RGB(red: 0.2, green: 0.55, blue: 1), location: nil,
                                    joinURL: URL(string: "https://meet.google.com/abc-defg-hij"), service: "Google Meet")
        default: break
        }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // The icon mirrors the island (idle notch, pill, a dot when something needs you).
        let icon = StatusIcon(button: item.button)
        statusIcon = icon
        if let model {
            statusWatch = model.objectWillChange.sink { [weak self, weak model] _ in
                // objectWillChange fires before the change lands: read it on the next turn.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let model, let icon = self?.statusIcon else { return }
                        let next = model.statusPose
                        icon.show(next.pose, tooltip: next.tooltip)
                    }
                }
            }
            let now = model.statusPose
            icon.show(now.pose, tooltip: now.tooltip)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak item] in
            MainActor.assumeIsolated {
                guard let frame = item?.button?.window?.frame else { return log("menu bar icon: not placed") }
                log("menu bar icon: \(item?.isVisible == true ? "showing" : "hidden") at x \(Int(frame.minX)), \(Int(frame.width)) pt wide")
            }
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(menuItem("Customise…", #selector(openCustomiser), key: ","))
        let awake = menuItem("Keep Mac Awake", #selector(toggleKeepAwake))
        menu.addItem(awake)
        keepAwakeItem = awake
        menu.addItem(.separator())
        let timer = menuItem("Start Focus Timer", #selector(toggleTimer))
        menu.addItem(timer)
        timerItem = timer
        let clear = menuItem("Clear Updates", #selector(clearUpdates))
        menu.addItem(clear)
        clearItem = clear
        let update = menuItem("Update Notch…", #selector(openUpdates))
        update.isHidden = true
        menu.addItem(update)
        updateItem = update
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Notch", #selector(quit), key: "q"))
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleTimer() {
        if model?.timer == nil { model?.startTimer(minutes: 25) } else { model?.stopTimer() }
    }
    @objc private func clearUpdates() { model?.clearUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }

    /// The menu bar macOS shows while the customiser is open (Notch is a regular app then).
    /// Its Edit menu is also what makes ⌘X, ⌘C, ⌘V, ⌘A and ⌘Z work in text fields: AppKit
    /// sends those keys through the menu, and without one they did nothing. No Hide (⌘H):
    /// hiding the app would hide the island too.
    static func mainMenu() -> NSMenu {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        func add(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }
        _ = add("Notch", [
            item("About Notch", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Quit Notch", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = add("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        NSApp.windowsMenu = add("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        return main
    }
}
