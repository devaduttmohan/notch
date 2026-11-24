import AppKit
import CryptoKit

/// A release of Notch on GitHub (the public repo named in Info.plist's NotchUpdateRepo).
struct NotchRelease: Equatable, Sendable {
    var version: String            // "0.7.2"
    var tag: String                // "v0.7.2"
    var name: String
    var notes: String              // the release notes (Markdown)
    var page: URL
    var asset: URL                 // Notch-0.7.2.zip
    var assetName: String
    var size: Int
    var sha256: String?            // GitHub's checksum for the zip, hex
    var published: Date?

    /// The lines a reader would skim: the bold leads of the notes, plain.
    var highlights: [String] {
        let lines = notes.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let bold = lines.compactMap { line -> String? in
            guard line.hasPrefix("**"), let end = line.dropFirst(2).range(of: "**") else { return nil }
            return Self.plain(String(line.dropFirst(2)[..<end.lowerBound]))
        }
        if !bold.isEmpty { return Array(bold.prefix(3)) }
        return Array(lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }.prefix(2).map(Self.plain))
    }

    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-•*"))
    }
}

enum UpdatePhase: Equatable {
    case unavailable(String)       // a development build, or somewhere Notch can't replace itself
    case idle                      // not checked yet
    case checking
    case upToDate
    case available(NotchRelease)
    case downloading(NotchRelease, Double)
    case installing(NotchRelease)
    case failed(String, NotchRelease?)
    case installFailed(String, String)   // version, why: the helper's report, read after the restart
}

/// Finds newer releases on GitHub and installs them: download, check GitHub's SHA-256, unzip,
/// check the app (bundle ID, version, signature and signing identity), then a small helper
/// swaps it in once Notch has quit and starts the new one. Anything wrong: nothing replaced.
/// The repo is public, so no sign-in: GitHub's API over HTTPS, about four times a day.
@MainActor final class Updater: ObservableObject {
    static let shared = Updater()

    @Published private(set) var phase: UpdatePhase = .idle
    @Published private(set) var lastChecked: Date?
    /// The latest release GitHub reported (for "what's new" right after updating).
    @Published private(set) var latest: NotchRelease?
    /// The version this one replaced, when this launch is the first after an update.
    @Published private(set) var updatedFrom: String?

    /// A newer version, the first time it's seen (a banner).
    var onFound: ((NotchRelease) -> Void)?
    /// After a restart: the update didn't go in (version, why).
    var onInstallFailed: ((String, String) -> Void)?
    var isAway: () -> Bool = { false }
    var quit: () -> Void = { NSApp.terminate(nil) }

    // Where things are. Tests point these somewhere harmless.
    var apiURL: URL
    var appPath = Bundle.main.bundlePath
    var currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    var cacheFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dev.notch.Notch/Updates")
    var relaunchTool = "/usr/bin/open"
    var waitForPID = ProcessInfo.processInfo.processIdentifier
    var logPath = LogFile.url.path
    /// Bookkeeping that isn't a setting (so Reset all settings leaves it): the version a banner
    /// announced, and the version that ran last.
    var defaults = UserDefaults.standard
    /// The helper's report when a swap fails, read at the next launch (next to the cache, which
    /// launch clears).
    var resultFile: URL { cacheFolder.deletingLastPathComponent().appendingPathComponent("update-result") }
    /// Notch should be gone this long after it hands over; still here means it didn't quit.
    static var restartTimeout: TimeInterval = 40

    nonisolated static let bundleID = "dev.notch.Notch"
    nonisolated static let repo = Bundle.main.infoDictionary?["NotchUpdateRepo"] as? String ?? "devaduttmohan/notch"
    static var every: TimeInterval = 6 * 3600

    private var timer: Timer?
    private var firstTimer: Timer?
    private var etag: String?
    private var lastRelease: NotchRelease?
    private var quietFailures = 0
    private var checking = false            // a look is out (the phase may not say so)
    private var manualWaiting = false       // Check now was pressed while it was out

