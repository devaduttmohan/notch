import AppKit
import Security

// MARK: - Model

/// One Jenkins build you started, as Notch sees it.
struct JenkinsBuild: Equatable, Identifiable {
    struct Stage: Equatable {
        var name: String
        var status: String           // SUCCESS, IN_PROGRESS, FAILED, UNSTABLE, ABORTED, NOT_EXECUTED, PAUSED_PENDING_INPUT
        var duration: TimeInterval
        var start: Date? = nil       // when Jenkins started it (for the time in the running stage)

        var running: Bool { status == "IN_PROGRESS" || status == "PAUSED_PENDING_INPUT" }
        var failed: Bool { status == "FAILED" || status == "ABORTED" }
    }

    var url: URL                     // …/job/Deploy/482/
    var job: String                  // "Folder » Deploy"
    var number: Int
    var building: Bool
    var result: String?              // SUCCESS, FAILURE, UNSTABLE, ABORTED, NOT_BUILT (nil while building)
    var started: Date
    var duration: TimeInterval       // once finished
    var estimated: TimeInterval      // Jenkins' guess from recent builds; 0 when it has none
    var cause: String?               // "Started by user Devadutt Mohan"
    var stages: [Stage] = []
    var queued = false               // waiting for an executor
    var finishedAt: Date?

    var id: String { url.absoluteString }
    /// The pipeline's own name, without its folders ("CodeAnalysis » Translator" → "Translator").
    var pipeline: String { job.components(separatedBy: " » ").last ?? job }
    var name: String { "\(pipeline) #\(number)" }
    var passed: Bool { result == "SUCCESS" }
    var failed: Bool { result == "FAILURE" || result == "ABORTED" || result == "UNSTABLE" }
    var consoleURL: URL { url.appendingPathComponent("console") }

    func elapsed(at now: Date) -> TimeInterval { building ? max(0, now.timeIntervalSince(started)) : duration }

    /// 0…1 from Jenkins' estimate; nil when it has none (a first run). Never shows 100%
    /// before it's actually done.
    func progress(at now: Date) -> Double? {
        guard !building || estimated > 0 else { return nil }
        if !building { return 1 }
        return min(elapsed(at: now) / estimated, 0.97)
    }

    func remaining(at now: Date) -> TimeInterval? {
        guard building, estimated > 0 else { return nil }
        return max(0, estimated - elapsed(at: now))
    }

    var currentStage: Stage? { stages.last { $0.running } }

    /// Past Jenkins' estimate: by how much (nil while within it, or without an estimate).
    func overtime(at now: Date) -> TimeInterval? {
        guard building, estimated > 0 else { return nil }
        let over = elapsed(at: now) - estimated
        return over > 0 ? over : nil
    }

    /// How long the running stage has been going: from Jenkins' start time for it, or else
    /// everything since the finished stages' time ran out.
    func stageTime(at now: Date) -> TimeInterval? {
        guard building, let stage = currentStage else { return nil }
        if let start = stage.start { return max(0, now.timeIntervalSince(start)) }
        return max(0, elapsed(at: now) - stages.filter { !$0.running }.reduce(0) { $0 + $1.duration })
    }
    var failedStage: Stage? { stages.first { $0.failed } }
}

/// What the island shows about your builds.
struct BuildSummary: Equatable {
    var running: [JenkinsBuild]      // building or queued, oldest first
    var recent: [JenkinsBuild]       // your finished builds (history from Jenkins, and any seen ending), newest first
    var unseenFailure: Bool

    var live: Bool { !running.isEmpty || unseenFailure }
    var lead: JenkinsBuild? { running.first { !$0.queued } ?? running.first }
    var all: [JenkinsBuild] { running + recent }
}

// MARK: - Reading Jenkins' answers

