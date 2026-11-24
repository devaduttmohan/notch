import AppKit

// MARK: - Model

/// One of your open pull requests (or one waiting for your review), as Notch sees it.
struct PullRequest: Equatable, Identifiable {
    enum CheckState: Equatable { case pending, success, failure, neutral }

    struct Check: Equatable {
        var name: String
        var state: CheckState
        var url: URL?
    }

    struct Review: Equatable {
        var id: String
        var author: String
        var state: String            // APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED
        var submittedAt: Date
    }

    struct Comment: Equatable {
        var id: String
        var author: String
        var body: String
        var createdAt: Date
        var url: URL?
        var path: String?            // set for inline review comments
    }

    var id: String
    var number: Int
    var title: String
    var url: URL
    var repo: String                 // owner/name
    var branch: String
    var isDraft: Bool
    var updatedAt: Date
    var head: String?
    var checks: [Check]
    var reviewDecision: String?
    var mergeState: String?
    var reviews: [Review]
    var unresolvedThreads: Int
    var openFlockThreads = 0         // unresolved review threads Flock started
    var threadsCapped = false        // over 100 threads: the counts are "at least"
    /// "5", or "48+" when there were more threads than one look reads.
    var openFlockLabel: String { "\(openFlockThreads)\(threadsCapped ? "+" : "")" }
    var comments: [Comment]          // conversation comments and the latest comment of each review thread
    var waitingOnMe = false          // someone else's PR, review requested from you
    var author: String?
    /// Check counts from the latest pulse. Progress reads these, so a check finishing doesn't
    /// need a full read; the names in `checks` are refreshed when one fails or the run ends.
    var tally: CheckTally?

    /// The Jira key from the branch name ("SSE-68225-embed-save" → "SSE-68225").
    var ticket: String? {
        branch.range(of: #"[A-Z][A-Z0-9]+-\d+"#, options: .regularExpression).map { String(branch[$0]) }
    }
    var checksTotal: Int { tally?.total ?? checks.count }
    var checksDone: Int { tally?.done ?? checks.filter { $0.state != .pending }.count }
    /// Every check green (skipped ones don't count against it), none failing or running.
    var checksPass: Bool { checksTotal > 0 && !running && (tally?.failed ?? failedChecks.count) == 0 }
    /// People (not bots: Flock's approval doesn't count) whose latest review approves.
    var approvers: [String] {
        var latest: [String: Review] = [:]
        for review in reviews where !PRDiff.isBot(review.author) && review.state != "COMMENTED" {
            if (latest[review.author]?.submittedAt ?? .distantPast) <= review.submittedAt { latest[review.author] = review }
        }
        return latest.values.filter { $0.state == "APPROVED" }.map(\.author).sorted()
    }
    /// Really approved: a person approved, nobody's asking for changes, and every check
    /// (hatch/flock-review included) passes.
    var approved: Bool { checksPass && !approvers.isEmpty && reviewDecision != "CHANGES_REQUESTED" }
    var running: Bool { tally.map { $0.pending > 0 } ?? checks.contains { $0.state == .pending } }
    var failedChecks: [Check] { checks.filter { $0.state == .failure } }
    /// "surveysparrow-staging-config #796", or just "#5045" in your main repo.
    func shortName(mainRepo: String?) -> String {
        repo == mainRepo ? "#\(number)" : "\(repo.split(separator: "/").last ?? "") #\(number)"
    }
}

/// Something that happened to a PR between two looks.
struct PREvent: Equatable {
    enum Kind: Equatable {
        case checksPassed
        case checksFailed([String])
        case approved(String)
        case changesRequested(String)
        case reviewed(String)
        case commented(String, String, Int)    // who, first line, how many
        case readyToMerge
        case merged
        case closed
        case reviewRequested(String)
        case allClear                         // approved by a person and every check passed
    }

    var pr: PullRequest
    var kind: Kind

    /// Worth flagging until you've looked (shows red in the bubble, sorts first).
    var needsYou: Bool {
        switch kind {
        case .checksFailed, .changesRequested, .commented, .reviewRequested: true
        default: false
        }
    }
    /// From Flock (its review, comments, or the hatch/flock-review check): these stay on the
    /// notch until you've looked, like Claude's updates.
    var fromFlock: Bool {
        switch kind {
        case .commented(let who, _, _), .changesRequested(let who), .reviewed(let who), .approved(let who): who == "Flock"
        case .checksFailed(let names): names.contains { $0.localizedCaseInsensitiveContains("flock") }
        default: false
        }
    }

    var bad: Bool {
        switch kind {
        case .checksFailed, .changesRequested: true
        default: false
        }
    }