    init() {
        let env = ProcessInfo.processInfo.environment["NOTCH_UPDATE_API"].flatMap(URL.init(string:))
        apiURL = env ?? URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")
            ?? URL(string: "https://api.github.com/repos/devaduttmohan/notch/releases/latest")!
    }

    /// Why this copy can't update itself, if it can't.
    var blocker: String? {
        guard currentVersion != nil, appPath.hasSuffix(".app") else {
            return "Updates are for the installed app; this is a development build."
        }
        // bin/notch builds into <checkout>/build/Notch.app: that one stays as built.
        let checkout = ((appPath as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        if FileManager.default.fileExists(atPath: checkout + "/Package.swift") {
            return "This copy was built from source (in build/), so it doesn't update itself."
        }
        if appPath.contains("/AppTranslocation/") {
            return "macOS is running Notch from a temporary copy. Move Notch.app with Finder (into Applications) to get updates."
        }
        // Privacy-protected folders: the swap runs after Notch has quit and may not keep its access.
        let home = NSHomeDirectory()
        for folder in ["Downloads", "Desktop", "Documents"] where appPath.hasPrefix("\(home)/\(folder)/") {
            return "Notch is in your \(folder) folder. Move it to Applications to get updates."
        }
        let folder = (appPath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: folder) else {
            return "Notch can't replace itself in \(folder). Move it to Applications."
        }
        return nil
    }

    var hasUpdate: Bool {
        if case .available = phase { return true }
        if case .failed(_, let release) = phase { return release != nil }
        return false
    }

    var available: NotchRelease? {
        switch phase {
        case .available(let release), .downloading(let release, _), .installing(let release): release
        case .failed(_, let release): release
        default: nil
        }
    }

    /// At launch: clear what an earlier update left, then look in a moment and every 6 hours.
    /// A copy that can't update itself (a development build) leaves the cache alone: it may
    /// be the installed app's download in progress.
    func start() {
        if let blocker { phase = .unavailable(blocker); return }
        if let report = try? String(contentsOf: resultFile, encoding: .utf8) {
            try? FileManager.default.removeItem(at: resultFile)
            let parts = report.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2).map(String.init)
            if parts.count == 3, parts[0] == "failed", let current = currentVersion, Self.isNewer(parts[1], than: current) {
                phase = .installFailed(parts[1], parts[2])
                log("update: \(parts[1]) wasn't installed (\(parts[2]))")
                onInstallFailed?(parts[1], parts[2])
            }
        }
        try? FileManager.default.removeItem(at: cacheFolder)
        scheduleChecks()
        // An earlier swap that half-failed can leave copies next to the app. This one is running,
        // so they're spare; a minute on, the helper has certainly finished with them.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.leftoverDelay) { [weak self] in
            MainActor.assumeIsolated { self?.clearLeftovers() }
        }
    }

    static var leftoverDelay: TimeInterval = 60

    private func clearLeftovers() {
        guard blocker == nil else { return }
        for suffix in [".replaced", ".failed", ".incoming"] where FileManager.default.fileExists(atPath: appPath + suffix) {
            do { try FileManager.default.removeItem(atPath: appPath + suffix); log("update: removed a leftover \((appPath as NSString).lastPathComponent)\(suffix)") }
            catch { log("update: couldn't remove a leftover \(appPath)\(suffix) (\(error.localizedDescription))") }
        }
    }

    /// At launch: the version that ran before, if this is a newer one (an "Updated to" banner).
    /// Kept in UserDefaults; read once from older settings files that kept it there.
    func noteLaunch() -> String? {
        guard let current = currentVersion, blocker == nil else { return nil }     // only the installed copy keeps this
        let before = defaults.string(forKey: "lastRunVersion") ?? Self.legacySetting("lastRunVersion")
        defaults.set(current, forKey: "lastRunVersion")
        guard let before, !before.isEmpty, Self.isNewer(current, than: before) else { return nil }
        updatedFrom = before
        return before
    }

