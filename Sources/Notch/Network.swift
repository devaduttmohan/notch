import AppKit
import Combine
import Network
import SystemConfiguration

/// Whether the Mac is online, and whether the VPNs you use are connected, from macOS's own
/// network state (the network path, and the VPN services in System Settings). Nothing is sent
/// anywhere to find out.
///
/// - Offline counts once it has lasted 5 s, a VPN once it has been down 15 s (it reconnects by
///   itself after every network change), and neither before a minute after launch or waking
///   (the Wi-Fi and the VPN take a moment to come back).
/// - Then a banner, and the notch shows it, with how long, until it's back or you dismiss it.
/// - Back: a banner saying how long it was down, and `onReconnect` (PRs and builds look again
///   straight away instead of waiting out their back-off).
/// - A VPN counts once Notch has seen it connected, so one you never use is never news. While
///   the Mac is offline, a VPN going down with it isn't news of its own.
@MainActor final class NetworkWatch: ObservableObject {
    static let shared = NetworkWatch()

    struct VPN: Identifiable, Equatable {
        var id: String               // the network service
        var name: String             // as in System Settings › VPN ("Private Access")
        var app: URL?                // the app that provides it (Jamf Trust), when there is one
        var connected = false
    }

    /// Every VPN in System Settings, and whether each is connected (the customiser lists them).
    @Published private(set) var vpns: [VPN] = []
    @Published private(set) var online = true

    /// What the notch should show (nil: all's well).
    var onChange: ((NetworkTrouble?) -> Void)?
    var onBanner: ((Banner) -> Void)?
    /// Back online, or a VPN back: worth looking at PRs and builds again now.
    var onReconnect: (() -> Void)?

    static let offlineGrace: TimeInterval = 5
    static let vpnGrace: TimeInterval = 15
    static let settleAfterWake: TimeInterval = 60

