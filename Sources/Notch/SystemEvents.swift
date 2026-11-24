import CoreAudio
import Foundation
import IOKit.ps

/// Brief banners for things the Mac itself does: plugging in power, running low on
/// battery, and headphones becoming the sound output (with their battery, when macOS
/// knows it). Public IOKit and CoreAudio APIs plus `system_profiler`; no permissions needed.
@MainActor final class SystemEvents {
    var onBanner: ((Banner) -> Void)?
    /// Fills late details (headphone battery) into a banner already shown: id, subtitle, accessory.
    var onBannerUpdate: ((UUID, String?, Banner.Accessory) -> Void)?

    private struct Power: Equatable {
        var onAC: Bool
        var level: Int
    }

    private var power: Power?
    private var output = AudioDeviceID(0)
    private var powerSource: CFRunLoopSource?

    func start() {
        power = Self.readPower()
        output = Self.defaultOutputDevice()
        log("power: " + (power.map { "\($0.level)% \($0.onAC ? "on power adapter" : "on battery")" } ?? "no battery")
            + ", sound output: \(Self.name(of: output))")

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let events = Unmanaged<SystemEvents>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { events.powerChanged() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }

        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
    }

    // MARK: Power

    private func powerChanged() {
        guard let now = Self.readPower() else { return }
        let before = power
        power = now
        guard let before, SettingsStore.shared.value.battery else { return }
        if !before.onAC && now.onAC {
            onBanner?(Banner(symbol: "bolt.fill", tint: .green, title: "Charging",
                             subtitle: now.level >= 100 ? "Fully charged" : nil,
                             accessory: .battery(level: now.level, charging: true), duration: 3))
        } else if !now.onAC, let threshold = [20, 10, 5].first(where: { before.level > $0 && now.level <= $0 }) {
            onBanner?(Banner(symbol: threshold <= 10 ? "battery.0percent" : "battery.25percent", tint: .red,
                             title: "Low Battery", subtitle: "\(now.level)% remaining",
                             accessory: .battery(level: now.level, charging: false), duration: 4))
        }
    }

    private nonisolated static func readPower() -> Power? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(description[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            return Power(onAC: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                         level: Int((Double(current) / Double(maximum) * 100).rounded()))
        }
        return nil
    }

    // MARK: Headphones

    private func outputChanged() {
        let device = Self.defaultOutputDevice()
        guard device != output else { return }
        output = device
        let name = Self.name(of: device)
        let transport = Self.transport(of: device)
        let bluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        let wired = name.localizedCaseInsensitiveContains("headphone")
        log("audio output: \(name)\(bluetooth ? " (Bluetooth)" : "")")
        guard bluetooth || wired, SettingsStore.shared.value.headphones else { return }
        let banner = Banner(symbol: Self.symbol(forHeadphones: name), title: name, subtitle: "Connected", duration: 4)
        onBanner?(banner)
        if bluetooth { readBattery(of: device, named: name, banner: banner.id) }   // wired ones have none
    }

    /// Seconds to wait before each look at the battery: macOS often learns the level a
    /// moment after the headphones connect.
    private static let batteryRetries: [TimeInterval] = [0, 1, 2]

