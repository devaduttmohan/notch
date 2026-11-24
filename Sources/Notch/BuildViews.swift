import SwiftUI

extension Color {
    /// Builds in progress: a calm blue (green and red are for how they end).
    static let buildBlue = Color(red: 0.30, green: 0.56, blue: 1.0)
}

/// The builds mark: a hammer inside the progress ring, which fills towards Jenkins' estimate,
/// turns orange once the build is past it, keeps turning on a first run (no estimate) and is
/// dashed while queued. With nothing running it's full and red when one of yours failed and
/// you haven't looked yet; a red dot says the same while another build runs.
struct BuildMark: View {
    let summary: BuildSummary
    var size: CGFloat = 20

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ZStack {
                if let lead = summary.lead {
                    BuildRing(build: lead, now: context.date, lineWidth: max(2, size * 0.11))
                } else {
                    ProgressRing(fraction: 1, color: idleColor, lineWidth: max(2, size * 0.11))
                }
                Image(systemName: "hammer.fill")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if summary.unseenFailure && summary.lead != nil {
                    Circle().fill(Color.red).frame(width: size * 0.32, height: size * 0.32)
                        .overlay(Circle().strokeBorder(Color.black, lineWidth: 1.5))
                        .offset(x: size * 0.1, y: -size * 0.06)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(Motion.animation(Motion.contentSwap), value: summary.unseenFailure)
        }
    }

    /// Nothing running: red for a failure you haven't seen, otherwise how your last build ended.
    private var idleColor: Color {
        if summary.unseenFailure { return .red }
        guard let last = summary.recent.first else { return .buildBlue }
        return last.passed ? .green : last.failed ? Color.red.opacity(0.75) : .buildBlue
    }
}

/// Right of the pill: just the time. Minutes left to Jenkins' estimate; past it, "+2m" in
/// orange counting up; the time so far on a first run; "queued" while it waits; "failed" when
/// one did and nothing else runs.
struct BuildProgress: View {
    let summary: BuildSummary

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let (text, color, down) = label(now)
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .contentTransition(.numericText(countsDown: down))
                .animation(Motion.animation(Motion.contentSwap), value: text)
                .fixedSize()
        }
    }

    private func label(_ now: Date) -> (String, Color, Bool) {
        guard let build = summary.lead else {
            // Nothing running (the section is pinned): how your last build ended.
            if summary.unseenFailure { return ("failed", .red, false) }
            guard let last = summary.recent.first else { return ("", .clear, false) }
            return (last.passed ? "passed" : last.failed ? "failed" : "done", last.passed ? .green : last.failed ? Color.red.opacity(0.85) : .secondary, false)
        }
        if build.queued { return ("queued", Color.white.opacity(0.9), false) }
        if let over = build.overtime(at: now) { return ("+" + MeetingCountdown.short(over), .orange, false) }
        if let left = build.remaining(at: now) { return (MeetingCountdown.short(left), Color.white.opacity(0.9), true) }
        return (MeetingCountdown.short(build.elapsed(at: now)), Color.white.opacity(0.9), false)
    }
}

/// Fills towards the estimate (orange and full once past it); without one, a short arc that
/// keeps turning; dashed while queued.
struct BuildRing: View {
    let build: JenkinsBuild
    let now: Date
    var lineWidth: CGFloat = 2.4

    var body: some View {
        if build.queued {
            Circle().stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: lineWidth, dash: [2, 2.6]))
        } else if build.overtime(at: now) != nil {
            ProgressRing(fraction: 1, color: .orange, lineWidth: lineWidth)
        } else if let progress = build.progress(at: now) {
            ProgressRing(fraction: progress, color: .buildBlue, lineWidth: lineWidth)
        } else {
            ZStack {
                Circle().stroke(Color.white.opacity(0.18), lineWidth: lineWidth)
                Circle().trim(from: 0, to: 0.28)
                    .stroke(Color.buildBlue, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) * 180))
                    .animation(.linear(duration: 1), value: Int(now.timeIntervalSinceReferenceDate))
            }
        }
    }
}

