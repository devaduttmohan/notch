import AppKit
import SwiftUI

extension Color {
    static let prPurple = Color(red: 0.6, green: 0.48, blue: 1)
}

/// Left of the pill: the pull-request mark, with a red dot when something's new.
struct PRGlyph: View {
    let summary: PRSummary
    var size: CGFloat = 20

    var body: some View {
        PullRequestIcon()
            .frame(width: size * 0.8, height: size * 0.8)
            .foregroundStyle(Color.prGreen)
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if summary.needsYou {
                    Circle().fill(Color.red).frame(width: size * 0.36, height: size * 0.36)
                        .overlay(Circle().strokeBorder(Color.black, lineWidth: 1.5))
                        .offset(x: size * 0.12, y: -size * 0.08)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(Motion.animation(Motion.contentSwap), value: summary.needsYou)
    }
}

/// Right of the pill: checks filling a ring ("9/14"), or how many PRs have news.
struct PRProgress: View {
    let summary: PRSummary

    var body: some View {
        // The pill's wing is narrow: the widest version that fits wins (ring + "10/11",
        // then "10/11", then the ring alone), so it never spills past the island's edge.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { ring; label }
            label
            ring
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .animation(Motion.animation(Motion.contentSwap), value: summary.checksDone)
    }

    @ViewBuilder private var ring: some View {
        if summary.checksTotal > 0 {
            ProgressRing(fraction: Double(summary.checksDone) / Double(max(summary.checksTotal, 1)),
                         color: .orange, lineWidth: 2.2)
                .frame(width: 12, height: 12)
        } else if summary.unseen.isEmpty {
            EmptyView()
        } else {
            Circle().fill(Color.red).frame(width: 7, height: 7)
        }
    }

    @ViewBuilder private var label: some View {
        if summary.checksTotal > 0 {
            Text("\(summary.checksDone)/\(summary.checksTotal)")
                .contentTransition(.numericText(value: Double(summary.checksDone)))
                .fixedSize()
        } else if summary.unseen.isEmpty {
            // Pinned with nothing running or new: how many you have on the go.
            Text("\(summary.thisWeek.filter { !$0.waitingOnMe }.count) open")
                .foregroundStyle(Color.white.opacity(0.85))
                .fixedSize()
        } else {
            Text("\(summary.unseen.count) new")
                .foregroundStyle(Color.red.opacity(0.95))
                .contentTransition(.numericText(value: Double(summary.unseen.count)))
                .fixedSize()
        }
    }
}

/// What sits in the bubble beside the pill: one small mark per kind of activity.
struct BubbleGlyph: View {
    let activity: Activity
    var tint: Color = .teal

    var body: some View {
        Group {
            switch activity {
            case let .nowPlaying(nowPlaying):
                ZStack {
                    if nowPlaying.isPlaying {
                        Waveform(playing: true, height: 13, tint: tint)
                    } else {
                        Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                    }
                }
            case let .pullRequests(summary):
                if summary.checksTotal > 0 {
                    ProgressRing(fraction: Double(summary.checksDone) / Double(max(summary.checksTotal, 1)),
                                 color: summary.needsYou ? .red : .orange, lineWidth: 2.6)
                        .frame(width: 15, height: 15)
                } else {
                    PRGlyph(summary: summary, size: 17)
                }
            case let .builds(summary):
                BuildMark(summary: summary, size: 17)
            case let .load(load):
                LoadBubble(load: load)
            case let .meeting(meeting):
                MeetingGlyph(meeting: meeting, size: 18)
            case let .timer(timer):
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ProgressRing(fraction: 1 - max(0, timer.endsAt.timeIntervalSince(context.date)) / max(timer.duration, 1),
                                 color: Color.accent(or: .orange), lineWidth: 2.6)
                        .frame(width: 15, height: 15)
                }
            case .claude:
                PulsingDot(color: .claude)
            case let .process(process):
                ProcessGlyph(process: process, size: 18)
            case .claudeUpdate, .home:
                EmptyView()
            }
        }
        .foregroundStyle(.white)
    }
}

/// The open island's page switcher, in the camera row: a tab per live activity on the
/// left (the current one in a lit capsule that slides), the page name on the right.
struct PageTabs: View {
    let pages: [ActivityKind]
    let current: ActivityKind?
    let select: (ActivityKind) -> Void
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 3) {
            ForEach(pages, id: \.self) { kind in
                let selected = kind == current
                SymbolImage(kind.symbol, size: 10.5, weight: .bold)
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.45))
                    .frame(width: 24, height: 20)
                    .background {
                        if selected {
                            Capsule().fill(Color.white.opacity(0.16))
                                .matchedGeometryEffect(id: "tab", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture { select(kind) }
                    .help(kind.title)
            }
        }
        .animation(UISpring.snap, value: current)
    }
}

/// The open island's PR page: a header, then your PRs with what's new first. A row opens in
/// place to show what failed, the latest word from reviewers, and what you can do.
struct PRsExpanded: View {
    let summary: PRSummary
    let open: String?                      // the open row (the model keeps it, so the island can grow to fit)
    let toggle: (String) -> Void
    var copyMenu: String? = nil            // the row whose Copy ▾ list is open
    var toggleCopy: (String?) -> Void = { _ in }
    var measured: (CGFloat) -> Void = { _ in }
    let act: (PRAction) -> Void

