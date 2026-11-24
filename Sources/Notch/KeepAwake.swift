import AppKit
import IOKit.pwr_mgt

/// Keeps the Mac from idle-sleeping while work is going on: a Claude Code turn, a
/// `notchctl run` command, or because you asked. The display may still sleep; the Mac
/// doesn't. (Closing the lid without an external display still sleeps, as macOS insists.)
/// Shows up in `pmset -g assertions` as "Notch: …".
@MainActor final class KeepAwake: ObservableObject {
    enum Reason: Hashable {
        case claude(session: String)
        case command(id: String)
        case manual
    }

    /// The model shows this: on, by hand, and why.
    var onChange: ((AwakeState) -> Void)?
    /// The same, for the customiser.
    @Published private(set) var state = AwakeState()

    private var reasons: [Reason: (label: String, since: Date)] = [:]
    private var assertion: IOPMAssertionID = 0
    private var sweep: Timer?

    func start() {
        // A session that went quiet for an hour (crashed, killed) or a command that never
        // reported back (12 h) shouldn't hold the Mac awake for ever.
        sweep = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dropStale() }
        }
        publish()
    }

    // MARK: Reasons

    func claudeWorking(session: String, project: String) {
        guard SettingsStore.shared.value.keepAwakeClaude else { return set(.claude(session: session), nil) }
        set(.claude(session: session), "Claude is working in \(project)")
    }

    func claudeIdle(session: String) {
        set(.claude(session: session), nil)
    }

    func commandStarted(id: String, command: String) {
        guard SettingsStore.shared.value.keepAwakeCommands else { return }
        set(.command(id: id), "Running \(command)")
    }

    func commandFinished(id: String) {
        set(.command(id: id), nil)
    }

    var manual: Bool { reasons[.manual] != nil }

    func toggleManual() {
        set(.manual, manual ? nil : "Kept awake by you")
    }

    /// Settings changed: drop reasons that are switched off.
    func settingsChanged(_ settings: NotchSettings) {
        for reason in reasons.keys {
            switch reason {
            case .claude where !settings.keepAwakeClaude, .command where !settings.keepAwakeCommands:
                set(reason, nil)
            default: break
            }
        }
    }

    // MARK: The assertion

    private var lastSeen: [Reason: Date] = [:]

    private func set(_ reason: Reason, _ label: String?) {
        let wasOn = !reasons.isEmpty
        let before = reasons[reason]?.label
        if let label {
            reasons[reason] = (label, reasons[reason]?.since ?? Date())
            lastSeen[reason] = Date()               // Claude refreshes this on every tool call
        } else {
            reasons[reason] = nil
            lastSeen[reason] = nil
        }
        if wasOn != !reasons.isEmpty { update() }
        if before != label { publish() }
    }

    private func update() {
        let why = summary
        if !reasons.isEmpty, assertion == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Notch: \(why ?? "keeping awake")" as CFString, &id)
            if result == kIOReturnSuccess {
                assertion = id
                log("keep awake: on (\(why ?? ""))")
            } else {
                log("keep awake: couldn't hold the Mac awake (\(result))")
            }
        } else if reasons.isEmpty, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
            log("keep awake: off, the Mac can sleep again")
        }
    }

    private var summary: String? {
        if let manual = reasons[.manual] { return manual.label }
        let labels = reasons.values.sorted { $0.since < $1.since }.map(\.label)
        guard let first = labels.first else { return nil }
        return labels.count == 1 ? first : "\(first) + \(labels.count - 1) more"
    }

    private func publish() {
        // Keep the name macOS shows (pmset -g assertions) in step with the reason.
        if assertion != 0, let why = summary {
            IOPMAssertionSetProperty(assertion, kIOPMAssertionNameKey as CFString, "Notch: \(why)" as CFString)
        }
        state = AwakeState(on: !reasons.isEmpty, manual: manual, why: summary)
        onChange?(state)
    }

    private func dropStale() {
        let now = Date()
        for (reason, seen) in lastSeen {
            switch reason {
            case .claude where now.timeIntervalSince(seen) > 3600, .command where now.timeIntervalSince(seen) > 12 * 3600:
                set(reason, nil)
            default: break
            }
        }
    }
}

/// What the island shows about keeping awake.
struct AwakeState: Equatable {
    var on = false
    var manual = false
    var why: String?
}