/// The open island: your running builds with their pipeline stages, then the ones that ended.
struct BuildsExpanded: View {
    let summary: BuildSummary
    let server: URL?
    var previewStage: Int? = nil              // previews: start with this stage of the first build hovered
    let open: (URL) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let rows = Array(summary.all.prefix(3))
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(header)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let server {
                        Button { open(server) } label: {
                            Label("Jenkins", systemImage: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(PressableStyle())
                        .foregroundStyle(.secondary)
                    }
                }
                ForEach(rows) { build in
                    BuildRow(build: build, now: context.date, previewStage: build.id == rows.first?.id ? previewStage : nil, open: open)
                        .transition(.blurReplace.combined(with: .opacity))
                }
                if rows.isEmpty {
                    Text("Nothing of yours running. Builds you start in Jenkins show up here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .animation(Motion.animation(Motion.contentSwap), value: rows.map(\.id))
        }
    }

    private var header: String {
        let running = summary.running.count
        if running > 0 { return "\(running) build\(running == 1 ? "" : "s") of yours running" }
        return "Your recent builds"
    }
}

private struct BuildRow: View {
    let build: JenkinsBuild
    let now: Date
    let open: (URL) -> Void
    /// The stage under the pointer on a running build's bar: the line under the bar shows it.
    private let hovered: State<Int?>

    init(build: JenkinsBuild, now: Date, previewStage: Int? = nil, open: @escaping (URL) -> Void) {
        self.build = build
        self.now = now
        self.open = open
        hovered = State(initialValue: previewStage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                status.frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(build.queued ? build.pipeline : build.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(build.failed ? Color.red.opacity(0.9) : .secondary)
                        .lineLimit(1)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 6)
                PillButton(symbol: build.queued ? "arrow.up.right" : "text.alignleft", title: build.queued ? "Open" : "Console") {
                    open(build.queued ? build.url.deletingLastPathComponent() : build.consoleURL)
                }
            }
            if !build.stages.isEmpty || (build.building && !build.queued) {
                VStack(alignment: .leading, spacing: 4) {
                    BuildBar(build: build, now: now, hovered: build.building ? hovered.projectedValue : nil)
                    if build.building && !build.queued && !build.stages.isEmpty { caption }
                }
                .padding(.leading, 28)
                .transition(.opacity)
            }
        }
    }

