import AppKit
import Combine
import SwiftUI

/// Everything the customiser changes. Saved as JSON in
/// ~/Library/Application Support/Notch/settings.json; missing keys fall back to the defaults
/// here, so older files keep working as settings are added.
struct NotchSettings: Codable, Equatable {
    // Appearance
    var background: BackgroundStyle = .midnight
    var accent: AccentChoice = .automatic
    var shadow: ShadowStyle = .floating
    var tintedGlow = true
    var edgeHighlight = true
    var size: IslandSize = .standard
    var roundness: Double = 1                 // 0.7 ... 1.3, scales the bottom corners

    // Motion
    var motion: MotionStyle = .smooth
    var speed: Double = 1                     // 0.6 ... 1.6, higher is faster
    var contentEffect: ContentEffect = .blur
    var reduceMotion: ReduceMotion = .system

    // Behaviour
    var openOn: OpenTrigger = .hover
    var haptics = true
    var sounds = true
    var display: DisplayChoice = .notched
    var pinAboveSpaces = true                 // stay on screen through Space switches (private window-server API)

    // Modules
    var music = true
    var timers = true
    var claude = true
    var commands = true
    var battery = true
    var headphones = true
    var meetings = true
    var systemHealth = true
    var pullRequests = true
    var builds = false                        // Jenkins builds you start (on once you sign in)
    var jenkinsURL = ""
    var jenkinsUser = ""
    var jenkinsJobs: [String] = []            // jobs you've built (learned), for your build history

    // Meetings
    var meetingLead = 10                      // minutes before a meeting that the pill appears
    var meetingTimeLeft = true                // during a meeting, show the time left
    var meetingChime = true
    var videoMeetingsOnly = false
    var hiddenCalendars: [String] = []        // calendar identifiers switched off

    // CPU & memory (live)
    var loadMonitor = false
    var loadPill: LoadPill = .busy            // when the closed island shows it
    var loadShow: LoadShow = .both
    var loadBusyCPU = 80                      // % of the whole Mac, for 30 s, counts as busy

    // System health
    var cpuAlert = 150                        // % of one core, sustained for 2 minutes
    var memoryAlertGB = 8
    var ignoredProcesses: [String] = SystemMonitor.defaultIgnored

    // Pull requests
    var prIgnoredAuthors = ["saas-devops-2025", "surveysparrow-hatch"]   // bots whose comments are boilerplate

    // Keep awake
    var keepAwakeClaude = true                // while a Claude Code turn is running
    var keepAwakeCommands = true              // while `notchctl run` commands run
}

/// When the closed island shows CPU & memory: always, only while the Mac is busy, or never
/// (the open island still has its page).
enum LoadPill: String, Codable, CaseIterable, Identifiable {
    case always, busy, never
    var id: Self { self }
    var name: String { [.always: "Always", .busy: "When busy", .never: "Island only"][self]! }
}

enum LoadShow: String, Codable, CaseIterable, Identifiable {
    case both, cpu, memory
    var id: Self { self }
    var name: String { [.both: "Both", .cpu: "CPU", .memory: "Memory"][self]! }
}

enum BackgroundStyle: String, Codable, CaseIterable, Identifiable {
    case midnight, graphite, ambient, aurora
    var id: Self { self }
    var name: String { rawValue.capitalized }
    var detail: String {
        switch self {
        case .midnight: "Pure black, one with the notch"
        case .graphite: "Black melting into a soft sheen"
        case .ambient: "Glows with what's playing"
        case .aurora: "Slow drifting colour light"
        }
    }
}

enum AccentChoice: String, Codable, CaseIterable, Identifiable {
    case automatic, blue, purple, pink, red, orange, yellow, green, teal, graphite
    var id: Self { self }
    var name: String { self == .automatic ? "Automatic" : rawValue.capitalized }
    /// nil for automatic: each activity keeps its own colour.
    var color: Color? {
        switch self {
        case .automatic: nil
        case .blue: Color(red: 0.04, green: 0.52, blue: 1.0)
        case .purple: Color(red: 0.69, green: 0.32, blue: 0.87)
        case .pink: Color(red: 1.0, green: 0.22, blue: 0.47)
        case .red: Color(red: 1.0, green: 0.27, blue: 0.23)
        case .orange: Color(red: 1.0, green: 0.62, blue: 0.04)
        case .yellow: Color(red: 1.0, green: 0.84, blue: 0.04)
        case .green: Color(red: 0.19, green: 0.82, blue: 0.35)
        case .teal: Color(red: 0.25, green: 0.78, blue: 0.85)
        case .graphite: Color(white: 0.72)
        }
    }
}

