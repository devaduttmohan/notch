import AppKit
import Darwin

/// Calm, busy (CPU over your threshold for 30 s, or memory pressure raised) or critical.
enum LoadLevel: Equatable { case calm, busy, critical }

/// One app (its helpers summed in) or one process, for "Your apps using the most".
struct LoadProcess: Equatable, Identifiable {
    var id: String                 // the app bundle's path, or "pid:123"
    var name: String
    var folder: String?            // where a non-app process runs (tells dev servers apart)
    var appPath: String?           // for its icon, and to quit the whole app
    var pids: [Int32]
    var cpu: Double                // % of one core, like Activity Monitor
    var memoryGB: Double           // memory footprint, like Activity Monitor's Memory column
}

/// The whole Mac, right now and over the last minute.
struct LoadSnapshot: Equatable {
    struct Point: Equatable { var time: Date; var cpu: Double }

    var time: Date
    var cpu: Double                // % of the whole Mac (all cores), 0…100
    var user: Double
    var system: Double
    var cores: Int
    var history: [Point]           // the last minute or so
    var appGB: Double              // Activity Monitor's App Memory, Wired, Compressed
    var wiredGB: Double
    var compressedGB: Double
    var totalGB: Double
    var swapGB: Double
    var pressure: Int              // the kernel's level: 1 normal, 2 warning, 4 critical
    var cpuLevel: LoadLevel
    var memoryLevel: LoadLevel
    var top: [LoadProcess]

    var usedGB: Double { appGB + wiredGB + compressedGB }
    var availableGB: Double { max(0, totalGB - usedGB) }
    var busy: Bool { cpuLevel != .calm || memoryLevel != .calm }
    /// Worth taking the pill from your music: CPU busy, or memory critical. Memory pressure
    /// that's only elevated (a Mac that swaps all day) waits its turn with background work.
    var pressing: Bool { cpuLevel != .calm || memoryLevel == .critical }
    var pressureName: String { pressure >= 4 ? "high" : pressure >= 2 ? "elevated" : "normal" }
}

/// Reads the Mac's CPU and memory totals (public Mach and sysctl calls; no permissions) every
/// 2 s, every second while its page is open, nothing while you're away. Busy and calm come
/// with some hysteresis, so the pill doesn't flicker around the threshold.
@MainActor final class LoadMonitor {
    var onChange: ((LoadSnapshot?) -> Void)?
    var isAway: () -> Bool = { false }
    /// Your apps using the most (from `SystemMonitor`, which already samples processes).
    var processes: (Int) -> [LoadProcess] = { _ in [] }

    private(set) var snapshot: LoadSnapshot?
    private var timer: Timer?
    private var fast = false
    private var last: (ticks: CPUTicks, time: Date)?
    private var history: [LoadSnapshot.Point] = []
    private var recent: [LoadSnapshot.Point] = []     // CPU readings for the busy/calm averages
    private var cpuBusy = false
    private var memoryBusyUntil = Date.distantPast
    private var wasBusy = false

    /// Busy: CPU averages at least the threshold over this long. Calm again: it averages 10
    /// points under it over `calmAfter`.
    static var busyAfter: TimeInterval = 30
    static var calmAfter: TimeInterval = 15