    /// Looks the level up (off the main thread) and fills it into the banner, which then
    /// grows a ring. Gives up quietly if macOS doesn't know it.
    private func readBattery(of device: AudioDeviceID, named name: String, banner: UUID, attempt: Int = 0) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let battery = Self.headphoneBattery(named: name)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.output == device else { return }    // switched away meanwhile
                    if let battery, let level = battery.level {
                        log("headphone battery: \(name) \(level)% (\(battery.detail))")
                        self.onBannerUpdate?(banner, battery.detail, .battery(level: level, charging: false))
                    } else if attempt + 1 < Self.batteryRetries.count {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Self.batteryRetries[attempt + 1]) { [weak self] in
                            MainActor.assumeIsolated {
                                self?.readBattery(of: device, named: name, banner: banner, attempt: attempt + 1)
                            }
                        }
                    } else {
                        log("headphone battery: macOS doesn't report it for \(name)")
                    }
                }
            }
        }
    }

    nonisolated static func symbol(forHeadphones name: String) -> String {
        let name = name.lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") { return "beats.headphones" }
        if name.contains("buds") { return "earbuds" }
        if name.contains("speaker") { return "hifispeaker.fill" }
        return "headphones"
    }

    // MARK: Headphone battery

    /// What macOS knows about a Bluetooth audio device's battery. AirPods and Beats report
    /// each earbud and the case; other headphones a single level, if they share it at all.
    struct HeadphoneBattery: Equatable, Sendable {
        var left: Int?
        var right: Int?
        var caseLevel: Int?
        var main: Int?

        /// The ring: the emptier earbud, or the single level.
        var level: Int? { [left, right].compactMap { $0 }.min() ?? main }

        /// The line under the name, e.g. "L 80% · R 75% · Case 40%".
        var detail: String {
            var parts: [String] = []
            switch (left, right) {
            case let (left?, right?) where left != right: parts = ["L \(left)%", "R \(right)%"]
            case let (left?, nil): parts = ["L \(left)%"]          // one earbud in use
            case let (nil, right?): parts = ["R \(right)%"]
            default: parts = ["Connected"]                         // both the same: the ring says it
            }
            if let caseLevel { parts.append("Case \(caseLevel)%") }
            return parts.joined(separator: " · ")
        }
    }

    /// Asks `system_profiler`, Apple's own system report tool (the same data as System
    /// Information › Bluetooth). Read-only and needs no permission. Takes about a quarter second.
    nonisolated static func headphoneBattery(named name: String) -> HeadphoneBattery? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return parseBattery(data, named: name)
    }

    /// Finds the connected device by name in `system_profiler SPBluetoothDataType -json`.
    nonisolated static func parseBattery(_ data: Data, named name: String) -> HeadphoneBattery? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        var found: [(name: String, kind: String, battery: HeadphoneBattery)] = []
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (deviceName, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    var battery = HeadphoneBattery()
                    for (key, raw) in info where key.hasPrefix("device_batteryLevel") {
                        let text = (raw as? String) ?? (raw as? NSNumber)?.stringValue ?? ""
                        guard let percent = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) else { continue }
                        switch key {
                        case "device_batteryLevelLeft": battery.left = percent
                        case "device_batteryLevelRight": battery.right = percent
                        case "device_batteryLevelCase": battery.caseLevel = percent
                        default: battery.main = percent
                        }
                    }
                    guard battery.level != nil else { continue }
                    found.append((deviceName, (info["device_minorType"] as? String ?? "").lowercased(), battery))
                }
            }
        }
        // CoreAudio and Bluetooth agree on the name, give or take a curly apostrophe.
        func plain(_ text: String) -> String { text.lowercased().replacingOccurrences(of: "’", with: "'") }
        let wanted = plain(name)
        if let match = found.first(where: { plain($0.name) == wanted })
            ?? found.first(where: { wanted.contains(plain($0.name)) || plain($0.name).contains(wanted) }) {
            return match.battery
        }
        // Names differ but there's only one audio device with a battery: that's the one.
        // (Never a mouse or keyboard.)
        let audio = found.filter { $0.kind.contains("head") || $0.kind.contains("speaker") }
        return audio.count == 1 ? audio[0].battery : nil
    }

    private nonisolated static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    nonisolated static func defaultOutputDevice() -> AudioDeviceID {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    nonisolated static func name(of device: AudioDeviceID) -> String {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = address(kAudioObjectPropertyName)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let name else { return "Headphones" }
        return name.takeRetainedValue() as String
    }

    nonisolated static func transport(of device: AudioDeviceID) -> UInt32 {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address(kAudioDevicePropertyTransportType)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return transport
    }
}