    func summary(mainRepo: String?) -> String {
        let name = pr.shortName(mainRepo: mainRepo)
        switch kind {
        case .checksPassed: return "\(name) checks passed"
        case .checksFailed(let names): return "\(name) " + (names.first.map { "\($0) failed" } ?? "checks failed")
        case .approved(let who): return "\(name) approved by \(who)"
        case .changesRequested(let who): return "\(name) changes requested by \(who)"
        case .reviewed(let who): return "\(name) reviewed by \(who)"
        case .commented(let who, _, let count): return "\(name) \(count) new comment\(count == 1 ? "" : "s") from \(who)"
        case .readyToMerge: return "\(name) ready to merge"
        case .merged: return "\(name) merged"
        case .closed: return "\(name) closed"
        case .reviewRequested(let who): return "\(name) review requested by \(who)"
        case .allClear: return "\(name) approved, all checks passed"
        }
    }
}

// MARK: - Reading GitHub's answer

/// The cheap "has anything changed?" view of a PR: costs about one point for all of them.
struct PRPulse: Equatable {
    var updatedAt: Date
    var head: String?
    var rollup: String?
    var counts: [String]              // check runs and statuses counted by state, e.g. "SUCCESS:7"
    var mergeState: String?
    var decision: String?
    var waitingOnMe: Bool

    /// The counts, by outcome (mapped the same way as full check details).
    var tally: CheckTally {
        var tally = CheckTally()
        for entry in counts {                          // "run.SUCCESS:7", "status.PENDING:2"
            guard let colon = entry.lastIndex(of: ":"), let n = Int(entry[entry.index(after: colon)...]) else { continue }
            tally.total += n
            switch entry[..<colon].split(separator: ".").last ?? "" {
            case "IN_PROGRESS", "QUEUED", "PENDING", "WAITING", "REQUESTED", "EXPECTED": break
            case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR":
                tally.done += n
                tally.failed += n
            default: tally.done += n                   // success, skipped, neutral, stale
            }
        }
        return tally
    }

    /// Why a PR needs a full read after this pulse (2 points), or nil when only its checks moved
    /// on: the counts are enough for the ring and "7/11". Names are fetched when a check fails
    /// or is re-run, and when the run finishes (that's when its banner goes out).
    static func readReason(old: PRPulse?, new: PRPulse) -> String? {
        guard let old else { return "new" }
        if new.head != old.head { return "new commit" }
        if new.updatedAt != old.updatedAt { return "updated" }
        if new.mergeState != old.mergeState { return "merge state" }
        if new.decision != old.decision { return "review decision" }
        if new.waitingOnMe != old.waitingOnMe { return "review requested" }
        let was = old.tally, now = new.tally
        if now.failed > was.failed { return "check failed" }
        if now.failed < was.failed { return "check re-run" }
        if now.pending == 0 && was.pending > 0 { return "checks finished" }
        if now.pending == 0 && now != was { return "checks changed" }
        return nil
    }
}

/// Checks counted by outcome, without names.
struct CheckTally: Equatable {
    var done = 0
    var failed = 0
    var total = 0
    var pending: Int { total - done }
}

/// GitHub's GraphQL budget: points per hour, shared by everything using your gh login.
struct RateLimit: Equatable {
    var cost: Int
    var remaining: Int
    var limit: Int
    var resetAt: Date
}

enum PRParser {
    static func rate(_ root: [String: Any]?) -> RateLimit? {
        guard let node = (root?["data"] as? [String: Any])?["rateLimit"] as? [String: Any],
              let remaining = node["remaining"] as? Int, let limit = node["limit"] as? Int else { return nil }
        return RateLimit(cost: node["cost"] as? Int ?? 1, remaining: remaining, limit: limit, resetAt: date(node["resetAt"]))
    }