    var running: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        log("load: watching CPU and memory (\(ProcessInfo.processInfo.activeProcessorCount) cores, "
            + String(format: "%.0f GB", Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824) + ")")
        sample()
        schedule()
    }

    func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        last = nil
        history = []
        recent = []
        cpuBusy = false
        wasBusy = false
        snapshot = nil
        onChange?(nil)
    }

    /// Every second while the CPU & memory page is open; every 2 s otherwise.
    func setFast(_ on: Bool) {
        guard on != fast else { return }
        fast = on
        guard timer != nil else { return }
        schedule()
        if on { sample() }
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: fast ? 1 : 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer?.tolerance = fast ? 0.1 : 0.3
    }

    private func sample() {
        // Away (locked, asleep): don't look; start the CPU deltas afresh when back.
        guard !isAway() else { last = nil; return }
        let now = Date()
        guard let ticks = Self.cpuTicks() else { return }
        defer { last = (ticks, now) }
        guard let last, now.timeIntervalSince(last.time) < 10 else { return }   // first look: a delta needs two
        let delta = ticks.minus(last.ticks)
        let total = Double(delta.total)
        guard total > 0 else { return }
        let user = Double(delta.user + delta.nice) / total * 100
        let system = Double(delta.system) / total * 100
        let cpu = min(100, user + system)
        history.append(.init(time: now, cpu: cpu))
        history.removeAll { now.timeIntervalSince($0.time) > 62 }
        let memory = Self.memory()
        let pressure = Self.pressureLevel()
        snapshot = LoadSnapshot(time: now, cpu: cpu, user: user, system: system,
                                cores: ProcessInfo.processInfo.activeProcessorCount, history: history,
                                appGB: memory.app, wiredGB: memory.wired, compressedGB: memory.compressed,
                                totalGB: memory.total, swapGB: Self.swapUsedGB(), pressure: pressure,
                                cpuLevel: cpuLevel(cpu, now: now, dt: now.timeIntervalSince(last.time)),
                                memoryLevel: memoryLevel(pressure, now: now), top: processes(3))
        if let snapshot, snapshot.busy != wasBusy {
            wasBusy = snapshot.busy
            log(snapshot.busy
                ? "load: busy (CPU \(Int(snapshot.cpu))%, memory \(String(format: "%.1f", snapshot.usedGB)) GB, pressure \(snapshot.pressureName))"
                : "load: calm again")
        }
        onChange?(snapshot)
    }

    /// Averages, so a brief spike or dip changes nothing: busy once CPU has averaged at least
    /// the threshold over the last 30 s; calm once it averages 10 points under over the last
    /// 15 s; critical while busy and averaging 95 % or more over the last 10 s.
    func cpuLevel(_ cpu: Double, now: Date, dt: TimeInterval) -> LoadLevel {
        recent.append(.init(time: now, cpu: cpu))
        recent.removeAll { now.timeIntervalSince($0.time) > Self.busyAfter }
        func average(_ seconds: TimeInterval) -> Double {
            let window = recent.filter { now.timeIntervalSince($0.time) <= seconds }
            return window.isEmpty ? 0 : window.reduce(0) { $0 + $1.cpu } / Double(window.count)
        }
        let threshold = Double(SettingsStore.shared.value.loadBusyCPU)
        let covered = now.timeIntervalSince(recent.first?.time ?? now) >= Self.busyAfter - max(dt, 1) * 1.5
        if !cpuBusy, covered, average(Self.busyAfter) >= threshold { cpuBusy = true }
        else if cpuBusy, average(Self.calmAfter) < threshold - 10 { cpuBusy = false }
        guard cpuBusy else { return .calm }
        return average(10) >= 95 ? .critical : .busy
    }

    /// The kernel's memory pressure (what Activity Monitor's graph colours), held for 20 s so
    /// a brief dip doesn't flicker the pill.
    func memoryLevel(_ pressure: Int, now: Date) -> LoadLevel {
        if pressure >= 4 { memoryBusyUntil = now.addingTimeInterval(20); return .critical }
        if pressure >= 2 { memoryBusyUntil = now.addingTimeInterval(20); return .busy }
        return now < memoryBusyUntil ? .busy : .calm
    }

    // MARK: Reading the Mac

    struct CPUTicks: Equatable {
        var user: UInt64, system: UInt64, idle: UInt64, nice: UInt64
        var total: UInt64 { user &+ system &+ idle &+ nice }
        func minus(_ old: CPUTicks) -> CPUTicks {
            CPUTicks(user: user &- old.user, system: system &- old.system, idle: idle &- old.idle, nice: nice &- old.nice)
        }
    }

    nonisolated static let host = mach_host_self()

    nonisolated static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks                     // user, system, idle, nice
        return CPUTicks(user: UInt64(t.0), system: UInt64(t.1), idle: UInt64(t.2), nice: UInt64(t.3))
    }

    /// Activity Monitor's split: App Memory (anonymous, less purgeable), Wired, Compressed.
    nonisolated static func memory() -> (app: Double, wired: Double, compressed: Double, total: Double) {
        let total = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return (0, 0, 0, total) }
        let page = Double(pageSize) / 1_073_741_824
        let app = Double(UInt64(stats.internal_page_count) &- UInt64(min(stats.purgeable_count, stats.internal_page_count))) * page
        return (app, Double(stats.wire_count) * page, Double(stats.compressor_page_count) * page, total)
    }

    nonisolated static let pageSize: Int = {
        var size = 0
        var length = MemoryLayout<Int>.size
        return sysctlbyname("hw.pagesize", &size, &length, nil, 0) == 0 && size > 0 ? size : Int(getpagesize())
    }()

    nonisolated static func swapUsedGB() -> Double {
        var usage = xsw_usage()
        var length = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &length, nil, 0) == 0 else { return 0 }
        return Double(usage.xsu_used) / 1_073_741_824
    }

    /// 1 normal, 2 warning, 4 critical (as `memory_pressure` and Activity Monitor see it).
    nonisolated static func pressureLevel() -> Int {
        var level: Int32 = 1
        var length = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &length, nil, 0) == 0 else { return 1 }
        return Int(level)
    }
}