    private var announced: String {
        get { defaults.string(forKey: "updateAnnounced") ?? Self.legacySetting("updateAnnounced") ?? "" }
        set { defaults.set(newValue, forKey: "updateAnnounced") }
    }

    /// A value 0.7.2 kept in settings.json (moved to UserDefaults since).
    private static func legacySetting(_ key: String) -> String? {
        guard let data = try? Data(contentsOf: SettingsStore.fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object[key] as? String
    }

    /// The first look comes this long after launch.
    static var firstCheck: TimeInterval = 20

    /// (Re)plans the automatic looks; turning Check automatically off cancels them, the first
    /// one included.
    func scheduleChecks() {
        firstTimer?.invalidate()
        timer?.invalidate()
        firstTimer = nil
        timer = nil
        guard SettingsStore.shared.value.checkForUpdates, blocker == nil else { return }
        firstTimer = Timer.scheduledTimer(withTimeInterval: Self.firstCheck, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.automaticCheck() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.automaticCheck() }
        }
        timer?.tolerance = 600
    }

    private func automaticCheck() {
        guard SettingsStore.shared.value.checkForUpdates else { return }
        check()
    }

    /// Opening the About page: look again if the last look is over 10 minutes old.
    func checkIfStale() {
        guard SettingsStore.shared.value.checkForUpdates else { return }
        if lastChecked.map({ Date().timeIntervalSince($0) > 600 }) ?? true { check() }
    }

    /// Shows a state without doing anything (the customiser's renders and tests).
    func preview(_ phase: UpdatePhase, checked: Date? = nil) {
        self.phase = phase
        lastChecked = checked
    }

    // MARK: Checking

    /// The failure shown is about this version (keep it; a newer release replaces it).
    private func failed(_ version: String) -> Bool {
        switch phase {
        case .failed(_, let release?): release.version == version
        case .installFailed(let failedVersion, _): failedVersion == version
        default: false
        }
    }

    /// Downloading or installing: nothing else may change the phase.
    private var installing: Bool {
        switch phase {
        case .downloading, .installing: true
        default: false
        }
    }

    func check(manual: Bool = false) {
        if let blocker { phase = .unavailable(blocker); return }
        if installing { return }
        if checking {                                   // a look is already out: its answer will do
            if manual { manualWaiting = true; phase = .checking }
            return
        }
        guard manual || !isAway() else { return }
        let shown = phase
        if manual || phase == .idle { phase = .checking }
        var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Notch/\(currentVersion ?? "dev") (updater)", forHTTPHeaderField: "User-Agent")
        if let etag, lastRelease != nil { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        checking = true
        manualWaiting = manual
        Task {
            defer { checking = false; manualWaiting = false }
            let release: NotchRelease
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch status {
                case 304 where lastRelease != nil:
                    release = lastRelease!
                case 200:
                    guard let parsed = Self.parse(data) else { throw UpdateError.check("GitHub's answer didn't have a Notch download.") }
                    release = parsed
                    lastRelease = parsed
                    etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Etag")
                case 403, 429: throw UpdateError.check("GitHub is limiting checks right now. Try again later.")
                case 404: throw UpdateError.check("No releases found for \(Self.repo).")
                default: throw UpdateError.check("GitHub answered \(status).")
                }
            } catch {
                return checkFailed(error, manual: manual || manualWaiting, shown: shown)
            }
            let manual = manual || manualWaiting
            quietFailures = 0
            let first = lastChecked == nil
            lastChecked = Date()
            latest = release
            // Update was clicked while this look was out: leave the download alone. A failed
            // install keeps its message unless you asked.
            if installing { return }
            if !manual, failed(release.version) { return }
            guard let current = currentVersion, Self.isNewer(release.version, than: current) else {
                phase = .upToDate
                if manual || first { log("update: up to date (\(currentVersion ?? "?"); latest is \(release.version))") }
                return
            }
            phase = .available(release)
            if announced != release.version {
                announced = release.version
                log("update: Notch \(release.version) is available (this is \(current))")
                onFound?(release)
            }
        }
    }