enum JenkinsParser {
    /// One build (`…/482/api/json`, or an executor's current build).
    static func build(_ node: [String: Any]) -> JenkinsBuild? {
        guard let number = node["number"] as? Int, let text = node["url"] as? String, let url = URL(string: text) else { return nil }
        let display = node["fullDisplayName"] as? String ?? ""
        let job = display.range(of: #" #\d+\s*$"#, options: .regularExpression).map { String(display[..<$0.lowerBound]) }
            ?? jobName(from: url)
        return JenkinsBuild(url: url, job: job.isEmpty ? jobName(from: url) : job, number: number,
                            building: node["building"] as? Bool ?? false,
                            result: node["result"] as? String,
                            started: Date(timeIntervalSince1970: (node["timestamp"] as? Double ?? 0) / 1000),
                            duration: (node["duration"] as? Double ?? 0) / 1000,
                            estimated: max(0, (node["estimatedDuration"] as? Double ?? -1) / 1000),
                            cause: causes(node).first?["shortDescription"] as? String)
    }

    /// The waiting queue (`/queue/api/json`): builds that haven't got an executor yet.
    static func queued(_ data: Data) -> [(id: Int, job: String, url: URL?, since: Date, causes: [[String: Any]])] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? Int else { return nil }
            let task = item["task"] as? [String: Any]
            return (id, task?["name"] as? String ?? "Build", (task?["url"] as? String).flatMap(URL.init(string:)),
                    Date(timeIntervalSince1970: (item["inQueueSince"] as? Double ?? 0) / 1000), causes(item))
        }
    }

    /// The pipeline's stages (`…/482/wfapi/describe`, from the Pipeline Stage View plugin).
    static func stages(_ data: Data) -> [JenkinsBuild.Stage] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stages = root["stages"] as? [[String: Any]] else { return [] }
        return stages.compactMap { stage in
            guard let name = stage["name"] as? String else { return nil }
            return .init(name: stageName(name), status: stage["status"] as? String ?? "NOT_EXECUTED",
                         duration: (stage["durationMillis"] as? Double ?? 0) / 1000, start: startTime(stage))
        }
    }

    /// The same from the newer Pipeline Graph View plugin (`…/482/pipeline-graph/tree`):
    /// `{"status":"ok","data":{"stages":[{"name","state","totalDurationMillis"}…]}}`, states
    /// in lower case.
    static func graphStages(_ data: Data) -> [JenkinsBuild.Stage] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let graph = root["data"] as? [String: Any] ?? root
        return (graph["stages"] as? [[String: Any]] ?? []).compactMap { stage in
            guard let name = stage["name"] as? String ?? stage["title"] as? String else { return nil }
            let status = switch (stage["state"] as? String ?? "").lowercased() {
            case "success": "SUCCESS"
            case "running": "IN_PROGRESS"
            case "paused": "PAUSED_PENDING_INPUT"
            case "failure": "FAILED"
            case "unstable": "UNSTABLE"
            case "aborted": "ABORTED"
            default: "NOT_EXECUTED"                       // queued, skipped, not_built
            }
            return .init(name: stageName(name), status: status, duration: (stage["totalDurationMillis"] as? Double ?? 0) / 1000,
                         start: startTime(stage))
        }
    }

    /// A stage's `startTimeMillis` (both plugins use the name), if it has one.
    static func startTime(_ stage: [String: Any]) -> Date? {
        guard let millis = stage["startTimeMillis"] as? Double, millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    /// "Declarative: Checkout SCM" → "Checkout SCM": the prefix is Jenkins' bookkeeping.
    static func stageName(_ name: String) -> String {
        name.hasPrefix("Declarative: ") ? String(name.dropFirst("Declarative: ".count)) : name
    }

    static func causes(_ node: [String: Any]) -> [[String: Any]] {
        (node["actions"] as? [[String: Any]] ?? []).flatMap { $0["causes"] as? [[String: Any]] ?? [] }
    }

    /// Started by you: your Jenkins id or name on a "started by user" cause, or your GitHub
    /// login on a push.
    static func startedBy(_ causes: [[String: Any]], ids: [String]) -> Bool {
        let mine = Set(ids.filter { !$0.isEmpty }.map { $0.lowercased() })
        return causes.contains { cause in
            if let user = (cause["userId"] as? String)?.lowercased(), mine.contains(user) { return true }
            if let name = (cause["userName"] as? String)?.lowercased(), mine.contains(name) { return true }
            let text = (cause["shortDescription"] as? String ?? "").lowercased()
            return mine.contains { text.hasSuffix(" by \($0)") || text.hasSuffix(" user \($0)") }
        }
    }

    /// "…/job/Folder/job/Deploy/482/" → "Folder » Deploy".
    static func jobName(from url: URL) -> String {
        let parts = url.pathComponents
        var names: [String] = []
        for (index, part) in parts.enumerated() where part == "job" && index + 1 < parts.count {
            names.append(parts[index + 1].removingPercentEncoding ?? parts[index + 1])
        }
        return names.joined(separator: " » ")
    }
}