    /// The pulse query: your login, then every PR's pulse in the order GitHub lists them.
    static func parsePulse(_ data: Data) -> (login: String, order: [String], pulses: [String: PRPulse], rate: RateLimit?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let viewer = payload["viewer"] as? [String: Any],
              let login = viewer["login"] as? String else { return nil }
        var order: [String] = []
        var pulses: [String: PRPulse] = [:]
        func add(_ nodes: Any?, waiting: Bool) {
            for node in ((nodes as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [] {
                guard let id = node["id"] as? String, pulses[id] == nil else { continue }
                let commit = ((node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["commit"] as? [String: Any]
                let rollup = commit?["statusCheckRollup"] as? [String: Any]
                let contexts = rollup?["contexts"] as? [String: Any]
                let counts = (["checkRunCountsByState", "statusContextCountsByState"].flatMap { key in
                    (contexts?[key] as? [[String: Any]] ?? []).compactMap { entry -> String? in
                        guard let state = entry["state"] as? String, let count = entry["count"] as? Int, count > 0 else { return nil }
                        return "\(key.hasPrefix("check") ? "run" : "status").\(state):\(count)"
                    }
                }).sorted()
                order.append(id)
                pulses[id] = PRPulse(updatedAt: date(node["updatedAt"]), head: commit?["oid"] as? String,
                                     rollup: rollup?["state"] as? String, counts: counts,
                                     mergeState: node["mergeStateStatus"] as? String, decision: node["reviewDecision"] as? String,
                                     waitingOnMe: waiting)
            }
        }
        add(viewer["pullRequests"], waiting: false)
        add(payload["requested"], waiting: true)
        return (login, order, pulses, rate(root))
    }

    /// The details query (nodes by id): full PRs.
    static func parseNodes(_ data: Data) -> (prs: [PullRequest], rate: RateLimit?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodes = (root["data"] as? [String: Any])?["nodes"] as? [[String: Any]] else { return nil }
        return (nodes.compactMap(pr), rate(root))
    }


    /// The viewer's login, their open PRs, and PRs waiting on their review.
    static func parse(_ data: Data) -> (login: String, prs: [PullRequest])? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let viewer = payload["viewer"] as? [String: Any],
              let login = viewer["login"] as? String else { return nil }
        let mine = ((viewer["pullRequests"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap(pr)
        let requested = ((payload["requested"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap { node -> PullRequest? in
            guard var request = pr(node) else { return nil }
            request.waitingOnMe = true
            return request
        }
        return (login, mine + requested.filter { r in !mine.contains { $0.id == r.id } })
    }

    static func pr(_ node: [String: Any]) -> PullRequest? {
        guard let id = node["id"] as? String, let number = node["number"] as? Int,
              let urlText = node["url"] as? String, let url = URL(string: urlText) else { return nil }
        let commit = ((node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["commit"] as? [String: Any]
        let rollup = commit?["statusCheckRollup"] as? [String: Any]
        let contexts = (rollup?["contexts"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let reviews = ((node["reviews"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap { r -> PullRequest.Review? in
            guard let id = r["id"] as? String, let state = r["state"] as? String else { return nil }
            return PullRequest.Review(id: id, author: login(r["author"]), state: state, submittedAt: date(r["submittedAt"]))
        }
        let threads = (node["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let threadComments = threads.compactMap { t -> PullRequest.Comment? in
            guard let last = ((t["latest"] as? [String: Any])?["nodes"] as? [[String: Any]])?.last else { return nil }
            return comment(last)
        }
        let openFlock = threads.filter { t in
            let starter = (((t["first"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first).map { login($0["author"]) } ?? ""
            return (t["isResolved"] as? Bool) == false && starter.hasPrefix("flock")
        }.count
        let conversation = ((node["comments"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap(comment)
        return PullRequest(id: id, number: number, title: node["title"] as? String ?? "Pull request #\(number)", url: url,
                           repo: ((node["repository"] as? [String: Any])?["nameWithOwner"] as? String) ?? "",
                           branch: node["headRefName"] as? String ?? "", isDraft: node["isDraft"] as? Bool ?? false,
                           updatedAt: date(node["updatedAt"]), head: commit?["oid"] as? String,
                           checks: contexts.compactMap(check), reviewDecision: node["reviewDecision"] as? String,
                           mergeState: node["mergeStateStatus"] as? String, reviews: reviews,
                           unresolvedThreads: threads.filter { ($0["isResolved"] as? Bool) == false }.count,
                           openFlockThreads: openFlock, threadsCapped: threads.count >= 100,
                           comments: conversation + threadComments, author: login(node["author"]))
    }

    static func check(_ node: [String: Any]) -> PullRequest.Check? {
        if node["__typename"] as? String == "CheckRun", let name = node["name"] as? String {
            let state: PullRequest.CheckState
            if node["status"] as? String != "COMPLETED" { state = .pending }
            else {
                switch node["conclusion"] as? String {
                case "SUCCESS": state = .success
                case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": state = .failure
                default: state = .neutral                                   // skipped, neutral, stale
                }
            }
            return .init(name: name, state: state, url: (node["detailsUrl"] as? String).flatMap(URL.init(string:)))
        }
        if let name = node["context"] as? String {
            let state: PullRequest.CheckState = switch node["state"] as? String {
            case "SUCCESS": .success
            case "FAILURE", "ERROR": .failure
            default: .pending                                               // pending, expected
            }
            return .init(name: name, state: state, url: (node["targetUrl"] as? String).flatMap(URL.init(string:)))
        }
        return nil
    }

    static func comment(_ node: [String: Any]) -> PullRequest.Comment? {
        guard let id = node["id"] as? String else { return nil }
        return .init(id: id, author: login(node["author"]), body: node["body"] as? String ?? "", createdAt: date(node["createdAt"]),
                     url: (node["url"] as? String).flatMap(URL.init(string:)), path: node["path"] as? String)
    }

    static func login(_ author: Any?) -> String { (author as? [String: Any])?["login"] as? String ?? "ghost" }
    static func date(_ value: Any?) -> Date { (value as? String).flatMap { try? Date($0, strategy: .iso8601) } ?? .distantPast }
}

// MARK: - What changed

enum PRDiff {
    /// Review bots: Flock and anything GitHub marks "[bot]". Their approval isn't an approval.
    static func isBot(_ login: String) -> Bool { login.hasSuffix("[bot]") || login.hasPrefix("flock") }

    /// Flock's review bot shows as "Flock"; "[bot]" suffixes go.
    static func person(_ login: String) -> String {
        let plain = login.replacingOccurrences(of: "[bot]", with: "")
        return plain.hasPrefix("flock") ? "Flock" : plain
    }

    /// The first readable line of a comment: no markdown furniture, no HTML, at most ~90 characters.
    static func firstLine(_ body: String) -> String {
        let lines = body.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#>*-_` ").union(.whitespaces)) }
        // Skip images, tables and header lines like "Affected file: …" to reach what was said.
        let header = #"^\**(affected files?|files?|path|location)\**\s*:"#
        let line = lines.first {
            $0.count > 3 && !$0.hasPrefix("!") && !$0.hasPrefix("|")
                && $0.range(of: header, options: [.regularExpression, .caseInsensitive]) == nil
        } ?? ""
        let plain = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        return plain.count > 90 ? String(plain.prefix(88)) + "…" : plain
    }

    /// Events between two looks. `ignored` logins (bots that only post boilerplate) and your
    /// own activity don't count.
    static func events(old: [PullRequest], new: [PullRequest], me: String, ignored: Set<String>) -> [PREvent] {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var events: [PREvent] = []
        let ignoredLogins = Set(ignored.map { $0.lowercased() })
        func counts(_ login: String) -> Bool {            // GitHub logins ignore case
            let plain = login.lowercased()
            return plain != me.lowercased() && !ignoredLogins.contains(plain)
                && !ignoredLogins.contains(plain.replacingOccurrences(of: "[bot]", with: ""))
        }
        for pr in new {
            guard let was = before[pr.id] else {
                if pr.waitingOnMe { events.append(PREvent(pr: pr, kind: .reviewRequested(person(pr.author ?? "someone")))) }
                continue                                          // a PR you just opened: nothing to say yet
            }
            if pr.waitingOnMe && !was.waitingOnMe {
                events.append(PREvent(pr: pr, kind: .reviewRequested(person(pr.author ?? "someone"))))
            }
            // Checks: report when a run finishes (a new push that was already done counts too).
            let newPush = pr.head != was.head
            if pr.checksTotal > 0, !pr.running, was.running || newPush {
                let failed = pr.failedChecks.map(\.name)
                events.append(PREvent(pr: pr, kind: failed.isEmpty ? .checksPassed : .checksFailed(failed)))
            }
            // New reviews.
            let seenReviews = Set(was.reviews.map(\.id))
            var personApproved = false
            for review in pr.reviews where !seenReviews.contains(review.id) && counts(review.author) {
                switch review.state {
                case "APPROVED" where isBot(review.author):
                    events.append(PREvent(pr: pr, kind: .reviewed(person(review.author))))   // Flock passing isn't approval
                case "APPROVED":
                    personApproved = true
                    events.append(PREvent(pr: pr, kind: pr.approved ? .allClear : .approved(person(review.author))))
                case "CHANGES_REQUESTED": events.append(PREvent(pr: pr, kind: .changesRequested(person(review.author))))
                case "COMMENTED": events.append(PREvent(pr: pr, kind: .reviewed(person(review.author))))
                default: break
                }
            }
            // New comments, grouped by who wrote them (a review's inline comments come together).
            let seenComments = Set(was.comments.map(\.id))
            let fresh = pr.comments.filter { !seenComments.contains($0.id) && counts($0.author) }
            var byAuthor: [String: [PullRequest.Comment]] = [:]
            for comment in fresh { byAuthor[person(comment.author), default: []].append(comment) }
            for (who, comments) in byAuthor.sorted(by: { $0.key < $1.key }) {
                // A review that just landed already says it; skip its comments unless they're the news.
                if events.contains(where: { $0.pr.id == pr.id && [PREvent.Kind.changesRequested(who), .reviewed(who)].contains($0.kind) }) { continue }
                let latest = comments.max { $0.createdAt < $1.createdAt }!
                events.append(PREvent(pr: pr, kind: .commented(who, firstLine(latest.body), comments.count)))
            }
            // Became really approved without a new approval (the last checks just went green).
            if pr.approved, !was.approved, !personApproved, !pr.waitingOnMe {
                events.removeAll { $0.pr.id == pr.id && $0.kind == .checksPassed }
                events.append(PREvent(pr: pr, kind: .allClear))
            }
            if pr.mergeState == "CLEAN", was.mergeState != "CLEAN", !pr.waitingOnMe {
                events.append(PREvent(pr: pr, kind: .readyToMerge))
            }
        }
        return events
    }
}

// MARK: - Watching

/// Your pull requests, through the `gh` command line you're already signed in to (Notch never
/// holds a GitHub token). One GraphQL query a minute, every 20 s while checks run, paused
/// while the Mac sleeps; backs off quietly when offline.
@MainActor final class PRWatcher: ObservableObject {
    @Published private(set) var prs: [PullRequest] = []
    @Published private(set) var login: String?
    @Published private(set) var status = "Not checked yet"
    /// PRs with something you haven't seen yet (a failure, changes requested, a comment…).
    @Published private(set) var unseen: Set<String> = []
    @Published private(set) var lastEvents: [String: PREvent] = [:]
    /// The last GraphQL budget GitHub reported.
    @Published private(set) var rate: RateLimit?
    /// Who gh is signed in as (and the sign-in flow the customiser drives).
    let account = GitHubAccount()
    private var pulses: [String: PRPulse] = [:]
    /// Looks since a PR's last full read where only its check counts moved.
    private var countsOnly: [String: Int] = [:]
    private var lowBudgetLogged = false

    var onEvents: (([PREvent]) -> Void)?
    /// After every look (and when things are marked seen): rebuild what the island shows.
    var onChange: (() -> Void)?

    private var timer: Timer?
    private var fetching = false
    private var failures = 0
    private var asleep = false
    private var observers: [any NSObjectProtocol] = []

    /// Why nobody's at the Mac right now. While any of these hold, Notch doesn't spend API
    /// points; when the last one ends it catches up in one look, so nothing is missed.
    enum AwayReason: String {
        case locked = "screen locked"
        case displaysAsleep = "displays asleep"
        case switchedOut = "switched to another user"
    }
    private(set) var away: Set<AwayReason> = []
    /// The session dictionary's lock flag is undocumented, so it's only trusted to end a pause
    /// once it has been seen confirming one.
    private var lockFlagSeen = false

    static var ghPath: String? {
        // NOTCH_GH_PATH: tests point this at a stand-in that replays recorded answers.
        ([ProcessInfo.processInfo.environment["NOTCH_GH_PATH"]].compactMap { $0 } + ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"])
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The repo most of your PRs are in (named without its owner in the list).
    var mainRepo: String? {
        Dictionary(grouping: prs.filter { !$0.waitingOnMe }, by: \.repo).max { $0.value.count < $1.value.count }?.key
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.asleep = true }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.asleep = false
                self?.refresh()
            }
        })
        account.onChange = { [weak self] in self?.refresh() }
        account.load()
        let awaySignals: [(NotificationCenter, String, AwayReason, Bool)] = [
            (DistributedNotificationCenter.default(), "com.apple.screenIsLocked", .locked, true),
            (DistributedNotificationCenter.default(), "com.apple.screenIsUnlocked", .locked, false),
            (workspace, NSWorkspace.screensDidSleepNotification.rawValue, .displaysAsleep, true),
            (workspace, NSWorkspace.screensDidWakeNotification.rawValue, .displaysAsleep, false),
            (workspace, NSWorkspace.sessionDidResignActiveNotification.rawValue, .switchedOut, true),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification.rawValue, .switchedOut, false),
        ]
        for (center, name, reason, on) in awaySignals {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAway(reason, on) }
            })
        }
        // Started behind the lock screen (relaunched while you're away): pause from the start.
        if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true {
            lockFlagSeen = true
            setAway(.locked, true)
        }
        refresh()
    }

    /// Pause while you're away; when the last reason ends, look straight away.
    func setAway(_ reason: AwayReason, _ on: Bool) {
        let wasAway = !away.isEmpty
        if on { away.insert(reason) } else { away.remove(reason) }
        if !wasAway && !away.isEmpty {
            log("github: \(reason.rawValue); pausing PR checks until you're back")
        } else if wasAway && away.isEmpty {
            log("github: you're back; catching up on PRs")
            refresh()
        }
    }

    /// While paused, a check that costs nothing: is the Mac really still locked, dark or
    /// switched away? Ends a pause whose "you're back" notification never came.
    private func confirmAway() {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        var ended: [AwayReason] = []
        if away.contains(.switchedOut), session?[kCGSessionOnConsoleKey as String] as? Bool == true { ended.append(.switchedOut) }
        if away.contains(.displaysAsleep), CGDisplayIsAsleep(CGMainDisplayID()) == 0 { ended.append(.displaysAsleep) }
        if away.contains(.locked) {
            if session?["CGSSessionScreenIsLocked"] as? Bool == true { lockFlagSeen = true }
            else if lockFlagSeen { ended.append(.locked) }
        }
        guard !ended.isEmpty else { return }
        ended.forEach { away.remove($0) }
        if away.isEmpty { log("github: you're back (" + ended.map(\.rawValue).joined(separator: ", ") + " no longer true); catching up on PRs") }
    }

    /// Look now (and then on the usual schedule).
    func refresh() {
        timer?.invalidate()
        guard SettingsStore.shared.value.pullRequests else {
            status = "Off"
            return schedule(in: 120)
        }
        if !away.isEmpty { confirmAway() }
        guard !asleep, away.isEmpty, !fetching else { return schedule(in: 60) }
        guard let gh = Self.ghPath else {
            status = "Install the GitHub CLI (gh) and sign in"
            return schedule(in: 600)
        }
        fetching = true
        let query = Self.pulseQuery
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.run(gh, ["api", "graphql", "-F", "n=20", "-f", "query=\(query)"])
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receivedPulse(result, gh: gh) }
            }
        }
    }

    /// Step 1, about one point: what changed since the last look? Step 2 fetches full details
    /// only for those PRs (usually none), instead of re-reading everything every time.
    private func receivedPulse(_ result: (status: Int32, output: Data), gh: String) {
        guard result.status == 0, let parsed = PRParser.parsePulse(result.output) else { return failed(result.status) }
        note(parsed.rate)
        var reasons: [String: String] = [:]
        let switching = login != nil && login?.lowercased() != parsed.login.lowercased()   // another account: read all
        for id in parsed.order where switching || pulses[id] != parsed.pulses[id] || !prs.contains(where: { $0.id == id }) {
            let known = !switching && prs.contains { $0.id == id }
            if let why = known ? PRPulse.readReason(old: pulses[id], new: parsed.pulses[id]!) : "new" {
                reasons[id] = why
            } else {
                countsOnly[id, default: 0] += 1         // only checks moved on: the counts will do
            }
        }
        pulses = parsed.pulses
        countsOnly = countsOnly.filter { parsed.pulses[$0.key] != nil }
        let ids = parsed.order.filter { reasons[$0] != nil && $0.range(of: "^[A-Za-z0-9_=-]+$", options: .regularExpression) != nil }
        guard !ids.isEmpty else { return finish(login: parsed.login, order: parsed.order, details: [:]) }
        let why = reasons
        let query = Self.detailQuery(ids: ids)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let details = Self.run(gh, ["api", "graphql", "-f", "query=\(query)"])
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard details.status == 0, let nodes = PRParser.parseNodes(details.output) else {
                        ids.forEach { self.pulses[$0] = nil }        // look again next time
                        return self.failed(details.status)
                    }
                    self.note(nodes.rate)
                    self.logReads(ids, why, cost: nodes.rate?.cost)
                    self.finish(login: parsed.login, order: parsed.order,
                                details: Dictionary(nodes.prs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
                }
            }
        }
    }

    /// One line per full read: which PRs, why, and what it cost. A read after a run of
    /// progress-only looks says how many it skipped.
    private func logReads(_ ids: [String], _ reasons: [String: String], cost: Int?) {
        let points = cost.map { " · \($0) point\($0 == 1 ? "" : "s")" } ?? ""
        guard login != nil else { return log("github: first look, read \(ids.count) PR\(ids.count == 1 ? "" : "s") in full\(points)") }
        let named = ids.map { id -> String in
            let name = prs.first { $0.id == id }?.shortName(mainRepo: mainRepo) ?? "new PR"
            let skipped = countsOnly.removeValue(forKey: id) ?? 0
            let why = reasons[id] == "new" ? "" : " " + (reasons[id] ?? "")
            return name + why + (skipped > 0 ? " after \(skipped) look\(skipped == 1 ? "" : "s") on counts alone" : "")
        }
        let shown = named.count > 4 ? Array(named.prefix(3)) + ["\(named.count - 3) more"] : named
        log("github: read \(ids.count) PR\(ids.count == 1 ? "" : "s") in full (\(shown.joined(separator: ", ")))\(points)")
    }

    private func failed(_ exitCode: Int32) {
        fetching = false
        failures += 1
        if failures > 2 { status = "Can't reach GitHub right now" }
        if failures == 1 {
            log("github: couldn't fetch PRs (gh exit \(exitCode)); backing off")
            account.load()                               // signed out? the customiser will say so
        }
        schedule(in: min(60 * pow(2, Double(failures - 1)), 900))
    }

    private func finish(login newLogin: String, order: [String], details: [String: PullRequest]) {
        fetching = false
        // A different account (signed in or switched in gh): start afresh, no "news" from the swap.
        let switched = login != nil && login?.lowercased() != newLogin.lowercased()
        if switched {
            log("github: now signed in as @\(newLogin)")
            unseen.removeAll()
            lastEvents.removeAll()
            countsOnly.removeAll()
        }
        let first = login == nil || switched
        if failures > 0 { log("github: back online") }
        failures = 0
        let previous = switched ? [] : prs
        let next = order.compactMap { id -> PullRequest? in
            guard var pr = details[id] ?? previous.first(where: { $0.id == id }) else { return nil }
            pr.waitingOnMe = pulses[id]?.waitingOnMe ?? false
            pr.tally = pulses[id]?.tally
            return pr
        }
        let settings = SettingsStore.shared.value
        let events = first ? [] : PRDiff.events(old: previous, new: next, me: newLogin, ignored: Set(settings.prIgnoredAuthors))
        login = newLogin
        prs = next
        let open = next.filter { !$0.waitingOnMe }.count
        status = "Watching \(open) open PR\(open == 1 ? "" : "s") as @\(newLogin)"
        if first { log("github: \(status)" + (rate.map { " (\($0.remaining) of \($0.limit) API points left this hour)" } ?? "")) }
        // PRs that vanished: merged or closed.
        let gone = previous.filter { old in !old.waitingOnMe && !next.contains { $0.id == old.id } }
        if !gone.isEmpty { lookUpClosed(gone) }
        publish(events)
        onChange?()
        schedule(in: nextInterval())
    }

    /// Every minute; every 20 s while your checks run. Slower when the shared budget runs low
    /// (every 5 minutes under 15% left), and a pause until the reset when it's nearly gone.
    func nextInterval() -> TimeInterval {
        var interval: TimeInterval = prs.contains { $0.running && !$0.waitingOnMe } ? 20 : 60
        guard let rate else { return interval }
        if rate.remaining < max(100, rate.limit / 50) {
            interval = max(interval, rate.resetAt.timeIntervalSinceNow + 30)
        } else if rate.remaining < rate.limit * 15 / 100 {
            interval = max(interval, 300)
        }
        return interval
    }

    private func note(_ rate: RateLimit?) {
        guard let rate else { return }
        self.rate = rate
        let low = rate.remaining < rate.limit * 15 / 100
        if low && !lowBudgetLogged {
            log("github: API budget low (\(rate.remaining) of \(rate.limit) left until \(rate.resetAt.formatted(date: .omitted, time: .shortened))); looking less often")
        }
        lowBudgetLogged = low
    }

    private func publish(_ events: [PREvent]) {
        guard !events.isEmpty else { return }
        for event in events {
            lastEvents[event.pr.id] = event
            if event.needsYou { unseen.insert(event.pr.id) }
        }
        log("github: " + events.map { $0.summary(mainRepo: mainRepo) }.joined(separator: "; "))
        onEvents?(events)
        onChange?()
    }

    /// You opened the PR list (or a row): those are seen.
    func markSeen(_ ids: Set<String>? = nil) {
        guard !unseen.isEmpty else { return }
        if let ids { unseen.subtract(ids) } else { unseen.removeAll() }
        onChange?()
    }

    func summary() -> PRSummary {
        PRSummary(prs: prs, unseen: unseen, lastEvents: lastEvents, mainRepo: mainRepo)
    }

    /// Re-runs a GitHub Actions check's failed jobs (others, like hatch/*, open their page instead).
    func rerun(_ check: PullRequest.Check, in pr: PullRequest) {
        guard let url = check.url, let gh = Self.ghPath,
              let match = url.absoluteString.range(of: #"/actions/runs/(\d+)"#, options: .regularExpression) else {
            if let url = check.url { NSWorkspace.shared.open(url) }
            return
        }
        let runID = url.absoluteString[match].split(separator: "/").last.map(String.init) ?? ""
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.run(gh, ["run", "rerun", runID, "--failed", "-R", pr.repo])
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    log("github: re-run \(check.name) on #\(pr.number) " + (result.status == 0 ? "started" : "failed (\(result.status))"))
                    self?.refresh()
                }
            }
        }
    }

    private func lookUpClosed(_ gone: [PullRequest]) {
        guard let gh = Self.ghPath else { return }
        let ids = gone.map { "\"\($0.id)\"" }.joined(separator: ",")
        let query = "query { nodes(ids: [\(ids)]) { ... on PullRequest { id merged state } } }"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.run(gh, ["api", "graphql", "-f", "query=\(query)"])
            let nodes = ((try? JSONSerialization.jsonObject(with: result.output)) as? [String: Any])
                .flatMap { ($0["data"] as? [String: Any])?["nodes"] as? [[String: Any]] } ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let events = gone.compactMap { pr -> PREvent? in
                        guard let node = nodes.first(where: { $0["id"] as? String == pr.id }) else { return nil }
                        return PREvent(pr: pr, kind: node["merged"] as? Bool == true ? .merged : .closed)
                    }
                    self?.publish(events)
                }
            }
        }
    }

    private func schedule(in seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = seconds * 0.1
    }

    nonisolated static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, Data()) }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus, data)
    }

    /// About one point: every PR's last update, latest commit, merge state and check counts.
    static let pulseQuery = """
    query($n: Int!) {
      rateLimit { cost limit remaining resetAt }
      viewer {
        login
        pullRequests(first: $n, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { ...pulse } }
      }
      requested: search(query: "is:pr is:open review-requested:@me archived:false", type: ISSUE, first: 10) {
        nodes { ...pulse }
      }
    }
    fragment pulse on PullRequest {
      id updatedAt mergeStateStatus reviewDecision
      commits(last: 1) { nodes { commit { oid statusCheckRollup { state contexts(first: 1) {
        checkRunCountsByState { state count }
        statusContextCountsByState { state count }
      } } } } }
    }
    """

    /// Full details, only for the PRs whose pulse changed (a few points each).
    static func detailQuery(ids: [String]) -> String {
        "query { rateLimit { cost limit remaining resetAt } nodes(ids: [\(ids.map { "\"\($0)\"" }.joined(separator: ","))]) { ... on PullRequest { ...pr } } }\n"
            + prFragment
    }

    static let prFragment = """
    fragment pr on PullRequest {
      id number title url isDraft updatedAt headRefName author { login }
      repository { nameWithOwner }
      reviewDecision mergeStateStatus
      commits(last: 1) { nodes { commit { oid statusCheckRollup { state contexts(first: 60) { nodes {
        __typename
        ... on CheckRun { name status conclusion detailsUrl }
        ... on StatusContext { context state targetUrl }
      } } } } } }
      reviews(last: 20) { nodes { id author { login } state submittedAt } }
      reviewThreads(first: 100) { nodes { isResolved
        first: comments(first: 1) { nodes { author { login } } }
        latest: comments(last: 1) { nodes { id author { login } body createdAt path url } } } }
      comments(last: 15) { nodes { id author { login } body createdAt url } }
    }
    """
}