    private func checkFailed(_ error: Error, manual: Bool, shown: UpdatePhase) {
        let message = (error as? UpdateError)?.message ?? "Couldn't reach GitHub. Check your connection."
        if installing { return }
        if manual {
            phase = .failed(message, nil)
        } else {
            if phase == .checking { phase = shown == .checking ? .idle : shown }   // only undo its own spinner
            quietFailures += 1
        }
        if manual || quietFailures == 1 { log("update: couldn't check (\(message))") }
    }

    /// GitHub's latest release: the Notch-x.y.z.zip asset, its checksum, and the notes.
    nonisolated static func parse(_ data: Data) -> NotchRelease? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["draft"] as? Bool != true, root["prerelease"] as? Bool != true,
              let tag = root["tag_name"] as? String,
              let page = (root["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = root["assets"] as? [[String: Any]],
              let asset = assets.first(where: {
                  ($0["name"] as? String)?.range(of: #"^Notch-\d+(\.\d+)*\.zip$"#, options: .regularExpression) != nil
              }),
              let name = asset["name"] as? String,
              let link = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
              link.scheme == "https" || link.host == "127.0.0.1"
        else { return nil }
        let digest = (asset["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
        return NotchRelease(version: String(tag.drop { !$0.isNumber }), tag: tag, name: root["name"] as? String ?? tag,
                            notes: root["body"] as? String ?? "", page: page, asset: link, assetName: name,
                            size: asset["size"] as? Int ?? 0, sha256: digest,
                            published: ISO8601DateFormatter().date(from: root["published_at"] as? String ?? ""))
    }

    /// "0.7.10" is newer than "0.7.9"; "v" and anything after the numbers are ignored.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.drop { !$0.isNumber }.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for index in 0..<max(x.count, y.count) {
            let p = index < x.count ? x[index] : 0, q = index < y.count ? y[index] : 0
            if p != q { return p > q }
        }
        return false
    }

    // MARK: Installing

    /// Update: download (with progress), check, unpack, check the app, swap it in, restart.
    func install() {
        guard let release = available, blocker == nil else { return }
        switch phase {
        case .downloading, .installing: return
        default: break
        }
        // Notch has to be able to write next to itself (a privacy-protected folder, an external
        // or iCloud volume may refuse): find out now, while it's running, not after it quits.
        // The helper needs these names free: an earlier update's leftovers go now, or we say which.
        for suffix in [".incoming", ".replaced", ".failed"] where FileManager.default.fileExists(atPath: appPath + suffix) {
            do { try FileManager.default.removeItem(atPath: appPath + suffix) } catch {
                phase = .failed("An earlier update left \(appPath + suffix), and it can't be removed. Remove it, then try again.", release)
                log("update: can't remove the leftover \(appPath + suffix) (\(error.localizedDescription))")
                return
            }
        }
        let probe = appPath + ".incoming"
        do {
            try FileManager.default.createDirectory(atPath: probe, withIntermediateDirectories: false)
            try FileManager.default.removeItem(atPath: probe)
        } catch {
            let folder = (appPath as NSString).deletingLastPathComponent
            phase = .failed("Notch can't write in \(folder), so it can't replace itself there. Move it to Applications to get updates.", release)
            log("update: can't write next to the app in \(folder) (\(error.localizedDescription))")
            return
        }
        phase = .downloading(release, 0)
        log("update: downloading Notch \(release.version)")
        let folder = cacheFolder.appendingPathComponent(release.version)
        Task {
            do {
                guard let expected = release.sha256 else {
                    throw UpdateError.install("GitHub gave no checksum for this download, so Notch won't install it. Download it from the release page.")
                }
                try? FileManager.default.removeItem(at: folder)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let zip = try await download(release, to: folder.appendingPathComponent(release.assetName))
                phase = .installing(release)
                let app = try await Task.detached { () throws -> URL in
                    try Self.verify(zip, sha256: expected)
                    return try Self.unpack(zip, into: folder, version: release.version)
                }.value
                try handOver(app, from: folder, release: release)
                log("update: Notch \(release.version) checked; quitting so it can be put in place")
                quit()
                // Still here a while later: Notch didn't quit, so the helper gave up. Say so
                // rather than showing Installing… for ever.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.restartTimeout) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, case .installing(let shown) = self.phase, shown == release else { return }
                        try? FileManager.default.removeItem(at: self.resultFile)
                        self.phase = .failed("Notch didn't restart, so the update wasn't put in place. Try again.", release)
                        log("update: still running \(Self.restartTimeout) s after handing over \(release.version)")
                    }
                }
            } catch {
                let message = (error as? UpdateError)?.message ?? "The download didn't finish. Check your connection and try again."
                phase = .failed(message, release)
                log("update: couldn't install \(release.version) (\(message))")
            }
        }
    }