// MARK: - Keychain

/// The Jenkins API token, in your login keychain, stored and read through macOS's own
/// `security` tool (the way gh keeps its token). The entry then belongs to that tool rather
/// than to one particular build of Notch, so rebuilding Notch never brings up a "wants to use
/// your keychain" prompt. The token goes in on the tool's standard input, never on a command
/// line other processes could see. Blocking: call it off the main thread.
enum Keychain {
    static let tool = "/usr/bin/security"

    /// Jenkins tokens are hex; anything else (spaces, quotes) could break the tool's input.
    static func isPlain(_ text: String) -> Bool {
        !text.isEmpty && text.range(of: #"^[A-Za-z0-9._@+-]+$"#, options: .regularExpression) != nil
    }

    nonisolated static func set(_ secret: String, service: String, account: String) -> Bool {
        guard isPlain(secret), isPlain(service), isPlain(account) else { return false }
        return run(["-i"], input: "add-generic-password -U -s \(service) -a \(account) -w \(secret)\n").status == 0
    }

    nonisolated static func get(service: String, account: String) -> String? {
        guard isPlain(service), isPlain(account) else { return nil }
        let result = run(["find-generic-password", "-s", service, "-a", account, "-w"], input: nil)
        guard result.status == 0 else { return nil }
        let token = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    @discardableResult
    nonisolated static func delete(service: String, account: String) -> Bool {
        guard isPlain(service), isPlain(account) else { return false }
        return run(["delete-generic-password", "-s", service, "-a", account], input: nil).status == 0
    }

    private nonisolated static func run(_ arguments: [String], input: String?) -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let feed = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : feed
        do { try process.run() } catch { return (-1, Data()) }
        if let input {
            feed.fileHandleForWriting.write(Data(input.utf8))
            try? feed.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    /// Runs a keychain call on a background queue and comes back with its result.
    static func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }
}

// MARK: - Watching

/// The Jenkins builds you start: any job, found by asking which builds are running right
/// now and who started them (one small request), plus the queue. A build of yours gets its
/// pipeline stages while it runs and a result banner when it ends.
///
/// Every 20 s while one of yours runs. Otherwise builds come in bursts, so the looks thin
/// out the longer nothing of yours has run: every 90 s for 10 minutes, every 3 minutes until
/// half an hour, then every 5, with only the executors asked (not the queue) once it's quiet.
/// A push to one of your PRs brings a look forward. Nothing while you're away.
@MainActor final class JenkinsWatcher: ObservableObject {
    /// The app's watcher (the customiser signs in through it).
    static let shared = JenkinsWatcher()

    struct Account: Equatable {
        var id: String
        var fullName: String
    }

    enum Phase: Equatable {
        case signedOut
        case signingIn
        case signedIn
        case failed(String)
    }

    @Published private(set) var phase: Phase = .signedOut
    @Published private(set) var account: Account?
    @Published private(set) var status = "Not signed in"
    @Published private(set) var running: [JenkinsBuild] = []
    @Published private(set) var recent: [JenkinsBuild] = []
    @Published private(set) var unseenFailure = false
    @Published private(set) var lastLook: Date?

    /// A build of yours finished.
    var onFinished: ((JenkinsBuild) -> Void)?
    /// After every look: rebuild what the island shows.
    var onChange: (() -> Void)?
    /// Locked, asleep, displays off: don't look.
    var isAway: () -> Bool = { false }
    /// Your GitHub login, so builds started by your pushes count as yours.
    var gitHubLogin: () -> String? = { nil }

    let keychainService: String
    private var timer: Timer?
    private var looking = false
    /// Your build history: when it was last read, and which finished builds already have stages.
    private var historyLoadedAt: Date?
    private var loadingHistory = false
    private var jobsSearched = false
    private var stagesFetched: Set<String> = []
    /// When a build of yours last ran, ended, or you last pushed: the idle looks back off from here.
    var lastActivity = Date()                     // (settable so tests can make it "quiet")
    private var failures = 0
    /// Where each job's stages come from, found on its first build: the Stage View plugin,
    /// the newer Pipeline Graph View, or nowhere (a freestyle job, or no stage plugin).
    enum StageSource: Equatable {
        case stageView
        case graphView(String)                            // its address: "pipeline-graph" or "pipeline-overview"
        case none

        var path: String {
            switch self {
            case .stageView: "wfapi/describe"
            case .graphView(let base): "\(base)/tree"
            case .none: ""
            }
        }
        var name: String {
            switch self {
            case .stageView: "the Stage View plugin"
            case .graphView: "the Pipeline Graph View plugin"
            case .none: "nowhere"
            }
        }
    }
    private(set) var stageSources: [String: StageSource] = [:]

    /// The token, once read from the keychain (reading it can take a moment, so it's kept).
    private var token: String?

    init(keychainService: String = "dev.notch.jenkins.token") {
        self.keychainService = keychainService
    }

    private var settings: NotchSettings { SettingsStore.shared.value }
    private var server: URL? { Self.serverURL(settings.jenkinsURL) }

    var summary: BuildSummary { BuildSummary(running: running, recent: recent, unseenFailure: unseenFailure) }

    /// You, as Jenkins and GitHub name you: builds started by any of these are yours.
    private var myIDs: [String] {
        let user = settings.jenkinsUser
        return [account?.id ?? user, user, account?.fullName ?? "", gitHubLogin() ?? ""]
    }

    /// "flyingdutchman.example.com" or a full URL, without a trailing slash.
    static func serverURL(_ text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.scheme == "https" || url.scheme == "http", url.host != nil else { return nil }
        return url
    }

    static func keychainAccount(_ user: String, _ server: URL) -> String { "\(user)@\(server.host ?? server.absoluteString)" }

    func start() {
        guard settings.builds, let server, !settings.jenkinsUser.isEmpty else {
            phase = .signedOut
            status = "Not signed in"
            return
        }
        let service = keychainService, account = Self.keychainAccount(settings.jenkinsUser, server)
        Task {
            // Off the main thread: the island never waits on the keychain.
            token = await Keychain.background { Keychain.get(service: service, account: account) }
            guard token != nil else {
                phase = .signedOut
                status = "Not signed in"
                log("jenkins: no saved token; sign in in the customiser")
                return
            }
            phase = .signedIn
            await verify(quietly: true)
        }
    }

    // MARK: Signing in

    /// Checks the username and token with Jenkins (`/me/api/json`); on success the token goes
    /// into the keychain and the watching starts.
    func signIn(server text: String, user: String, token: String) {
        let user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let server = Self.serverURL(text) else { return phase = .failed("That doesn't look like a Jenkins address.") }
        guard !user.isEmpty, !token.isEmpty else { return phase = .failed("Fill in your username and an API token.") }
        phase = .signingIn
        Task {
            let result = await Self.get(server.appendingPathComponent("me/api/json"), query: "tree=id,fullName", user: user, token: token)
            switch result {
            case .success(let data):
                guard let me = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = me["id"] as? String,
                      id != "anonymous" else {
                    phase = .failed("Jenkins answered, but not as a signed-in user. Check the username.")
                    return
                }
                let service = keychainService, entry = Self.keychainAccount(user, server)
                guard Keychain.isPlain(token) else {
                    phase = .failed("That token has characters a Jenkins token doesn't; paste it again.")
                    return
                }
                guard await Keychain.background({ Keychain.set(token, service: service, account: entry) }) else {
                    phase = .failed("Couldn't save the token in your keychain.")
                    return
                }
                self.token = token
                SettingsStore.shared.value.jenkinsURL = server.absoluteString
                SettingsStore.shared.value.jenkinsUser = user
                SettingsStore.shared.value.builds = true
                account = Account(id: id, fullName: me["fullName"] as? String ?? id)
                phase = .signedIn
                log("jenkins: signed in to \(server.host ?? "?") as \(id)")
                refresh()
            case .failure(let problem):
                phase = .failed(problem.message)
                log("jenkins: sign-in failed: \(problem.message)")
            }
        }
    }

    func signOut() {
        if let server {
            let service = keychainService, account = Self.keychainAccount(settings.jenkinsUser, server)
            Task { await Keychain.background { Keychain.delete(service: service, account: account) } }
        }
        token = nil
        historyLoadedAt = nil
        jobsSearched = false
        stagesFetched = []
        SettingsStore.shared.value.jenkinsJobs = []
        timer?.invalidate()
        account = nil
        running = []
        recent = []
        unseenFailure = false
        phase = .signedOut
        status = "Not signed in"
        log("jenkins: signed out; token removed from the keychain")
        onChange?()
    }

    private func verify(quietly: Bool) async {
        guard let server, let token else { return }
        let result = await Self.get(server.appendingPathComponent("me/api/json"), query: "tree=id,fullName", user: settings.jenkinsUser, token: token)
        if case .success(let data) = result, let me = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = me["id"] as? String, id != "anonymous" {
            account = Account(id: id, fullName: me["fullName"] as? String ?? id)
            phase = .signedIn
            log("jenkins: watching builds on \(server.host ?? "?") as \(id)")
            refresh()
        } else if case .failure(let problem) = result, problem.unauthorized {
            phase = .failed("Jenkins didn't accept the saved token. Sign in again.")
            log("jenkins: saved token refused (\(problem.message))")
        } else {
            phase = .signedIn                         // offline: keep trying on the usual schedule
            schedule(in: 120)
        }
    }

    // MARK: Looking

    func refresh() {
        timer?.invalidate()
        guard settings.builds, phase == .signedIn, let server, let token else { return }
        guard !isAway(), !looking else { return schedule(in: 60) }
        looking = true
        let user = settings.jenkinsUser
        let ids = myIDs
        // Quiet for a while: just the executors. A build of yours waiting in the queue shows
        // once it starts; while things are happening, the queue is asked too.
        let askQueue = !running.isEmpty || Date().timeIntervalSince(lastActivity) < Self.burst
        Task {
            let executors = await Self.get(server.appendingPathComponent("computer/api/json"), query: Self.executorsTree, user: user, token: token)
            let queue: Result<Data, Problem>? = askQueue
                ? await Self.get(server.appendingPathComponent("queue/api/json"), query: Self.queueTree, user: user, token: token) : nil
            guard case .success(let busy) = executors else {
                looking = false
                if case .failure(let problem) = executors { return failed(problem) }
                return
            }
            if failures > 0 { log("jenkins: back online") }
            failures = 0
            // Yours, from the executors (the tree keeps each build's causes)…
            let allRunning = Self.withCauses(busy)
            var mine = allRunning.filter { JenkinsParser.startedBy($0.causes, ids: ids) }.map(\.build)
            // …and from the queue.
            if case .success(let waiting)? = queue {
                for item in JenkinsParser.queued(waiting) where JenkinsParser.startedBy(item.causes, ids: ids) {
                    guard let url = item.url else { continue }
                    mine.append(JenkinsBuild(url: url.appendingPathComponent("queue-\(item.id)"), job: item.job, number: 0,
                                             building: true, result: nil, started: item.since, duration: 0, estimated: 0,
                                             cause: nil, queued: true))
                }
            }
            await finishLook(mine: mine, server: server, user: user, token: token)
        }
    }

    private func finishLook(mine: [JenkinsBuild], server: URL, user: String, token: String) async {
        let before = running
        // Stages for pipelines of yours that are running.
        var current: [JenkinsBuild] = []
        for var build in mine {
            if !build.queued {
                build.stages = await stages(for: build, user: user, token: token)
                    ?? before.first { $0.id == build.id }?.stages ?? []
            }
            current.append(build)
        }
        // Gone from the executors: finished. Ask each for its result.
        let gone = before.filter { old in !old.queued && !current.contains { $0.id == old.id } }
        for old in gone {
            var done = old
            if case .success(let data) = await Self.get(old.url.appendingPathComponent("api/json"), query: Self.buildTree, user: user, token: token),
               let node = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let build = JenkinsParser.build(node) {
                done = build
                done.stages = old.stages
                if let stages = await stages(for: old, user: user, token: token), !stages.isEmpty { done.stages = stages }
            }
            guard !done.building else { current.append(done); continue }       // still going (between executors)
            done.finishedAt = Date()
            recent.insert(done, at: 0)
            if done.failed { unseenFailure = true }
            log("jenkins: \(done.name) \(done.result?.lowercased() ?? "finished") after \(CommandAlerts.duration(done.duration))"
                + (done.failedStage.map { " (stage \($0.name))" } ?? ""))
            onFinished?(done)
        }
        recent = Array(recent.prefix(8))
        // A stage moved on: say so (the log shows what the stage bar shows).
        for build in current where !build.queued && !build.stages.isEmpty {
            let old = before.first { $0.id == build.id }?.stages.map { "\($0.name)\($0.status)" }
            guard old != build.stages.map({ "\($0.name)\($0.status)" }) else { continue }
            log("jenkins: \(build.name) stages: " + build.stages.map { stage in
                stage.name + (stage.status == "SUCCESS" ? " ✓" : stage.running ? " ▶" : stage.failed ? " ✗" : "")
            }.joined(separator: " · "))
        }
        let started = current.filter { new in !new.queued && !before.contains { $0.id == new.id } }
        if !started.isEmpty { log("jenkins: " + started.map { "\($0.name) running" }.joined(separator: "; ")) }
        running = current.sorted { $0.started < $1.started }
        lastLook = Date()
        let count = running.count
        status = count == 0 ? "No builds of yours running" : "\(count) build\(count == 1 ? "" : "s") of yours running"
        looking = false
        let newJob = remember(jobsOf: current.filter { !$0.queued } + gone)
        onChange?()
        if !running.isEmpty || !gone.isEmpty { lastActivity = Date() }
        schedule(in: Self.interval(running: !running.isEmpty, quietFor: Date().timeIntervalSince(lastActivity)))
        // Your build history: at the start, then every half hour, and at once when you build in a
        // job for the first time (its earlier builds of yours, even ones no look caught, show).
        if newJob { historyLoadedAt = nil }
        if historyLoadedAt.map({ Date().timeIntervalSince($0) > 1800 }) ?? true {
            await loadHistory(server: server, user: user, token: token)
        }
    }

    // MARK: History

    /// The job a build belongs to ("…/job/Deploy/482/" → "…/job/Deploy/").
    static func jobURL(of build: JenkinsBuild) -> URL { build.url.deletingLastPathComponent() }

    /// Jobs you've built, most recent first, kept in settings so the history survives restarts.
    /// True when one of them is new to the list.
    @discardableResult
    private func remember(jobsOf builds: [JenkinsBuild]) -> Bool {
        guard !builds.isEmpty else { return false }
        let known = Set(settings.jenkinsJobs)
        let added = builds.contains { !known.contains(Self.jobURL(of: $0).absoluteString) }
        var jobs = settings.jenkinsJobs
        for build in builds.reversed() {
            let job = Self.jobURL(of: build).absoluteString
            jobs.removeAll { $0 == job }
            jobs.insert(job, at: 0)
        }
        jobs = Array(jobs.prefix(8))
        if jobs != settings.jenkinsJobs { SettingsStore.shared.value.jenkinsJobs = jobs }
        return added
    }

    /// Your latest finished builds: each job you've built is asked for its last 30 builds (one
    /// small request each; shared jobs are mostly other people's) and yours are kept, merged with any seen ending here, newest first.
    /// Stages for the ones shown are read once (a finished build doesn't change).
    private func loadHistory(server: URL, user: String, token: String) async {
        guard !loadingHistory else { return }
        loadingHistory = true
        defer { loadingHistory = false }
        let ids = myIDs
        var jobs = settings.jenkinsJobs.compactMap(URL.init(string:))
        if jobs.isEmpty, !jobsSearched {
            jobsSearched = true
            jobs = await findJobs(server: server, user: user, token: token, ids: ids)
        }
        var found: [JenkinsBuild] = []
        for job in jobs.prefix(6) {
            guard case .success(let data) = await Self.get(job.appendingPathComponent("api/json"), query: "tree=builds[\(Self.buildFields)]{0,30}",
                                                           user: user, token: token),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for node in root["builds"] as? [[String: Any]] ?? [] {
                guard JenkinsParser.startedBy(JenkinsParser.causes(node), ids: ids), var build = JenkinsParser.build(node),
                      !build.building else { continue }
                build.finishedAt = build.started.addingTimeInterval(build.duration)
                found.append(build)
            }
        }
        var merged = recent
        for build in found where !merged.contains(where: { $0.id == build.id }) { merged.append(build) }
        merged.sort { ($0.finishedAt ?? $0.started) > ($1.finishedAt ?? $1.started) }
        merged = Array(merged.prefix(6))
        for index in merged.indices.prefix(3) where merged[index].stages.isEmpty && !stagesFetched.contains(merged[index].id) {
            stagesFetched.insert(merged[index].id)
            if let stages = await stages(for: merged[index], user: user, token: token) { merged[index].stages = stages }
        }
        if historyLoadedAt == nil {
            log("jenkins: history: \(found.count) finished build\(found.count == 1 ? "" : "s") of yours in \(jobs.prefix(6).count) job\(jobs.count == 1 ? "" : "s")")
        }
        historyLoadedAt = Date()
        recent = merged
        onChange?()
    }

    /// The first time, with no jobs remembered yet: one look over every job's last five builds
    /// (three folder levels deep) for ones you started. Once per launch at most.
    private func findJobs(server: URL, user: String, token: String, ids: [String]) async -> [URL] {
        let builds = "builds[number,actions[causes[userId,userName,shortDescription]]]{0,5}"
        let tree = "tree=jobs[url,\(builds),jobs[url,\(builds),jobs[url,\(builds)]]]"
        guard case .success(let data) = await Self.get(server.appendingPathComponent("api/json"), query: tree, user: user, token: token, timeout: 45),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("jenkins: couldn't look for the jobs you've run; history starts with your next build")
            return []
        }
        var found: [URL] = []
        func walk(_ jobs: [[String: Any]]) {
            for job in jobs {
                if (job["builds"] as? [[String: Any]] ?? []).contains(where: { JenkinsParser.startedBy(JenkinsParser.causes($0), ids: ids) }),
                   let text = job["url"] as? String, let url = URL(string: text) {
                    found.append(url)
                }
                walk(job["jobs"] as? [[String: Any]] ?? [])
            }
        }
        walk(root["jobs"] as? [[String: Any]] ?? [])
        log("jenkins: found \(found.count) job\(found.count == 1 ? "" : "s") you've run recently (looked through \(data.count / 1024) KB)")
        let remembered = Array(found.prefix(8).map(\.absoluteString))
        if !remembered.isEmpty { SettingsStore.shared.value.jenkinsJobs = remembered }
        return found
    }

    /// A build's stages from whichever plugin this Jenkins has (found once per job, then
    /// asked directly). [] for a job without stages; nil when the look failed (keep the last).
    private func stages(for build: JenkinsBuild, user: String, token: String) async -> [JenkinsBuild.Stage]? {
        let known = stageSources[build.job]
        if known == StageSource.none { return [] }
        let candidates: [StageSource] = known.map { [$0] } ?? [.stageView, .graphView("pipeline-graph"), .graphView("pipeline-overview")]
        for source in candidates {
            switch await Self.get(build.url.appendingPathComponent(source.path), query: nil, user: user, token: token) {
            case .success(let data):
                if known == nil {
                    stageSources[build.job] = source
                    log("jenkins: \(build.job): stages from \(source.name)")
                }
                return source == .stageView ? JenkinsParser.stages(data) : JenkinsParser.graphStages(data)
            case .failure(let problem) where problem.status == 404:
                continue
            case .failure:
                return nil
            }
        }
        stageSources[build.job] = StageSource.none
        log("jenkins: \(build.job) has no stages (not a pipeline, or no stage plugin); showing time progress")
        return []
    }

    /// Builds come in bursts: within this long of the last one, keep looking often.
    static let burst: TimeInterval = 600

    /// Until the next look: quick while a build of yours runs; a minute for a while after one,
    /// then every two minutes. Not longer: a build that starts and ends between two looks is
    /// never seen running (a 4-minute merge slipped between 5-minute looks).
    static func interval(running: Bool, quietFor: TimeInterval) -> TimeInterval {
        if running { return 20 }
        return quietFor < burst ? 60 : 120
    }

    /// You pushed to one of your PRs, which often starts builds: look in a moment and keep
    /// looking often for a while, rather than waiting out a quiet-time gap.
    func lookSoon(in seconds: TimeInterval = 20) {
        lastActivity = Date()
        guard settings.builds, phase == .signedIn, !looking else { return }
        if let fire = timer?.fireDate, fire.timeIntervalSinceNow <= seconds { return }
        schedule(in: seconds)
    }

    /// You looked at the builds page: failures are seen.
    func markSeen() {
        guard unseenFailure else { return }
        unseenFailure = false
        onChange?()
    }

    private func failed(_ problem: Problem) {
        failures += 1
        if problem.unauthorized {
            phase = .failed("Jenkins stopped accepting the token. Sign in again.")
            log("jenkins: token refused (\(problem.message))")
            onChange?()
            return
        }
        if failures == 1 { log("jenkins: couldn't look (\(problem.message)); backing off") }
        status = failures > 2 ? "Can't reach Jenkins right now" : status
        schedule(in: min(60 * pow(2, Double(failures - 1)), 600))
    }

    private func schedule(in seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: Requests

    static let buildFields = "number,url,fullDisplayName,building,result,timestamp,duration,estimatedDuration,actions[causes[userId,userName,shortDescription]]"
    static let executorsTree = "tree=computer[executors[currentExecutable[\(buildFields)]],oneOffExecutors[currentExecutable[\(buildFields)]]]"
    static let queueTree = "tree=items[id,inQueueSince,task[name,url],actions[causes[userId,userName,shortDescription]]]"
    static let buildTree = "tree=\(buildFields)"

    /// The executors' builds, each with its causes.
    static func withCauses(_ data: Data) -> [(build: JenkinsBuild, causes: [[String: Any]])] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let computers = root["computer"] as? [[String: Any]] else { return [] }
        var seen: Set<String> = []
        var out: [(JenkinsBuild, [[String: Any]])] = []
        for computer in computers {
            for key in ["executors", "oneOffExecutors"] {
                for executor in computer[key] as? [[String: Any]] ?? [] {
                    guard let run = executor["currentExecutable"] as? [String: Any], let build = JenkinsParser.build(run),
                          seen.insert(build.id).inserted else { continue }
                    out.append((build, JenkinsParser.causes(run)))
                }
            }
        }
        return out
    }

    struct Problem: Error {
        var status: Int?
        var message: String
        var unauthorized: Bool { status == 401 || status == 403 }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral          // no cookies, no cache on disk
        config.timeoutIntervalForRequest = 15
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    /// A GET with your username and API token (Basic auth, as Jenkins expects for tokens).
    static func get(_ url: URL, query: String?, user: String, token: String, timeout: TimeInterval = 15) async -> Result<Data, Problem> {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let query { components?.percentEncodedQuery = query.addingPercentEncoding(withAllowedCharacters: .jenkinsQuery) }
        guard let full = components?.url else { return .failure(Problem(status: nil, message: "bad address")) }
        var request = URLRequest(url: full)
        request.timeoutInterval = timeout
        request.setValue("Basic " + Data("\(user):\(token)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300: return .success(data)
            case 401: return .failure(Problem(status: status, message: "Jenkins didn't accept that username and token"))
            case 403: return .failure(Problem(status: status, message: "Jenkins refused access (403)"))
            default: return .failure(Problem(status: status, message: "Jenkins answered \(status)"))
            }
        } catch {
            return .failure(Problem(status: nil, message: error.localizedDescription))
        }
    }
}

private extension CharacterSet {
    /// Query characters left as they are: `tree=`'s brackets get percent-encoded (URLComponents
    /// refuses them raw, and Jenkins decodes them either way); commas and `=` stay.
    static let jenkinsQuery: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "[]+&")
        set.insert(charactersIn: ",=")
        return set
    }()
}

/// The banner when a build of yours ends.
enum BuildBanner {
    static func banner(for build: JenkinsBuild) -> Banner {
        let took = CommandAlerts.duration(build.duration)
        if build.passed {
            return Banner(symbol: "checkmark.circle.fill", tint: .green, title: "\(build.name) passed",
                          subtitle: "Took \(took)", accessory: .check, duration: 5)
        }
        let verb = build.result == "ABORTED" ? "was aborted" : build.result == "UNSTABLE" ? "is unstable" : "failed"
        return Banner(symbol: "xmark.octagon.fill", tint: .red, title: "\(build.name) \(verb)",
                      subtitle: build.failedStage.map { "At \($0.name) · after \(took)" } ?? "After \(took)",
                      accessory: .cross, duration: 7)
    }
}
