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
}

/// Finds newer releases on GitHub and installs them: download, check GitHub's SHA-256, unzip,
/// check the app (bundle ID, version, signature and signing identity), then a small helper
/// swaps it in once Notch has quit and starts the new one. Anything wrong: nothing replaced.
/// The repo is public, so no sign-in: GitHub's API over HTTPS, about four times a day.
@MainActor final class Updater: ObservableObject {
    static let shared = Updater()

    @Published private(set) var phase: UpdatePhase = .idle
    @Published private(set) var lastChecked: Date?

    /// A newer version, the first time it's seen (a banner).
    var onFound: ((NotchRelease) -> Void)?
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

    nonisolated static let bundleID = "dev.notch.Notch"
    nonisolated static let repo = Bundle.main.infoDictionary?["NotchUpdateRepo"] as? String ?? "devaduttmohan/notch"
    static var every: TimeInterval = 6 * 3600

    private var timer: Timer?
    private var etag: String?
    private var lastRelease: NotchRelease?
    private var quietFailures = 0

    init() {
        let env = ProcessInfo.processInfo.environment["NOTCH_UPDATE_API"].flatMap(URL.init(string:))
        apiURL = env ?? URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
    }

    /// Why this copy can't update itself, if it can't.
    var blocker: String? {
        guard currentVersion != nil, appPath.hasSuffix(".app") else {
            return "Updates are for the installed app; this is a development build."
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
    func start() {
        try? FileManager.default.removeItem(at: cacheFolder)
        if let blocker { phase = .unavailable(blocker); return }
        scheduleChecks()
    }

    func scheduleChecks() {
        timer?.invalidate()
        timer = nil
        guard SettingsStore.shared.value.checkForUpdates, blocker == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer?.tolerance = 600
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

    func check(manual: Bool = false) {
        if let blocker { phase = .unavailable(blocker); return }
        switch phase {
        case .downloading, .installing, .checking: return
        default: break
        }
        guard manual || !isAway() else { return }
        let shown = phase
        if manual || phase == .idle { phase = .checking }
        var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Notch/\(currentVersion ?? "dev") (updater)", forHTTPHeaderField: "User-Agent")
        if let etag, lastRelease != nil { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        Task {
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
                return checkFailed(error, manual: manual, shown: shown)
            }
            quietFailures = 0
            let first = lastChecked == nil
            lastChecked = Date()
            guard let current = currentVersion, Self.isNewer(release.version, than: current) else {
                phase = .upToDate
                if manual || first { log("update: up to date (\(currentVersion ?? "?"); latest is \(release.version))") }
                return
            }
            phase = .available(release)
            if SettingsStore.shared.value.updateAnnounced != release.version {
                SettingsStore.shared.value.updateAnnounced = release.version
                log("update: Notch \(release.version) is available (this is \(current))")
                onFound?(release)
            }
        }
    }

    private func checkFailed(_ error: Error, manual: Bool, shown: UpdatePhase) {
        let message = (error as? UpdateError)?.message ?? "Couldn't reach GitHub. Check your connection."
        if manual {
            phase = .failed(message, nil)
        } else {
            phase = shown == .checking ? .idle : shown          // a background look keeps what's shown
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
        process.arguments = [script.path, String(waitForPID), appPath, app.path, relaunchTool, logPath, release.version]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw UpdateError.install("Couldn't start the installer.") }
    }

    nonisolated static let swapScript = """
    #!/bin/sh
    # Notch's updater: waits for Notch to quit, puts the new app in place and starts it.
    pid="$1"; dest="$2"; new="$3"; relaunch="$4"; logfile="$5"; version="$6"
    say() { printf '%s Notch: update: %s\\n' "$(date +%H:%M:%S.00)" "$1" >> "$logfile"; }
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
    if kill -0 "$pid" 2>/dev/null; then say "Notch didn't quit; left $version for later"; exit 1; fi
    old="$dest.replaced"
    rm -rf "$old"
    if ! mv "$dest" "$old"; then say "couldn't move the old app aside; kept it"; "$relaunch" "$dest"; exit 1; fi
    if ! mv "$new" "$dest"; then mv "$old" "$dest"; say "couldn't put $version in place; kept the old app"; "$relaunch" "$dest"; exit 1; fi
    xattr -dr com.apple.quarantine "$dest" 2>/dev/null
    rm -rf "$old"
    say "installed $version at $dest"
    "$relaunch" "$dest"
    """

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
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
