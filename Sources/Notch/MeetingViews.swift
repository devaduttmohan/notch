import AppKit
import SwiftUI

/// The meeting's mark in the pill and the bubble: a frosted glass tile with a camera (a
/// calendar page when there's no call to join) in the calendar's colour.
struct MeetingGlyph: View {
    let meeting: Meeting
    let size: CGFloat

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        tile
            .fill(LinearGradient(colors: [Color.white.opacity(0.19), Color.white.opacity(0.10)], startPoint: .top, endPoint: .bottom))
            .overlay(tile.strokeBorder(Color.white.opacity(0.2), lineWidth: 0.6))
            .overlay {
                MeetingIcon(video: meeting.joinURL != nil, filled: true)
                    .frame(width: size * 0.6, height: size * 0.6)
                    .foregroundStyle(meeting.color.readableOnDark)
            }
            .frame(width: size, height: size)
    }
}

extension RGB {
    /// The colour, lifted towards white if it's too dark to read on the dark glass.
    var readableOnDark: Color {
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        guard luminance < 0.42 else { return color }
        let lift = min(0.6, (0.42 - luminance) * 1.6)
        return Color(red: red + (1 - red) * lift, green: green + (1 - green) * lift, blue: blue + (1 - blue) * lift)
    }
}

/// Right side of the pill: a ring and the minutes, counting down to the start (orange in
/// the last minute), then the time left once it's under way.
struct MeetingCountdown: View {
    let meeting: Meeting

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let live = meeting.isLive(at: now)
            let seconds = live ? meeting.end.timeIntervalSince(now) : meeting.start.timeIntervalSince(now)
            let label = Self.short(seconds)
            let urgent = !live && seconds <= 60
            let color: Color = urgent ? .orange : live ? meeting.color.color : .white
            HStack(spacing: 4) {
                ProgressRing(fraction: live ? meeting.progress(at: now) : 1 - min(seconds / 600, 1),
                             color: color, lineWidth: 2.2)
                    .frame(width: 12, height: 12)
                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(urgent ? Color.orange : Color.white.opacity(0.9))
                    .contentTransition(.numericText(countsDown: true))
                    .animation(Motion.animation(Motion.contentSwap), value: label)
            }
            .fixedSize()
        }
    }

    /// "12m", "45s", "1h 5m" without the "1h", it never fits.
    static func short(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "\(Int(seconds.rounded(.up)))s" }
        return "\(Int((seconds / 60).rounded(.up)))m"
    }
}

/// A little Calendar-app style day tile: the month in the calendar's colour, the day big.
struct DateTile: View {
    let date: Date
    let color: Color

    var body: some View {
        VStack(spacing: 0) {
            Text(date, format: .dateTime.month(.abbreviated))
                .font(.system(size: 10, weight: .bold))
                .textCase(.uppercase)
                .foregroundStyle(color)
            Text(date, format: .dateTime.day())
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: 44, height: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.1)))
    }
}

/// The open island for a meeting: what, when, where, and a big Join. Underneath, Dismiss and
/// Skip meeting (once it's under way: its progress, and Dismiss for the rest of it).
struct MeetingExpanded: View {
    let meeting: Meeting
    let ns: Namespace.ID
    let act: (MeetingAction) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let live = meeting.isLive(at: now)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    DateTile(date: meeting.start, color: meeting.color.color)
                        .matchedGeometryEffect(id: "leading", in: ns)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meeting.title)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Text(when(now: now))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .animation(Motion.animation(Motion.contentSwap), value: when(now: now))
                        Text(meeting.service ?? meeting.location ?? meeting.calendar)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let url = meeting.joinURL {
                        JoinButton(prominent: meeting.prominent) { NSWorkspace.shared.open(url) }
                    } else {
                        PillButton(symbol: MeetingIcon.calendarName, title: "Open") { Meetings.openCalendarApp() }
                    }
                }
                HStack(spacing: 8) {
                    if live {
                        MeetingProgress(meeting: meeting, now: now)
                            .transition(.blurReplace)
                    } else {
                        Spacer()
                    }
                    PillButton(symbol: "checkmark", title: "Dismiss") { act(.dismiss) }
                        .help(live ? "Hide it for the rest of the meeting" : "Hide it until the meeting starts")
                    if !live {
                        PillButton(symbol: "bell.slash.fill", title: "Skip meeting") { act(.skip) }
                            .help("Not joining: no reminder when it starts, nothing while it runs")
                            .transition(.blurReplace)
                    }
                }
            }
            .animation(Motion.animation(Motion.contentSwap), value: live)
        }
    }

    private func when(now: Date) -> String {
        let range = meeting.start.formatted(date: .omitted, time: .shortened) + " – "
            + meeting.end.formatted(date: .omitted, time: .shortened)
        if meeting.isLive(at: now) { return range + " · now" }
        let seconds = meeting.start.timeIntervalSince(now)
        if seconds <= 60 { return range + " · starting" }
        return range + " · in " + CommandAlerts.duration((seconds / 60).rounded(.up) * 60)
    }
}

/// Green, with a soft pulse while the meeting is about to start.
struct JoinButton: View {
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                MeetingIcon(video: true, filled: true).frame(width: 15, height: 15)
                Text("Join")
            }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color(red: 0.19, green: 0.78, blue: 0.35).gradient))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .phaseAnimator(prominent ? [false, true] : [false]) { button, bright in
            button.shadow(color: Color.green.opacity(bright ? 0.7 : 0), radius: bright ? 10 : 0)
        } animation: { _ in .easeInOut(duration: 1.1 * Motion.slowdown) }
        .help("Join the call")
    }
}

/// Elapsed and remaining time of a meeting under way.
private struct MeetingProgress: View {
    let meeting: Meeting
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Text(formatElapsed(now.timeIntervalSince(meeting.start)))
                .frame(width: 40, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule().fill(meeting.color.color)
                        .frame(width: geo.size.width * CGFloat(meeting.progress(at: now)))
                }
            }
            .frame(height: 5)
            Text("-" + formatClock(meeting.end.timeIntervalSince(now)))
                .frame(width: 44, alignment: .leading)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
}

/// A thin ring that fills clockwise.
struct ProgressRing: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.animation(Motion.contentSwap), value: fraction)
        }
    }
}

extension Meeting {
    func progress(at date: Date) -> Double {
        let length = end.timeIntervalSince(start)
        guard length > 0 else { return 1 }
        return min(max(date.timeIntervalSince(start) / length, 0), 1)
    }
}