enum ShadowStyle: String, Codable, CaseIterable, Identifiable {
    case off, soft, floating, dramatic
    var id: Self { self }
    var name: String { rawValue.capitalized }
    var radius: CGFloat { [.off: 0, .soft: 10, .floating: 18, .dramatic: 30][self]! }
    var opacity: Double { [.off: 0, .soft: 0.25, .floating: 0.38, .dramatic: 0.6][self]! }
    var drop: CGFloat { [.off: 0, .soft: 4, .floating: 8, .dramatic: 14][self]! }
}

enum IslandSize: String, Codable, CaseIterable, Identifiable {
    case compact, standard, large
    var id: Self { self }
    var name: String { rawValue.capitalized }
}

enum MotionStyle: String, Codable, CaseIterable, Identifiable {
    case snappy, smooth, bouncy, gentle
    var id: Self { self }
    var name: String { rawValue.capitalized }
    var detail: String {
        switch self {
        case .snappy: "Quick and crisp"
        case .smooth: "The island's own feel"
        case .bouncy: "Playful overshoot"
        case .gentle: "Slow and calm"
        }
    }
    /// How this personality bends every spring: duration scale and extra bounce.
    var tuning: (duration: Double, bounce: Double) {
        switch self {
        case .snappy: (0.78, -0.08)
        case .smooth: (1, 0)
        case .bouncy: (1.12, 0.14)
        case .gentle: (1.35, -0.06)
        }
    }
}

enum ContentEffect: String, Codable, CaseIterable, Identifiable {
    case blur, zoom, fade
    var id: Self { self }
    var name: String { rawValue.capitalized }
}

enum ReduceMotion: String, Codable, CaseIterable, Identifiable {
    case system, always, never
    var id: Self { self }
    var name: String { [.system: "System", .always: "Always", .never: "Never"][self]! }
}

enum OpenTrigger: String, Codable, CaseIterable, Identifiable {
    case hover, hold, click
    var id: Self { self }
    var name: String { [.hover: "Hover", .hold: "Hover & hold", .click: "Click"][self]! }
}

enum DisplayChoice: String, Codable, CaseIterable, Identifiable {
    case notched, primary
    var id: Self { self }
    var name: String { self == .notched ? "Built-in display" : "Primary display" }
}

/// The one copy of the settings: observed by the island, the customiser and the services.
@MainActor final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var value: NotchSettings {
        didSet { if value != oldValue { scheduleSave() } }
    }

    /// `NOTCH_SETTINGS_FILE` points somewhere else (tests, so they never touch yours).
    static var fileURL: URL {
        if let custom = ProcessInfo.processInfo.environment["NOTCH_SETTINGS_FILE"] { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Notch/settings.json")
    }

    private var saveTask: DispatchWorkItem?

    init(value: NotchSettings? = nil) {
        self.value = value ?? Self.load()
    }

    func reset() {
        value = NotchSettings()
    }

    /// Stored keys over the defaults, so a file from an older version still loads.
    private static func load() -> NotchSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(NotchSettings())) as? [String: Any]
        else { return NotchSettings() }
        let merged = defaults.merging(stored) { _, new in new }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let settings = try? JSONDecoder().decode(NotchSettings.self, from: mergedData)
        else { return NotchSettings() }
        return settings
    }

    /// A slider drag changes the value many times a second; write once it settles.
    private func scheduleSave() {
        saveTask?.cancel()
        let value = self.value
        let task = DispatchWorkItem {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(value) else { return }
            try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: Self.fileURL, options: .atomic)
        }
        saveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
    }
}

/// Haptic taps on the trackpad, unless switched off.
enum Haptics {
    @MainActor static func tap(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
        guard SettingsStore.shared.value.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

/// System sounds, unless switched off.
enum Sounds {
    @MainActor static func play(_ name: String) {
        guard SettingsStore.shared.value.sounds else { return }
        NSSound(named: name)?.play()
    }
}
