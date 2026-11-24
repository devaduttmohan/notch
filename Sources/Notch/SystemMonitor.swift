import AppKit
import Darwin

/// One of your processes that has been working far too hard, or holding far too much memory.
struct RunawayProcess: Equatable, Identifiable {
    enum Reason: Equatable { case cpu, memory }

    var pid: Int32
    var name: String
    var folder: String?           // its working folder, e.g. ~/Projects/app-v1 (tells dev servers apart)
    var cpu: Double               // % of one core over the last half minute, like Activity Monitor
    var memoryGB: Double
    var reason: Reason
    var since: Date
    var history: [Double]         // CPU % over the last few minutes, for the sparkline
    var quitting = false          // asked to quit and still running: offer Force Quit

    var id: Int32 { pid }
}

/// Watches for runaway processes, a nearly full disk and a hot Mac. Public libproc calls on
/// your own processes (other users' and the system's aren't readable, and aren't yours to
/// stop anyway); no permissions needed.
@MainActor final class SystemMonitor {
    var onRunaway: ((RunawayProcess?) -> Void)?
    var onBanner: ((Banner) -> Void)?

    /// Build tools and VMs work hard on purpose; these are skipped unless you remove them.
    nonisolated static let defaultIgnored = ["swift-frontend", "swift-build", "swiftc", "clang", "ld", "ld64", "cc1plus",
                                 "rustc", "cargo", "go", "javac", "xcodebuild", "com.apple.Virtualization.VirtualMachine",
                                 "qemu-system-aarch64", "qemu-system-x86_64"]

    private struct Sample: Sendable {
        var pid: Int32
        var name: String
        var cpuNanos: UInt64
        var resident: UInt64
    }
    private struct Point {
        var time: Date
        var cpuNanos: UInt64
        var resident: UInt64
    }

    private var history: [Int32: [Point]] = [:]
    private var names: [Int32: String] = [:]
    private var flagged: RunawayProcess?
    private var announced: Set<Int32> = []
    private var snoozed: [String: Date] = [:]
    private var sampler: Timer?
    private var diskTimer: Timer?
    private var diskWarned: Int?          // the lowest threshold already warned about (GB)
    private var lastHeatWarning = Date.distantPast
    private var observers: [any NSObjectProtocol] = []

    /// How often to look, and how long a process must stay hot (shorter in tests).
    static var sampleEvery: TimeInterval = 5
    static var sustained: TimeInterval = 120

