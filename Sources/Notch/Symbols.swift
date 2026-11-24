import SwiftUI

extension Color {
    /// GitHub's open pull request green.
    static let prGreen = Color(red: 0.247, green: 0.725, blue: 0.314)
}

/// GitHub's pull request mark (after the git-pull-request octicon): two rings joined by a
/// line on the left; on the right a ring whose line rises and turns left into an arrow.
/// Drawn as vector paths on a 16-point grid, so it's sharp at any size and takes the
/// surrounding foreground colour like an SF Symbol.
struct PullRequestIcon: View {
    nonisolated static let symbolName = "notch.pullrequest"

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                PullRequestStrokes()
                    .stroke(style: StrokeStyle(lineWidth: side / 16 * 1.55, lineCap: .round, lineJoin: .round))
                PullRequestArrow()
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct PullRequestStrokes: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        let origin = CGPoint(x: rect.midX - 8 * s, y: rect.midY - 8 * s)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * s, y: origin.y + y * s) }
        func ring(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: origin.x + (x - 1.75) * s, y: origin.y + (y - 1.75) * s, width: 3.5 * s, height: 3.5 * s)
        }
        var path = Path()
        // Left: the branch, two rings joined by a line.
        path.addEllipse(in: ring(3.75, 3.25))
        path.move(to: p(3.75, 5.0))
        path.addLine(to: p(3.75, 11.0))
        path.addEllipse(in: ring(3.75, 12.75))
        // Right: a ring, its line rising and turning left towards the arrow.
        path.addEllipse(in: ring(12.25, 12.75))
        path.move(to: p(12.25, 11.0))
        path.addLine(to: p(12.25, 5.75))
        path.addQuadCurve(to: p(9.75, 3.25), control: p(12.25, 3.25))
        path.addLine(to: p(8.6, 3.25))
        return path
    }
}

private struct PullRequestArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        let origin = CGPoint(x: rect.midX - 8 * s, y: rect.midY - 8 * s)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * s, y: origin.y + y * s) }
        var path = Path()
        path.move(to: p(6.3, 3.25))
        path.addLine(to: p(9.2, 0.9))
        path.addLine(to: p(9.2, 5.6))
        path.closeSubpath()
        return path
    }
}

/// An SF Symbol by name, or Notch's own drawn marks (the pull request icon) by theirs.
struct SymbolImage: View {
    let name: String
    let size: CGFloat
    var weight: Font.Weight = .semibold

    init(_ name: String, size: CGFloat, weight: Font.Weight = .semibold) {
        self.name = name
        self.size = size
        self.weight = weight
    }

    var body: some View {
        if name == PullRequestIcon.symbolName {
            PullRequestIcon().frame(width: size * 1.1, height: size * 1.1)
        } else if name.hasPrefix("notch.meeting.") {
            MeetingIcon(video: name.hasPrefix(MeetingIcon.videoName), filled: name.hasSuffix(".fill"))
                .frame(width: size * 1.15, height: size * 1.15)
        } else {
            Image(systemName: name).font(.system(size: size, weight: weight))
        }
    }
}

/// Notch's meeting marks, in the same hand as the pull request icon (16-point grid, round
/// strokes): a video camera for calls, a calendar page for meetings without a link.
/// `filled` is for small tiles and buttons, where solid shapes read better than lines.
struct MeetingIcon: View {
    nonisolated static let videoName = "notch.meeting.video"
    nonisolated static let calendarName = "notch.meeting.calendar"

    var video = true
    var filled = false

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let line = side / 16 * 1.55
            ZStack {
                if video {
                    if filled {
                        MeetingVideoBody().fill()
                        MeetingVideoLens(inset: 0.9).fill()
                    } else {
                        MeetingVideoBody().stroke(style: StrokeStyle(lineWidth: line, lineJoin: .round))
                        MeetingVideoLens(inset: 0).stroke(style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                    }
                } else {
                    MeetingCalendarPage().stroke(style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                    if filled { MeetingCalendarHeader().fill() }
                    MeetingCalendarDot().fill()
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A point on the 16-point grid, centred in `rect`.
private func grid(_ rect: CGRect) -> (CGFloat, CGFloat) -> CGPoint {
    let s = min(rect.width, rect.height) / 16
    let x0 = rect.midX - 8 * s, y0 = rect.midY - 8 * s
    return { x, y in CGPoint(x: x0 + x * s, y: y0 + y * s) }
}

private func gridRect(_ rect: CGRect, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    let s = min(rect.width, rect.height) / 16
    return CGRect(x: rect.midX + (x - 8) * s, y: rect.midY + (y - 8) * s, width: w * s, height: h * s)
}

private struct MeetingVideoBody: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        return Path(roundedRect: gridRect(rect, 1.1, 4.0, 9.6, 8.0), cornerRadius: 2.4 * s, style: .continuous)
    }
}

private struct MeetingVideoLens: Shape {
    var inset: CGFloat                    // a gap from the body, for the filled version
    func path(in rect: CGRect) -> Path {
        let p = grid(rect)
        var path = Path()
        path.move(to: p(10.7 + inset, 6.6))
        path.addLine(to: p(13.6, 4.9))
        path.addQuadCurve(to: p(14.9, 5.6), control: p(14.9, 4.4))
        path.addLine(to: p(14.9, 10.4))
        path.addQuadCurve(to: p(13.6, 11.1), control: p(14.9, 11.6))
        path.addLine(to: p(10.7 + inset, 9.4))
        path.closeSubpath()
        return path
    }
}

private struct MeetingCalendarPage: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        let p = grid(rect)
        var path = Path(roundedRect: gridRect(rect, 1.75, 2.9, 12.5, 11.35), cornerRadius: 2.7 * s, style: .continuous)
        path.move(to: p(1.75, 6.5)); path.addLine(to: p(14.25, 6.5))             // the header line
        path.move(to: p(5.2, 1.25)); path.addLine(to: p(5.2, 4.2))               // binding pegs
        path.move(to: p(10.8, 1.25)); path.addLine(to: p(10.8, 4.2))
        return path
    }
}

private struct MeetingCalendarHeader: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        var path = Path()
        path.addPath(Path(roundedRect: gridRect(rect, 1.75, 2.9, 12.5, 3.6),
                          cornerRadii: RectangleCornerRadii(topLeading: 2.7 * s, bottomLeading: 0, bottomTrailing: 0, topTrailing: 2.7 * s),
                          style: .continuous))
        return path
    }
}

private struct MeetingCalendarDot: Shape {
    func path(in rect: CGRect) -> Path {
        Path(ellipseIn: gridRect(rect, 6.7, 9.0, 2.6, 2.6))
    }
}
