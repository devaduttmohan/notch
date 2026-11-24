import SwiftUI

// Claude's background work in the notch. Claude Code says what's running, not how far along it
// is or how long it'll take, so the ring only turns (like a build with no estimate) and the
// time counts up from when Notch saw it start.

/// A short Claude-orange arc turning on a faint track: working, with no claim to progress.
struct TurningRing: View {
    var color: Color = .claude
    var lineWidth: CGFloat = 2.4
    private let turning = State(initialValue: false)

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: lineWidth)
            Circle().trim(from: 0, to: 0.28)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(turning.wrappedValue ? 360 : 0))
                .animation(.linear(duration: 1.6 * Motion.slowdown).repeatForever(autoreverses: false), value: turning.wrappedValue)
        }
        .onAppear { turning.wrappedValue = true }
    }
}

/// Left of the pill: the turning ring around Claude's mark, and "+2" for the rest (the way the
/// side bubble counts what else is going on).
struct BackgroundMark: View {
    let tasks: [BackgroundTask]
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            TurningRing(lineWidth: max(2, size * 0.11))
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if tasks.count > 1 {
                Text("+\(tasks.count - 1)")
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .background(Capsule().fill(Color.white.opacity(0.22)))
                    .fixedSize()
                    .offset(x: size * 0.45, y: size * 0.25)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(Motion.animation(Motion.contentSwap), value: tasks.count)
    }
}

/// Right of the pill: how long the oldest one has been running (as Builds shows its time).
struct BackgroundTime: View {
    let tasks: [BackgroundTask]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let oldest = tasks.compactMap(\.started).min()
            let text = oldest.map { Self.elapsed(context.date.timeIntervalSince($0)) } ?? ""
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.9))
                .contentTransition(.numericText())
                .animation(Motion.animation(Motion.contentSwap), value: text)
                .fixedSize()
        }
    }

    /// Time so far, rounded down (the countdowns' short form rounds up): "45s", "6m", "1h 5m".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }
}

/// Under Claude's page (or on its own): what's running in the background, like the Builds
/// page's rows. Three at most, then "and 2 more".
struct BackgroundSection: View {
    let tasks: [BackgroundTask]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let rows = Array(tasks.prefix(3))
            VStack(alignment: .leading, spacing: 8) {
                Text("\(tasks.count) running in the background")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                ForEach(rows) { task in
                    BackgroundRow(task: task, now: context.date)
                        .transition(.blurReplace.combined(with: .opacity))
                }
                if tasks.count > rows.count {
                    Text("and \(tasks.count - rows.count) more")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 28)
                }
            }
            .animation(Motion.animation(Motion.contentSwap), value: tasks.map(\.id))
        }
    }
}

private struct BackgroundRow: View {
    let task: BackgroundTask
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            TurningRing().frame(width: 15, height: 15).frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 6)
        }
    }

    /// "Notch · agent · 6m 10s so far", or "running" when it was already going as Notch saw it.
    private var subtitle: String {
        let time = task.started.map { CommandAlerts.duration(now.timeIntervalSince($0)) + " so far" } ?? "running"
        return [task.project, task.kindName, time].joined(separator: " · ")
    }
}

/// Claude's page with its background work underneath, measured so the island fits it.
struct ClaudePage<Top: View>: View {
    let tasks: [BackgroundTask]
    let measured: (CGFloat) -> Void
    @ViewBuilder let top: Top

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            top
            if !tasks.isEmpty {
                BackgroundSection(tasks: tasks)
                    .transition(.blurReplace.combined(with: .opacity))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in measured(height) }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(Motion.animation(Motion.contentSwap), value: tasks.isEmpty)
    }
}