// MARK: - Banners

extension PREvent {
    /// What happened, without the PR's name ("flock-review failed", "reviewed by Flock").
    var detail: String {
        switch kind {
        case .checksPassed: "checks passed"
        case .checksFailed(let names): (names.first?.replacingOccurrences(of: "hatch/", with: "") ?? "checks") + " failed"
        case .approved(let who): "approved by \(who)"
        case .changesRequested(let who): "changes requested by \(who)"
        case .reviewed(let who): "reviewed by \(who)"
        case .commented(let who, _, let count): "\(count) comment\(count == 1 ? "" : "s") from \(who)"
        case .readyToMerge: "ready to merge"
        case .merged: "merged"
        case .closed: "closed"
        case .reviewRequested(let who): "review requested by \(who)"
        case .allClear: "approved, all checks passed"
        }
    }
}

/// Which of several events about one PR leads its banner.
private func rank(_ kind: PREvent.Kind) -> Int {
    switch kind {
    case .changesRequested: 0
    case .checksFailed: 1
    case .reviewRequested: 2
    case .commented: 3
    case .allClear: 4
    case .approved: 5
    case .merged: 6
    case .readyToMerge: 7
    case .reviewed: 8
    case .checksPassed: 9
    case .closed: 10
    }
}

/// One banner per look at GitHub: a single event says exactly what happened; several are
/// folded together ("Flock reviewed 3 PRs", "4 PR updates").
enum PRBanner {
    static func banner(for events: [PREvent], mainRepo: String?) -> Banner? {
        guard let first = events.first else { return nil }
        let bad = events.contains(where: \.bad)
        let good = events.allSatisfy {
            switch $0.kind { case .checksPassed, .approved, .readyToMerge, .merged, .allClear: true; default: false }
        }
        let tint: Banner.Tint = bad ? .red : good ? .green : .purple
        if events.count == 1 {
            let pr = first.pr
            let name = pr.shortName(mainRepo: mainRepo)
            switch first.kind {
            case .checksPassed:
                return Banner(symbol: PullRequestIcon.symbolName, tint: .green, title: "Checks passed · \(name)",
                              subtitle: pr.title, accessory: .check, duration: 4)
            case .checksFailed(let names):
                let what = names.count == 1 ? "\(names[0]) failed" : "\(names.count) checks failed"
                return Banner(symbol: PullRequestIcon.symbolName, tint: .red, title: "\(what) · \(name)",
                              subtitle: pr.title, accessory: .cross, duration: 6)
            case .approved(let who):
                // A person approved, but something still has to pass.
                let pending = pr.failedChecks.first.map { "\($0.name) failing" } ?? (pr.running ? "checks still running" : nil)
                return Banner(symbol: PullRequestIcon.symbolName, tint: .purple, title: "\(who) approved · \(name)",
                              subtitle: pending.map { "\($0) · \(pr.title)" } ?? pr.title, duration: 5)
            case .allClear:
                return Banner(symbol: "checkmark.seal.fill", tint: .green, title: "Approved · \(name)",
                              subtitle: "All checks passed · \(pr.title)", accessory: .check, duration: 6)
            case .changesRequested(let who):
                return Banner(symbol: PullRequestIcon.symbolName, tint: .red, title: "\(who) requested changes · \(name)",
                              subtitle: pr.unresolvedThreads > 0 ? "\(pr.unresolvedThreads) open threads · \(pr.title)" : pr.title,
                              duration: 6)
            case .reviewed(let who):
                return Banner(symbol: PullRequestIcon.symbolName, tint: .purple, title: "\(who) reviewed · \(name)",
                              subtitle: pr.title, duration: 5)
            case .commented(let who, let line, let count):
                return Banner(symbol: "text.bubble.fill", tint: .purple,
                              title: count == 1 ? "\(who) commented · \(name)" : "\(count) comments from \(who) · \(name)",
                              subtitle: line.isEmpty ? pr.title : "“\(line)”", duration: 6)
            case .readyToMerge:
                return Banner(symbol: "arrow.triangle.merge", tint: .green, title: "Ready to merge · \(name)",
                              subtitle: pr.title, accessory: .check, duration: 5)
            case .merged:
                return Banner(symbol: "arrow.triangle.merge", tint: .purple, title: "Merged · \(name)",
                              subtitle: pr.title, accessory: .check, duration: 5)
            case .closed:
                return Banner(symbol: "xmark.circle", tint: .white, title: "Closed · \(name)", subtitle: pr.title, duration: 4)
            case .reviewRequested(let who):
                return Banner(symbol: "eye.fill", tint: .purple, title: "Review requested · \(name)",
                              subtitle: "\(who): \(pr.title)", duration: 6)
            }
        }
        // Several about one PR: lead with the most important, the rest underneath.
        if Set(events.map(\.pr.id)).count == 1 {
            let ranked = events.sorted { rank($0.kind) < rank($1.kind) }
            guard var lead = banner(for: [ranked[0]], mainRepo: mainRepo) else { return nil }
            let rest = ranked.dropFirst().map { $0.detail }
            var seen = Set<String>()
            let also = rest.filter { seen.insert($0).inserted }
            lead.subtitle = (["Also " + also.joined(separator: ", ")] + [first.pr.title]).joined(separator: " · ")
            return lead
        }
        // Several: say what they share, if anything.
        let reviewers = Set(events.compactMap { event -> String? in
            switch event.kind {
            case .approved(let who), .changesRequested(let who), .reviewed(let who), .commented(let who, _, _): who
            default: nil
            }
        })
        let prCount = Set(events.map(\.pr.id)).count
        let title: String
        if reviewers.count == 1, events.allSatisfy({ if case .checksPassed = $0.kind { false } else if case .checksFailed = $0.kind { false } else { true } }) {
            title = "\(reviewers.first!) reviewed \(prCount) PR\(prCount == 1 ? "" : "s")"
        } else if events.allSatisfy({ if case .checksFailed = $0.kind { true } else { false } }) {
            title = "Checks failed on \(prCount) PRs"
        } else if events.allSatisfy({ if case .checksPassed = $0.kind { true } else { false } }) {
            title = "Checks passed on \(prCount) PRs"
        } else {
            title = "\(events.count) PR updates"
        }
        return Banner(symbol: PullRequestIcon.symbolName, tint: tint, title: title,
                      subtitle: events.map { $0.summary(mainRepo: mainRepo) }.joined(separator: " · "),
                      accessory: .count(events.count), duration: 6)
    }
}