    private var offlineSince: Date?
    private var reportedOffline = false
    private var downSince: [String: Date] = [:]          // a VPN you use, disconnected since
    private var reportedDown: Set<String> = []
    private var used: Set<String> = []                    // VPNs seen connected
    private var dismissed: Set<String> = []               // trouble keys hidden until they're back
    private var wokeAt: Date?
    private var asleep = false
    private var shown: NetworkTrouble?
    private var timer: Timer?
    private var recheck: Timer?
    private var monitor: NWPathMonitor?
    private var lastPath = ""
    private var connections: [String: SCNetworkConnection] = [:]
    /// VPNs whose state macOS has told us (a connection's first read says "disconnected" until
    /// its first callback, a few milliseconds later).
    private var heard: Set<String> = []
    private var observers: [any NSObjectProtocol] = []
    private var settingsWatch: AnyCancellable?

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.slept() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.woke() }
        })
        // The module or VPN alerts switched: look again once it's saved.
        settingsWatch = SettingsStore.shared.$value.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.evaluate() } }
        }
        wokeAt = Date()                                   // just launched: let the network settle
        loadVPNs()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let up = Self.online(path.status, through: path.availableInterfaces.map(\.type))
            let how = path.availableInterfaces.map { "\($0.name) \($0.type)" }.joined(separator: ", ")
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.pathUpdate(online: up, how: how) } }
        }
        monitor.start(queue: DispatchQueue(label: "notch.network"))
        self.monitor = monitor
        // A report from macOS can be missed (or come in stale while a VPN's settings are rewritten):
        // ask again now and then, so a wrong state can't stick.
        recheck = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readVPNs() }
        }
        recheck?.tolerance = 10
        log("network: watching" + (vpns.isEmpty ? " (no VPNs in System Settings)" : "; VPNs: " + vpns.map(\.name).joined(separator: ", ")))
    }

    // MARK: What changed

    /// The network path changed: is there a way out at all?
    func pathChanged(online up: Bool, at now: Date = Date()) {
        guard up != online else { return evaluate(at: now) }
        online = up
        if up {
            let since = offlineSince
            offlineSince = nil
            dismissed.remove(NetworkTrouble.offlineKey)
            // A VPN that went down with the network gets its own moment to reconnect.
            for id in downSince.keys where !reportedDown.contains(id) { downSince[id] = now }
            if reportedOffline, let since {
                reportedOffline = false
                let down = CommandAlerts.duration(now.timeIntervalSince(since))
                log("network: back online after \(down)")
                if SettingsStore.shared.value.network {
                    onBanner?(Banner(symbol: "wifi", tint: .green, title: "Back online", subtitle: "Offline for \(down)", duration: 4))
                }
                onReconnect?()
            }
        } else {
            offlineSince = now
        }
        evaluate(at: now)
    }

    /// A VPN connected or disconnected (connecting counts as not yet).
    func vpnChanged(id: String, connected: Bool, at now: Date = Date()) {
        guard let index = vpns.firstIndex(where: { $0.id == id }), vpns[index].connected != connected else { return }
        vpns[index].connected = connected
        let name = vpns[index].name
        if connected {
            used.insert(id)
            dismissed.remove(id)
            let since = downSince.removeValue(forKey: id)
            if reportedDown.remove(id) != nil, let since {
                let down = CommandAlerts.duration(now.timeIntervalSince(since))
                log("network: \(name) connected again after \(down)")
                let settings = SettingsStore.shared.value
                if settings.network && settings.vpnAlerts {
                    onBanner?(Banner(symbol: "checkmark.shield.fill", tint: .green, title: "\(name) connected",
                                     subtitle: "VPN · down for \(down)", duration: 4))
                }
                onReconnect?()
            }
        } else if used.contains(id) {
            downSince[id] = now
        }
        evaluate(at: now)
    }

    func slept() {
        asleep = true
        timer?.invalidate()
    }

    /// Back from sleep: drops that aren't news yet start counting now, after a minute to settle.
    func woke(at now: Date = Date()) {
        asleep = false
        wokeAt = now
        if offlineSince != nil, !reportedOffline { offlineSince = now }
        for id in downSince.keys where !reportedDown.contains(id) { downSince[id] = now }
        readVPNs(at: now)
        evaluate(at: now)
    }

    /// Dismiss on the page: hidden until it's back (and goes down again).
    func dismiss() {
        guard let shown else { return }
        dismissed.insert(shown.key)
        log("network: dismissed \(shown.name)")
        evaluate()
    }

    // MARK: What's news

    /// Which drops are news by now, what the notch shows, and when to look again.
    func evaluate(at now: Date = Date()) {
        timer?.invalidate()
        guard !asleep else { return }
        let settings = SettingsStore.shared.value
        guard settings.network else { return publish(nil) }
        let settled = wokeAt.map { $0.addingTimeInterval(Self.settleAfterWake) } ?? .distantPast
        var next: Date?

        if let since = offlineSince, !reportedOffline {
            let due = max(since.addingTimeInterval(Self.offlineGrace), settled)
            if now >= due {
                reportedOffline = true
                log("network: offline since \(since.formatted(date: .omitted, time: .standard))")
                onBanner?(Banner(symbol: "wifi.slash", tint: .orange, title: "You're offline",
                                 subtitle: "PRs and builds catch up when you're back", duration: 4))
            } else {
                next = due
            }
        }
        // A VPN down while the Mac is online (offline, it's down with everything else).
        if settings.vpnAlerts, offlineSince == nil {
            for vpn in vpns {
                guard let since = downSince[vpn.id], !reportedDown.contains(vpn.id) else { continue }
                let due = max(since.addingTimeInterval(Self.vpnGrace), settled)
                if now >= due {
                    reportedDown.insert(vpn.id)
                    log("network: \(vpn.name) disconnected since \(since.formatted(date: .omitted, time: .standard))")
                    onBanner?(Banner(symbol: "shield.slash.fill", tint: .orange, title: "\(vpn.name) disconnected",
                                     subtitle: "VPN · sites that need it won't load", duration: 4))
                } else {
                    next = min(next ?? due, due)
                }
            }
        }

        publish(trouble(settings: settings))
        if let next {
            timer = Timer.scheduledTimer(withTimeInterval: max(next.timeIntervalSince(now), 0) + 0.05, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
        }
    }

    /// Offline first (it explains everything else), then a VPN.
    private func trouble(settings: NotchSettings) -> NetworkTrouble? {
        if reportedOffline, let since = offlineSince, !dismissed.contains(NetworkTrouble.offlineKey) {
            return NetworkTrouble(key: NetworkTrouble.offlineKey, kind: .offline, since: since)
        }
        guard settings.vpnAlerts else { return nil }
        for vpn in vpns where reportedDown.contains(vpn.id) && !dismissed.contains(vpn.id) {
            if let since = downSince[vpn.id] {
                return NetworkTrouble(key: vpn.id, kind: .vpn(name: vpn.name, app: vpn.app), since: since)
            }
        }
        return nil
    }

    private func publish(_ trouble: NetworkTrouble?) {
        guard trouble != shown else { return }
        shown = trouble
        onChange?(trouble)
    }

    // MARK: Reading macOS's state

    private func pathUpdate(online up: Bool, how: String) {
        let path = (up ? "online" : "offline") + (how.isEmpty ? " (no interfaces)" : " (\(how))")
        if path != lastPath { log("network: path \(path)") }
        lastPath = path
        loadVPNs()                                        // one added? (and how each is now)
        pathChanged(online: up)
    }

    /// Online means a way out over a real link (Wi-Fi, Ethernet, cellular). A VPN's tunnel can
    /// keep a route of its own after the Wi-Fi goes, but it carries nothing without one.
    nonisolated static func online(_ status: NWPath.Status, through interfaces: [NWInterface.InterfaceType]) -> Bool {
        status == .satisfied && interfaces.contains { $0 != .other && $0 != .loopback }
    }

    /// The VPN services in System Settings (enabled ones), each watched for connecting and dropping.
    func loadVPNs() {
        guard let prefs = SCPreferencesCreate(nil, "Notch" as CFString, nil) else { return }
        var found: [VPN] = []
        for service in (SCNetworkServiceCopyAll(prefs) as? [SCNetworkService]) ?? [] where SCNetworkServiceGetEnabled(service) {
            guard let interface = SCNetworkServiceGetInterface(service),
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                  let id = SCNetworkServiceGetServiceID(service) as String? else { continue }
            let detail = SCPreferencesPathGetValue(prefs, "/NetworkServices/\(id)/Interface" as CFString) as? [String: Any]
            let subtype = detail?["SubType"] as? String
            // App VPNs (Jamf Trust, Cisco, WireGuard…), IKEv2 and Cisco IPSec, and L2TP (a PPP
            // service; PPP on its own is a modem or PPPoE, not a VPN).
            guard ["VPN", "IPSec", "IKEv2"].contains(type) || (type == "PPP" && subtype == "L2TP") else { continue }
            let app = type == "VPN" ? subtype.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } : nil
            found.append(VPN(id: id, name: SCNetworkServiceGetName(service) as String? ?? "VPN", app: app))
        }
        let merged = Self.merged(found, into: vpns)
        let added = merged.filter { connections[$0.id] == nil }
        if merged != vpns { vpns = merged }
        for vpn in added {
            var context = SCNetworkConnectionContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                                     retain: nil, release: nil, copyDescription: nil)
            guard let connection = SCNetworkConnectionCreateWithServiceID(nil, vpn.id as CFString, { connection, status, info in
                guard let info else { return }
                let watch = Unmanaged<NetworkWatch>.fromOpaque(info).takeUnretainedValue()
                let connected = status == .connected
                MainActor.assumeIsolated { watch.heard(from: connection, connected: connected) }
            }, &context) else { continue }
            SCNetworkConnectionScheduleWithRunLoop(connection, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            connections[vpn.id] = connection
        }
        readVPNs()
    }

    /// The VPNs in System Settings now, merged into those already known. One missing from a
    /// read keeps its place and its state: a VPN app rewriting its settings can make it vanish
    /// for a moment (seen with Jamf Trust when the Wi-Fi changes), and starting it afresh then
    /// took a stale "not connected" that stuck. (One really removed stays listed until Notch
    /// restarts, and is never news: it can't connect.)
    static func merged(_ found: [VPN], into known: [VPN]) -> [VPN] {
        var list = found.map { vpn in
            var vpn = vpn
            vpn.connected = known.first { $0.id == vpn.id }?.connected ?? false
            return vpn
        }
        list += known.filter { old in !found.contains { $0.id == old.id } }
        return list
    }

    /// Tests: watch these VPNs instead of the ones in System Settings (merged, as a read is).
    func use(vpns: [VPN]) {
        self.vpns = Self.merged(vpns, into: self.vpns)
    }

    /// A VPN's state, as macOS reports it (scheduled on the main run loop).
    private func heard(from connection: SCNetworkConnection, connected: Bool) {
        guard let id = connections.first(where: { $0.value === connection })?.key,
              let vpn = vpns.first(where: { $0.id == id }) else { return }
        if heard.insert(id).inserted { log("network: \(vpn.name) is \(connected ? "connected" : "not connected")") }
        vpnChanged(id: id, connected: connected)
    }

    /// Asks again (the network changed, or the Mac woke), for the VPNs macOS has reported on.
    private func readVPNs(at now: Date = Date()) {
        for vpn in vpns where heard.contains(vpn.id) {
            guard let connection = connections[vpn.id] else { continue }
            vpnChanged(id: vpn.id, connected: SCNetworkConnectionGetStatus(connection) == .connected, at: now)
        }
    }

    // MARK: Opening things

    static func openNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