    func start() {
        sampler = Timer.scheduledTimer(withTimeInterval: Self.sampleEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        sampler?.tolerance = 1
        diskTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDisk() }
        }
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.thermalChanged() }
        })
        sample()
        checkDisk()
        let free = Self.freeDiskGB().map { String(format: "%.0f GB free", $0) } ?? "disk unknown"
        log("system health: watching processes (alert at \(SettingsStore.shared.value.cpuAlert)% CPU or \(SettingsStore.shared.value.memoryAlertGB) GB), \(free)")
    }

    // MARK: Processes

    private func sample() {
        let me = getpid()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let samples = Self.readProcesses(excluding: me)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.digest(samples) }
            }
        }
    }

    private func digest(_ samples: [Sample]) {
        let now = Date()
        var alive = Set<Int32>()
        for sample in samples {
            alive.insert(sample.pid)
            names[sample.pid] = sample.name
            var points = history[sample.pid] ?? []
            // A pid reused by a new process: its CPU time went backwards. Start over.
            if let last = points.last, sample.cpuNanos < last.cpuNanos { points = [] }
            points.append(Point(time: now, cpuNanos: sample.cpuNanos, resident: sample.resident))
            points.removeAll { now.timeIntervalSince($0.time) > 300 }
            history[sample.pid] = points
        }
        for pid in history.keys where !alive.contains(pid) {
            history[pid] = nil
            names[pid] = nil
            announced.remove(pid)
        }
        evaluate(now: now)
    }

    private func evaluate(now: Date) {
        let settings = SettingsStore.shared.value
        guard settings.systemHealth else { return publish(nil) }
        let cpuLimit = Double(settings.cpuAlert)
        let memoryLimit = Double(settings.memoryAlertGB)
        let ignored = Set(settings.ignoredProcesses)

        // Still running hot? Keep showing it, with fresh numbers; cooled down or gone: clear.
        if var current = flagged {
            guard let points = history[current.pid] else { return publish(nil) }
            let recent = Self.cpu(points, over: 30, now: now)
            let memory = Double(points.last?.resident ?? 0) / 1_073_741_824
            let stillHot = current.reason == .cpu ? recent >= cpuLimit * 0.7 : memory >= memoryLimit * 0.9
            guard stillHot, !ignored.contains(current.name) else { return publish(nil) }
            current.cpu = recent
            current.memoryGB = memory
            current.history = Self.sparkline(points)
            return publish(current)
        }

        var worst: (score: Double, process: RunawayProcess)?
        for (pid, points) in history {
            guard let name = names[pid], !ignored.contains(name),
                  (snoozed[name] ?? .distantPast) < now,
                  let first = points.first, now.timeIntervalSince(first.time) >= Self.sustained - Self.sampleEvery
            else { continue }
            let sustainedCPU = Self.cpu(points, over: Self.sustained, now: now)
            let recentCPU = Self.cpu(points, over: 30, now: now)
            let memory = Double(points.last?.resident ?? 0) / 1_073_741_824
            let memoryHeld = points.suffix(4).allSatisfy { Double($0.resident) / 1_073_741_824 >= memoryLimit }
            var reason: RunawayProcess.Reason?
            var score = 0.0
            if sustainedCPU >= cpuLimit && recentCPU >= cpuLimit * 0.8 {
                reason = .cpu
                score = sustainedCPU / cpuLimit
            } else if memoryHeld && points.count >= 4 {
                reason = .memory
                score = memory / memoryLimit
            }
            guard let reason, score > (worst?.score ?? 0) else { continue }
            worst = (score, RunawayProcess(pid: pid, name: Self.displayName(pid: pid, fallback: name),
                                           folder: Self.workingFolder(pid), cpu: recentCPU, memoryGB: memory,
                                           reason: reason, since: now.addingTimeInterval(-Self.sustained),
                                           history: Self.sparkline(points)))
        }
        guard let found = worst?.process else { return publish(nil) }
        if !announced.contains(found.pid) {
            announced.insert(found.pid)
            log("system health: \(found.name) (pid \(found.pid)) at \(Int(found.cpu))% CPU, \(String(format: "%.1f", found.memoryGB)) GB"
                + (found.folder.map { " in \($0)" } ?? ""))
            onBanner?(Banner(symbol: found.reason == .cpu ? "flame.fill" : "memorychip.fill", tint: .orange,
                             title: found.reason == .cpu ? "\(found.name) is using \(Int(found.cpu))% CPU"
                                                         : "\(found.name) is holding \(String(format: "%.1f", found.memoryGB)) GB",
                             subtitle: "for 2 min" + (found.folder.map { " · \($0)" } ?? "") + " · hover to quit",
                             duration: 5))
        }
        publish(found)
    }

    private func publish(_ process: RunawayProcess?) {
        var process = process
        if let current = flagged, current.pid == process?.pid { process?.quitting = current.quitting }
        guard process != flagged else { return }
        flagged = process
        onRunaway?(process)
    }

    // MARK: Actions

    /// Quit like the Dock does for apps (they can save); a polite SIGTERM for everything else.
    func quit(_ process: RunawayProcess) {
        if let app = NSRunningApplication(processIdentifier: process.pid), app.bundleIdentifier != nil {
            app.terminate()
        } else {
            kill(process.pid, SIGTERM)
        }
        log("system health: asked \(process.name) (pid \(process.pid)) to quit")
        flagged?.quitting = true
        if let flagged { onRunaway?(flagged) }
    }

    func forceQuit(_ process: RunawayProcess) {
        kill(process.pid, SIGKILL)
        log("system health: force quit \(process.name) (pid \(process.pid))")
        history[process.pid] = nil
        publish(nil)
    }

    /// Not now: leave this one alone for half an hour.
    func snooze(_ process: RunawayProcess) {
        snoozed[names[process.pid] ?? process.name] = Date().addingTimeInterval(30 * 60)
        publish(nil)
    }

    /// Never warn about this program again (undo in the customiser).
    func ignore(_ process: RunawayProcess) {
        let name = names[process.pid] ?? process.name
        if !SettingsStore.shared.value.ignoredProcesses.contains(name) {
            SettingsStore.shared.value.ignoredProcesses.append(name)
        }
        publish(nil)
    }

    // MARK: Disk and heat

    private func checkDisk() {
        guard SettingsStore.shared.value.systemHealth, let free = Self.freeDiskGB() else { return }
        let threshold = [5, 10].first { free < Double($0) }
        if let threshold, threshold < (diskWarned ?? .max) {
            diskWarned = threshold
            onBanner?(Banner(symbol: "internaldrive.fill", tint: threshold <= 5 ? .red : .orange, title: "Low disk space",
                             subtitle: String(format: "%.1f GB left on your Mac", free), duration: 6))
            log(String(format: "system health: low disk, %.1f GB free", free))
        } else if threshold == nil, free > 12 {
            diskWarned = nil
        }
    }

    private func thermalChanged() {
        let state = ProcessInfo.processInfo.thermalState
        guard SettingsStore.shared.value.systemHealth, state == .serious || state == .critical,
              Date().timeIntervalSince(lastHeatWarning) > 600 else { return }
        lastHeatWarning = Date()
        onBanner?(Banner(symbol: "thermometer.high", tint: state == .critical ? .red : .orange,
                         title: "Your Mac is running hot",
                         subtitle: "macOS is slowing it down to cool off", duration: 6))
        log("system health: thermal state \(state == .critical ? "critical" : "serious")")
    }

    nonisolated static func freeDiskGB() -> Double? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { Double($0) / 1_000_000_000 }
    }

    // MARK: Reading processes

    /// CPU % of one core over the last `seconds`.
    private static func cpu(_ points: [Point], over seconds: TimeInterval, now: Date) -> Double {
        guard let last = points.last,
              let first = points.last(where: { now.timeIntervalSince($0.time) >= seconds - sampleEvery / 2 }) ?? points.first,
              last.time > first.time else { return 0 }
        let used = Double(last.cpuNanos &- first.cpuNanos) / 1e9
        return used / last.time.timeIntervalSince(first.time) * 100
    }

    /// CPU % between each pair of samples, oldest first.
    private static func sparkline(_ points: [Point]) -> [Double] {
        zip(points, points.dropFirst()).map { a, b in
            let wall = b.time.timeIntervalSince(a.time)
            return wall > 0 ? Double(b.cpuNanos &- a.cpuNanos) / 1e9 / wall * 100 : 0
        }
    }

    nonisolated private static func readProcesses(excluding me: Int32) -> [Sample] {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        var samples: [Sample] = []
        samples.reserveCapacity(Int(filled))
        for pid in pids.prefix(Int(max(filled, 0))) where pid > 0 && pid != me {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }   // not ours
            // Task times are in Mach time units (nanoseconds on Intel, ticks on Apple silicon).
            let ticks = info.pti_total_user + info.pti_total_system
            let nanos = ticks * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
            var nameBuffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            samples.append(Sample(pid: pid, name: name.isEmpty ? "pid \(pid)" : name, cpuNanos: nanos,
                                  resident: info.pti_resident_size))
        }
        return samples
    }

    /// An app's own name ("Brave Browser Helper (Renderer)"), else the process name ("node").
    static func displayName(pid: Int32, fallback: String) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? fallback
    }

    /// The folder it runs in, if it's somewhere in your home folder (dev servers, scripts).
    static func workingFolder(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let home = NSHomeDirectory()
        guard path.hasPrefix(home + "/") else { return nil }
        return "~" + path.dropFirst(home.count)
    }
}