    private func download(_ release: NotchRelease, to file: URL) async throws -> URL {
        let delegate = DownloadDelegate(destination: file) { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .downloading(let shown, let last) = self.phase, fraction - last >= 0.02 || fraction >= 1 else { return }
                self.phase = .downloading(shown, fraction)
            }
        }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            var request = URLRequest(url: release.asset, timeoutInterval: 60)
            request.setValue("Notch/\(currentVersion ?? "dev") (updater)", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: request).resume()
        }
    }

    /// The zip is exactly what GitHub says it published.
    nonisolated static func verify(_ zip: URL, sha256 expected: String) throws {
        guard let data = try? Data(contentsOf: zip) else { throw UpdateError.install("The download is missing.") }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else {
            throw UpdateError.install("The download doesn't match GitHub's checksum, so it wasn't installed.")
        }
    }

    /// Unzips it and checks the app: Notch's bundle ID, the release's version, a valid
    /// signature, and the same signing identity as every Notch build.
    nonisolated static func unpack(_ zip: URL, into folder: URL, version: String) throws -> URL {
        let out = folder.appendingPathComponent("unpacked")
        try? FileManager.default.removeItem(at: out)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path]).status == 0 else {
            throw UpdateError.install("Couldn't unzip the download.")
        }
        let app = out.appendingPathComponent("Notch.app")
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == bundleID else {
            throw UpdateError.install("The download isn't Notch (wrong bundle ID), so it wasn't installed.")
        }
        guard info?["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError.install("The download says it's a different version than the release, so it wasn't installed.")
        }
        // It has to run on this Mac, or there'd be no Notch left to put things right.
        if let minimum = info?["LSMinimumSystemVersion"] as? String {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let here = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            if isNewer(minimum, than: here) {
                throw UpdateError.install("Notch \(version) needs macOS \(minimum) or later; this Mac has \(here). Your current Notch stays.")
            }
        }
        let executable = info?["CFBundleExecutable"] as? String ?? "Notch"
        guard cpuTypes(of: app.appendingPathComponent("Contents/MacOS/\(executable)")).contains(hostCPU) else {
            throw UpdateError.install("Notch \(version) isn't built for this Mac's processor (\(hostArch)), so it wasn't installed.")
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).status == 0 else {
            throw UpdateError.install("The new app's signature doesn't check out, so it wasn't installed.")
        }
        let requirement = String(decoding: run("/usr/bin/codesign", ["-d", "-r-", app.path]).output, as: UTF8.self)
        guard requirement.contains("identifier \"\(bundleID)\"") else {
            throw UpdateError.install("The new app isn't signed as Notch, so it wasn't installed.")
        }
        try? FileManager.default.removeItem(at: zip)
        return app
    }

    /// The helper: waits for Notch to quit, moves the old app aside, puts the new one in its
    /// place, starts it and removes the old one; if the swap fails, the old app goes back.
    private func handOver(_ app: URL, from folder: URL, release: NotchRelease) throws {
        let script = folder.appendingPathComponent("swap.sh")
        try Self.swapScript.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        try? FileManager.default.removeItem(at: resultFile)
        process.arguments = [script.path, String(waitForPID), appPath, app.path, relaunchTool, logPath, release.version, resultFile.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw UpdateError.install("Couldn't start the installer.") }
    }

    nonisolated static let swapScript = """
    #!/bin/sh
    # Notch's updater: waits for Notch to quit, puts the new app in place, starts it, and keeps
    # the old app until the new one is running. A failure is written to $result for the next
    # launch to report.
    pid="$1"; dest="$2"; new="$3"; relaunch="$4"; logfile="$5"; version="$6"; result="$7"
    say() { printf '%s Notch: update: %s\\n' "$(date +%H:%M:%S.00)" "$1" >> "$logfile"; }
    failed() { say "$1"; printf 'failed %s %s\\n' "$version" "$2" > "$result"; }
    escape() { printf '%s' "$1" | sed 's/[][\\.*^$(){}+?|]/\\\\&/g'; }
    uid="$(id -u)"
    exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$new/Contents/Info.plist" 2>/dev/null || echo Notch)"
    # Notch itself at exactly this path (not notchctl), and only this user's.
    pattern="^$(escape "$dest")/Contents/MacOS/$(escape "$exe")( |\\$)"
    mine() { pgrep -U "$uid" -f "$pattern" 2>/dev/null; }
    # Wait (by the clock, 30 s) for this Notch to quit.
    deadline=$(( $(date +%s) + 30 ))
    while kill -0 "$pid" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then failed "Notch didn't quit, so $version wasn't installed" "Notch didn't quit in time."; exit 1; fi
    # Another copy running from this app: swapping its app from under it isn't safe.
    if [ -n "$(mine)" ]; then failed "another copy of Notch is running from $dest; $version wasn't installed" "Another copy of Notch was running; quit it and try again."; exit 1; fi
    staged="$dest.incoming"; old="$dest.replaced"
    rm -rf "$staged" "$old"
    # A name that's still there would make mv move into it, not to it.
    if [ -e "$staged" ] || [ -e "$old" ]; then
      failed "couldn't clear an earlier update's leftovers next to $dest; kept the old app" "Couldn't clear leftovers from an earlier update next to Notch."
      "$relaunch" "$dest"; exit 1
    fi
    # Copied next to the old app first, so the swap itself is two renames in one folder.
    if [ ! -d "$new" ] || ! ditto "$new" "$staged"; then
      rm -rf "$staged"; failed "couldn't copy $version next to the old app; kept the old app" "Couldn't copy the new app into place."
      "$relaunch" "$dest"; exit 1
    fi
    if ! mv "$dest" "$old"; then
      rm -rf "$staged"; failed "couldn't move the old app aside; kept it" "Couldn't move the old app aside."
      "$relaunch" "$dest"; exit 1
    fi
    if ! mv "$staged" "$dest"; then
      if mv "$old" "$dest"; then failed "couldn't put $version in place; kept the old app" "Couldn't put the new app in place."
      else failed "couldn't put $version in place, nor the old app back (it's at $old)" "The old app is at $old."; fi
      rm -rf "$staged"; "$relaunch" "$dest"; exit 1
    fi
    xattr -dr com.apple.quarantine "$dest" 2>/dev/null
    "$relaunch" "$dest"
    # Running means: it appeared (within 15 s), and is still up 3 s later (a crash at launch isn't a start).
    started=""; deadline=$(( $(date +%s) + 15 ))
    while [ -z "$started" ] && [ "$(date +%s)" -lt "$deadline" ]; do started="$(mine | tail -1)"; [ -n "$started" ] || sleep 0.1; done
    [ -n "$started" ] || started="$(mine | tail -1)"                # one last look at the deadline
    [ -n "$started" ] && sleep 3
    if [ -n "$started" ] && kill -0 "$started" 2>/dev/null; then
      rm -rf "$old"; rm -f "$result"; say "installed $version at $dest"; exit 0
    fi
    # The new app didn't start (or didn't stay up): stop any late starter and make sure it's gone,
    # then put the old app back. If that fails, the new one goes back, so something is in place.
    pkill -U "$uid" -f "$pattern" 2>/dev/null
    deadline=$(( $(date +%s) + 5 ))
    while [ -n "$(mine)" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 0.1; done
    if [ -n "$(mine)" ]; then pkill -9 -U "$uid" -f "$pattern" 2>/dev/null; sleep 1; fi
    aside="$dest.failed"; rm -rf "$aside"
    [ -e "$aside" ] && aside="$dest.failed.$$"                         # a stuck leftover: a fresh name
    if [ ! -e "$aside" ] && mv "$dest" "$aside"; then
      if mv "$old" "$dest"; then
        rm -rf "$aside"; failed "$version didn't start; put the old app back" "The new version didn't start, so the old one was put back."
      else
        mv "$aside" "$dest"; failed "$version didn't start, and the old app couldn't be put back (it's at $old)" "The old app is at $old."
      fi
    else
      failed "$version didn't start, and couldn't be moved aside (the old app is at $old)" "The old app is at $old."
    fi
    "$relaunch" "$dest"; exit 1
    """

    nonisolated static var hostCPU: Int32 {
        #if arch(arm64)
        0x0100_000C                     // CPU_TYPE_ARM64
        #else
        0x0100_0007                     // CPU_TYPE_X86_64
        #endif
    }

    /// The CPU types a Mach-O executable is built for, from its header (thin or universal),
    /// without lipo (which is only a stub without the developer tools). Not Mach-O: none.
    nonisolated static func cpuTypes(of executable: URL) -> Set<Int32> {
        guard let handle = try? FileHandle(forReadingFrom: executable),
              let head = try? handle.read(upToCount: 4096), head.count >= 8 else { return [] }
        try? handle.close()
        let bytes = [UInt8](head)
        func le32(_ at: Int) -> UInt32 { at + 4 <= bytes.count ? bytes[at..<at + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } : 0 }
        func be32(_ at: Int) -> UInt32 { at + 4 <= bytes.count ? bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) } : 0 }
        switch be32(0) {
        case 0xCFFA_EDFE, 0xCEFA_EDFE:                          // thin Mach-O (64/32-bit), little-endian on disk
            return [Int32(bitPattern: le32(4))]
        case 0xCAFE_BABE, 0xCAFE_BABF:                          // universal (fat / fat64), big-endian
            let count = Int(min(be32(4), 32))
            let stride = be32(0) == 0xCAFE_BABF ? 32 : 20
            return Set((0..<count).map { Int32(bitPattern: be32(8 + $0 * stride)) }.filter { $0 != 0 })
        default:
            return []
        }
    }

    nonisolated static var hostArch: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    nonisolated static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, Data()) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}

enum UpdateError: Error {
    case check(String)
    case install(String)
    var message: String {
        switch self {
        case .check(let text), .install(let text): text
        }
    }
}

/// Download progress for the updater, and the file once it's down.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<URL, Error>?

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite total: Int64) {
        if total > 0 { progress(Double(written) / Double(total)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            guard status == 200 else { throw UpdateError.install("GitHub answered \(status) for the download.") }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            progress(1)
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Normally the file arrived first (and this is a no-op); otherwise this ends the wait.
        continuation?.resume(throwing: error ?? UpdateError.install("The download stopped before it finished."))
        continuation = nil
    }
}
