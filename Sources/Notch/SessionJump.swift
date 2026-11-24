import AppKit
import Darwin

/// Where a Claude Code session lives, worked out from the processes above its hook:
/// the nearest real app (Claude, Warp, VS Code, Terminal…) and, in a terminal, its tab's device.
struct SessionHost: Equatable {
    var appPID: pid_t
    var bundleID: String
    var name: String
    var tty: String?          // "/dev/ttys003" when Claude Code runs in a terminal tab
    var folder: String?       // the session's working folder
    var appSession: String?   // the Claude app's own ID for the session ("local_…"), when it started it

    static let editors = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
                          "com.google.antigravity-ide", "com.vscodium"]

    /// The nearest app above the hook, nearest process first.
    @MainActor static func resolve(ancestors: [Int], folder: String?, appSession: String? = nil) -> SessionHost? {
        var tty: String?
        for pid in ancestors.map({ pid_t($0) }) {
            if tty == nil { tty = terminal(of: pid) }
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
               let id = app.bundleIdentifier {
                return SessionHost(appPID: pid, bundleID: id, name: name(of: app), tty: tty, folder: folder, appSession: appSession)
            }
        }
        return nil
    }

    static func name(of app: NSRunningApplication) -> String {
        switch app.bundleIdentifier {
        case "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders": "VS Code"
        case "com.googlecode.iterm2": "iTerm"
        case "com.google.antigravity-ide": "Antigravity"
        default: app.localizedName ?? "the app"
        }
    }

    /// The terminal device a process is attached to, if any.
    static func terminal(of pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.e_tdev != UInt32.max, info.e_tdev != 0,
              let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
        let device = String(cString: name)
        return device.hasPrefix("tty") ? "/dev/" + device : nil
    }
}

/// Brings a session's app forward, as close to the session as the app allows:
/// Claude opens the session itself (its claude://code/continue link, with the app's own
/// session ID); Terminal and iTerm select the exact tab; VS Code, Cursor and Antigravity
/// focus the window with the project; Warp comes to the front.
enum SessionJump {
    @MainActor static func open(_ host: SessionHost) {
        let app = NSRunningApplication(processIdentifier: host.appPID)
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: host.bundleID).first
        guard let bundleURL = app?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: host.bundleID) else {
            return log("claude: couldn't find \(host.name) to open")
        }
        switch host.bundleID {
        case claudeApp where host.appSession != nil:
            if let link = continueLink(host.appSession!), NSWorkspace.shared.open(link) {
                log("claude: opened the session in Claude (\(host.appSession!))")
                return
            }
            bringForward(bundleURL)
        case "com.apple.Terminal" where host.tty != nil:
            script(terminalTab(host.tty!), fallback: bundleURL)
        case "com.googlecode.iterm2" where host.tty != nil:
            script(itermSession(host.tty!), fallback: bundleURL)
        case _ where SessionHost.editors.contains(host.bundleID) && host.folder != nil:
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([URL(fileURLWithPath: host.folder!)], withApplicationAt: bundleURL, configuration: configuration)
        default:
            bringForward(bundleURL)
        }
        log("claude: opened the session in \(host.name)" + (host.tty.map { " (\($0))" } ?? ""))
    }

    static let claudeApp = "com.anthropic.claudefordesktop"

    /// The Claude app's link to one Code session (it takes only its own "local_…" IDs).
    static func continueLink(_ appSession: String) -> URL? {
        guard appSession.range(of: #"^local_[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "claude://code/continue?session=\(appSession)")
    }

    /// Through Launch Services, which may bring another app forward even though Notch isn't
    /// the active app (a plain activate() is refused for background apps on recent macOS).
    @MainActor static func bringForward(_ bundleURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
    }

    private static func script(_ source: String, fallback: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            process.standardError = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                DispatchQueue.main.async { MainActor.assumeIsolated { bringForward(fallback) } }
            }
        }
    }

    static func terminalTab(_ tty: String) -> String {
        """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(tty)" then
                set selected tab of w to t
                set index of w to 1
              end if
            end repeat
          end repeat
          activate
        end tell
        """
    }

    static func itermSession(_ tty: String) -> String {
        """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(tty)" then
                  select w
                  select t
                  select s
                end if
              end repeat
            end repeat
          end repeat
          activate
        end tell
        """
    }
}