    /// Under the bar while it runs: the stage it's on and how long it's been on it (or, while
    /// the pointer is on a segment, that stage), and on the right the time left (or how far
    /// past the estimate it is).
    private var caption: some View {
        let index = hovered.wrappedValue.flatMap { build.stages.indices.contains($0) ? $0 : nil }
        let shown = index.map { build.stages[$0] } ?? build.currentStage
        return HStack(spacing: 6) {
            if let stage = shown {
                Group {
                    StageMarker(stage: stage)
                    Text(stage.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(stage.failed ? Color.red.opacity(0.9) : Color.white.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(stageDetail(stage))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .fixedSize()
                }
                .id(stage.name)                       // another stage: blur across to it
                .transition(.asymmetric(insertion: AnyTransition(.blurReplace).combined(with: .offset(y: 3)),
                                        removal: AnyTransition(.blurReplace)))
            }
            Spacer(minLength: 8)
            Text(timeLeft)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(build.overtime(at: now) != nil ? Color.orange : .secondary)
                .contentTransition(.numericText(countsDown: build.overtime(at: now) == nil))
                .fixedSize()
        }
        .animation(Motion.animation(Motion.contentSwap), value: shown?.name)
    }

    /// The running stage's time so far (or "waiting for input"); a finished one's time.
    private func stageDetail(_ stage: JenkinsBuild.Stage) -> String {
        if stage.running {
            let time = build.stageTime(at: now).map(CommandAlerts.duration) ?? ""
            return stage.status == "PAUSED_PENDING_INPUT" ? "waiting for input · " + time : time
        }
        if stage.status == "NOT_EXECUTED" { return "not run" }
        return CommandAlerts.duration(stage.duration)
    }

    private var timeLeft: String {
        if let over = build.overtime(at: now) { return "over by \(MeetingCountdown.short(over))" }
        if let left = build.remaining(at: now) { return "~\(MeetingCountdown.short(left)) left" }
        return "first run, no estimate"
    }

    @ViewBuilder private var status: some View {
        if build.building {
            BuildRing(build: build, now: now, lineWidth: 2.4).frame(width: 15, height: 15)
        } else if build.passed {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(.green)
        } else {
            Image(systemName: build.result == "ABORTED" ? "stop.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 15)).foregroundStyle(build.result == "UNSTABLE" ? .orange : .red)
        }
    }

    private var subtitle: String {
        if build.queued { return "Waiting for an executor · \(CommandAlerts.duration(now.timeIntervalSince(build.started)))" }
        let elapsed = CommandAlerts.duration(build.elapsed(at: now))
        if build.building {
            guard build.estimated > 0 else { return elapsed + " so far" }
            let total = elapsed + " of ~" + CommandAlerts.duration(build.estimated)
            guard build.overtime(at: now) == nil, let left = build.remaining(at: now) else { return total }
            return total + " · done ~" + now.addingTimeInterval(left).formatted(date: .omitted, time: .shortened)
        }
        let ago = build.finishedAt.map { " · " + Self.ago(now.timeIntervalSince($0)) } ?? ""
        if build.passed { return "Passed in \(elapsed)\(ago)" }
        let verb = build.result == "ABORTED" ? "Aborted" : build.result == "UNSTABLE" ? "Unstable" : "Failed"
        return verb + (build.failedStage.map { " at \($0.name)" } ?? "") + " after \(elapsed)\(ago)"
    }

    static func ago(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        let days = Int(seconds / 86_400)
        return days == 1 ? "yesterday" : "\(days) days ago"
    }
}

/// Where a build is. Its stages as segments as wide as each one took (green done, blue
/// running and growing, red failed), then the rest of Jenkins' estimate as a dim track:
/// Jenkins only lists the stages that have started, so the estimate is what says how far
/// along it really is. Without stages (a freestyle job) it's one bar filling towards the
/// estimate; on a first run (no estimate) it breathes rather than make up a fill.
struct BuildBar: View {
    let build: JenkinsBuild
    let now: Date
    /// Set while the pointer is on a stage (running builds): it lifts, the others dim.
    var hovered: Binding<Int?>? = nil
    private let leaving = State<Int?>(initialValue: nil)

    private struct Piece: Identifiable {
        let id: Int
        let width: CGFloat
        let color: Color
        let live: Bool
        let help: String?
    }

    var body: some View {
        GeometryReader { geo in
                let pieces = layout(width: geo.size.width)
                let current = hovered?.wrappedValue
                HStack(spacing: 2) {
                    ForEach(pieces) { piece in
                        let isStage = piece.id < build.stages.count
                        Capsule()
                            .fill(piece.color)
                            .frame(width: piece.width)
                            .overlay {
                                if piece.live {
                                    Capsule().fill(Color.white.opacity(0.45))
                                        .phaseAnimator([0.0, 1.0]) { glow, phase in glow.opacity(phase) }
                                            animation: { _ in .easeInOut(duration: 0.9 * Motion.slowdown) }
                                }
                            }
                            // The one under the pointer lifts and brightens; the rest step back.
                            .scaleEffect(y: current == piece.id ? 1.75 : 1, anchor: .center)
                            .brightness(current == piece.id ? 0.12 : 0)
                            .opacity(current == nil || current == piece.id ? 1 : 0.45)
                            .overlay {
                                if hovered != nil && isStage {
                                    // A taller strip than the 4 pt bar, so it's easy to point at.
                                    Color.clear.frame(height: 18).contentShape(Rectangle())
                                        .onHover { inside in point(at: piece.id, inside) }
                                }
                            }
                            .help(hovered == nil ? (piece.help ?? "") : "")
                    }
                }
                .animation(.spring(Spring(duration: 0.32, bounce: 0.18)), value: current)
                .frame(width: geo.size.width, alignment: .leading)
                .animation(.linear(duration: 1), value: pieces.map(\.width))      // glides between the seconds
        }
        .frame(height: 4)
    }

    private var elapsed: TimeInterval { build.elapsed(at: now) }

    /// Onto a stage: show it. Off it: back to the current stage a beat later, unless the pointer
    /// has moved onto the next one in the meantime (no flicker between neighbours).
    private func point(at index: Int, _ inside: Bool) {
        guard let hovered else { return }
        if inside {
            leaving.wrappedValue = nil
            hovered.wrappedValue = index
        } else if hovered.wrappedValue == index {
            leaving.wrappedValue = index
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                if leaving.wrappedValue == index, hovered.wrappedValue == index {
                    hovered.wrappedValue = nil
                    leaving.wrappedValue = nil
                }
            }
        }
    }

    /// Segment widths: each stage by how long it took (the running one up to now), the rest of
    /// the estimate as track. Short stages keep a sliver so none disappears.
    private func layout(width: CGFloat) -> [Piece] {
        let track = Color.white.opacity(0.14)
        let stages = build.stages
        if stages.isEmpty {
            guard build.building, build.estimated > 0 else {
                return [Piece(id: 0, width: width, color: Color.buildBlue.opacity(build.building ? 0.55 : 0.85), live: build.building, help: nil)]
            }
            let done = min(width, max(4, width * CGFloat(elapsed / max(build.estimated, elapsed))))
            return [Piece(id: 0, width: done, color: .buildBlue, live: false, help: nil),
                    Piece(id: 1, width: max(0, width - done - 2), color: track, live: false, help: nil)]
        }
        // How long each stage took (the running one, so far). The stages share the part of the
        // bar for the time gone (stage times needn't add up to it: there are gaps between
        // them); the rest of the estimate is the track. Past the estimate there's no track.
        let running = build.stageTime(at: now) ?? 0
        let times = stages.map { $0.running && build.building ? running : $0.duration }
        let stageTotal = max(times.reduce(0, +), 1)
        let doneShare = build.building && build.estimated > elapsed ? elapsed / build.estimated : 1
        let trackShown = doneShare < 0.99
        // Every piece keeps a 3 pt sliver, set aside first so the whole bar always fits.
        let count = CGFloat(stages.count + (trackShown ? 1 : 0))
        let gaps = (count - 1) * 2
        let free = max(0, width - gaps - 3 * count)
        let scale = free * CGFloat(doneShare) / CGFloat(stageTotal)
        var pieces = stages.enumerated().map { index, stage in
            Piece(id: index, width: 3 + CGFloat(times[index]) * scale, color: Self.color(stage),
                  live: stage.running && build.building,
                  help: "\(stage.name): \(stage.status.lowercased().replacingOccurrences(of: "_", with: " ")), \(CommandAlerts.duration(times[index]))")
        }
        if trackShown {
            let used = pieces.reduce(0) { $0 + $1.width } + gaps
            pieces.append(Piece(id: stages.count, width: max(3, width - used), color: track, live: false, help: nil))
        }
        return pieces
    }

    static func color(_ stage: JenkinsBuild.Stage) -> Color {
        Self.stageColor(stage)
    }

    static func stageColor(_ stage: JenkinsBuild.Stage) -> Color {
        switch stage.status {
        case "SUCCESS": .green.opacity(0.85)
        case "IN_PROGRESS", "PAUSED_PENDING_INPUT": .buildBlue
        case "FAILED": .red
        case "UNSTABLE": .orange
        case "ABORTED": Color(white: 0.55)
        default: Color.white.opacity(0.22)
        }
    }
}

/// The small mark before a stage's name: a blue dot while it runs (orange waiting for input),
/// a tick when it passed, a cross when it failed, a hollow dot when it didn't run.
struct StageMarker: View {
    let stage: JenkinsBuild.Stage

    var body: some View {
        Group {
            switch stage.status {
            case "SUCCESS":
                Image(systemName: "checkmark").font(.system(size: 7.5, weight: .heavy)).foregroundStyle(.green)
            case "FAILED", "ABORTED":
                Image(systemName: "xmark").font(.system(size: 7.5, weight: .heavy)).foregroundStyle(.red)
            case "UNSTABLE":
                Image(systemName: "exclamationmark").font(.system(size: 7.5, weight: .heavy)).foregroundStyle(.orange)
            case "IN_PROGRESS", "PAUSED_PENDING_INPUT":
                Circle().fill(stage.status == "PAUSED_PENDING_INPUT" ? Color.orange : Color.buildBlue).frame(width: 5, height: 5)
            default:
                Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1).frame(width: 5, height: 5)
            }
        }
        .frame(width: 8, height: 8)
    }
}