    var body: some View {
        let listed = summary.thisWeek
        let visible = Array(listed.prefix(4))      // the same rows whether or not one is open
        let moreThisWeek = listed.count - visible.count
        let older = summary.older.count
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(header)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { act(.open(URL(string: "https://github.com/pulls")!)) } label: {
                    Label("All on GitHub", systemImage: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(PressableStyle())
                .foregroundStyle(.secondary)
            }
            ForEach(visible) { pr in
                PRRow(pr: pr, summary: summary, opened: pr.id == open, copyOpen: pr.id == open && pr.id == copyMenu,
                      setCopyOpen: { open in toggleCopy(open ? pr.id : nil) }, act: act) {
                    withAnimation(Motion.animation(Motion.contentSwap)) { toggle(pr.id) }
                }
            }
            if listed.isEmpty {
                Text("Nothing in the last 7 days").font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 10)
            }
            if moreThisWeek > 0 || older > 0 {
                Button { act(.open(URL(string: "https://github.com/pulls")!)) } label: {
                    Text([moreThisWeek > 0 ? "+\(moreThisWeek) more" : nil,
                          older > 0 ? "+\(older) older" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(PressableStyle())
                .padding(.leading, 10)
                .help("Your pull requests on GitHub")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in measured(height) }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, -2)
    }

    private var header: String {
        var parts = ["\(summary.thisWeek.filter { !$0.waitingOnMe }.count) in the last 7 days"]
        if !summary.unseen.isEmpty { parts.append("\(summary.unseen.count) new") }
        if !summary.running.isEmpty { parts.append("\(summary.running.count) running") }
        let waiting = summary.prs.filter(\.waitingOnMe).count
        if waiting > 0 { parts.append("\(waiting) to review") }
        return parts.joined(separator: " · ")
    }
}

private struct PRRow: View {
    let pr: PullRequest
    let summary: PRSummary
    let opened: Bool
    /// The Copy ▾ list under the buttons (the model keeps it, so the island grows to fit and it
    /// closes with the island).
    let copyOpen: Bool
    let setCopyOpen: (Bool) -> Void
    let act: (PRAction) -> Void
    let toggle: () -> Void
    /// What was just copied: the button says so for a moment.
    private let copied = State<PRCopyFormat?>(initialValue: nil)

    private func copy(_ format: PRCopyFormat) {
        PRCopy.copy(format, pr)
        Haptics.tap(.generic)
        withAnimation(Motion.animation(Motion.contentSwap)) {
            setCopyOpen(false)
            copied.wrappedValue = format
        }
        let shown = copied
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(Motion.animation(Motion.contentSwap)) { if shown.wrappedValue == format { shown.wrappedValue = nil } }
        }
    }

    var body: some View {
        let new = summary.unseen.contains(pr.id)
        let event = summary.lastEvents[pr.id]
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                status
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pr.title)
                        .font(.system(size: 12.5, weight: new ? .semibold : .medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(opened ? 180 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            if opened {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(pr.failedChecks.prefix(2), id: \.name) { check in
                        Label("\(check.name) failed", systemImage: "xmark.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.red.opacity(0.9))
                            .lineLimit(1)
                    }
                    if pr.openFlockThreads > 0 {
                        Label("\(pr.openFlockLabel) open Flock comment\(pr.openFlockThreads == 1 && !pr.threadsCapped ? "" : "s")",
                              systemImage: "text.bubble")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.prPurple)
                            .lineLimit(1)
                    }
                    if let line = detail(event) {
                        Text(line)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        PillButton(symbol: "arrow.up.right", title: "Open") { act(.open(pr.url)) }
                        PillButton(symbol: "doc.text.magnifyingglass", title: "Details") { act(.details(pr)) }
                            .help(pr.failedChecks.first.map { "\($0.name): the failed check's page" } ?? "The PR's checks")
                        CopyButton(open: copyOpen, copied: copied.wrappedValue) {
                            withAnimation(Motion.animation(Motion.contentSwap)) { setCopyOpen(!copyOpen) }
                        }
                        // A failed GitHub Actions run can be re-run from here.
                        if let failed = pr.failedChecks.first, failed.url?.absoluteString.contains("/actions/runs/") == true {
                            IconButton(symbol: "arrow.clockwise", label: "Re-run failed jobs", size: 28) { act(.rerun(failed, pr)) }
                        }
                    }
                    if copyOpen {
                        CopyMenu(pr: pr) { format in copy(format) }
                            .transition(.blurReplace.combined(with: .scale(0.96, anchor: .topLeading)))
                    }
                }
                .padding(.leading, 28)
                .transition(.blurReplace)
            }
        }
        // Right-click any row (open or not) for the same choices.
        .contextMenu {
            Button { act(.open(pr.url)) } label: { Label("Open on GitHub", systemImage: "arrow.up.right") }
            Button { act(.details(pr)) } label: { Label("Details", systemImage: "doc.text.magnifyingglass") }
            Divider()
            ForEach(PRCopyFormat.available(for: pr)) { format in
                Button { copy(format) } label: { Label(format.menuTitle, systemImage: format.symbol) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, opened ? 7 : 4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(opened ? 0.09 : 0)))
        // An accordion: the details are revealed by the row's own growing edge (and tucked away
        // by it), never drawn over the rows below while they make room.
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private var status: some View {
        if pr.running {
            ProgressRing(fraction: Double(pr.checksDone) / Double(max(pr.checksTotal, 1)), color: .orange, lineWidth: 2.4)
                .padding(2)
        } else if summary.unseen.contains(pr.id), case .checksFailed = summary.lastEvents[pr.id]?.kind {
            Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.red)
        } else if summary.unseen.contains(pr.id) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
        } else if pr.waitingOnMe {
            Image(systemName: "eye.circle.fill").font(.system(size: 16)).foregroundStyle(Color.prPurple)
        } else if pr.approved {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(.green)
        } else if !pr.failedChecks.isEmpty {
            Image(systemName: "xmark.circle").font(.system(size: 15)).foregroundStyle(Color.red.opacity(0.75))
        } else {
            PullRequestIcon().frame(width: 13, height: 13).foregroundStyle(Color.prGreen.opacity(0.85))
        }
    }

    private var subtitle: String {
        var parts = [pr.shortName(mainRepo: summary.mainRepo)]
        if let ticket = pr.ticket, !pr.title.contains(ticket) { parts.append(ticket) }   // your titles often lead with it
        if pr.waitingOnMe { parts.append("review requested" + (pr.author.map { " by \($0)" } ?? "")) }
        else if pr.running { parts.append("checks \(pr.checksDone)/\(pr.checksTotal)") }
        else if pr.approved { parts.append("approved by " + pr.approvers.joined(separator: ", ")) }
        else if let failed = pr.failedChecks.first {
            parts.append(failed.name.replacingOccurrences(of: "hatch/", with: "") + " failing")
        }
        else if pr.reviewDecision == "CHANGES_REQUESTED" { parts.append("changes requested") }
        else if pr.approvers.isEmpty { parts.append("awaiting review") }
        if pr.openFlockThreads > 0 { parts.append("Flock: \(pr.openFlockLabel) open") }
        if pr.isDraft { parts.append("draft") }
        return parts.joined(separator: " · ")
    }

    private func detail(_ event: PREvent?) -> String? {
        if let event, case let .commented(who, line, count) = event.kind {
            return "\(who): \(line.isEmpty ? "\(count) new comment\(count == 1 ? "" : "s")" : "“\(line)”")"
                + (pr.unresolvedThreads > 0 ? " · \(pr.unresolvedThreads) open threads" : "")
        }
        if let event { return event.summary(mainRepo: summary.mainRepo) }
        let others = pr.unresolvedThreads - pr.openFlockThreads
        if others > 0 { return "\(others) other open review thread\(others == 1 ? "" : "s")" }
        if !pr.approvers.isEmpty, !pr.approved { return "Approved by \(pr.approvers.joined(separator: ", ")), waiting on checks" }
        return nil
    }
}

/// Copy ▾ in an open PR row: opens the list of formats; for a moment after copying it reads
/// "✓ Copied" in green.
private struct CopyButton: View {
    let open: Bool
    let copied: PRCopyFormat?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                SymbolImage(copied == nil ? "doc.on.doc" : "checkmark", size: 11, weight: .bold)
                    .contentTransition(.symbolEffect(.replace))
                Text(copied == nil ? "Copy" : "Copied")
                    .contentTransition(.interpolate)
                if copied == nil {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .heavy))
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .transition(.blurReplace)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(copied == nil ? Color.white : Color.green)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(copied == nil ? Color.white.opacity(open ? 0.22 : 0.14) : Color.green.opacity(0.2)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .animation(Motion.animation(Motion.contentSwap), value: copied)
        .animation(Motion.animation(Motion.contentSwap), value: open)
        .help(copied.map { "Copied the \($0.title.lowercased())" } ?? "Copy the link, title, branch or Markdown")
    }
}

/// The formats, each with what it will copy underneath. Part of the row (the island grows to
/// fit), so it never hangs over the rows below or off the island's edge.
private struct CopyMenu: View {
    let pr: PullRequest
    let pick: (PRCopyFormat) -> Void

    var body: some View {
        VStack(spacing: 1) {
            ForEach(PRCopyFormat.available(for: pr)) { format in
                CopyMenuItem(format: format, preview: PRCopy.preview(format, pr)) { pick(format) }
            }
        }
        .padding(4)
        .frame(maxWidth: 330, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.6))
    }
}

private struct CopyMenuItem: View {
    let format: PRCopyFormat
    let preview: String
    let action: () -> Void
    private let hovered = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                SymbolImage(format.symbol, size: 11, weight: .semibold)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(format.title).font(.system(size: 12, weight: .semibold))
                    Text(preview).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(hovered.wrappedValue ? 0.12 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovered.wrappedValue = inside } }
    }
}
