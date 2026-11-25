import AppKit
import SwiftUI

struct NotchView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject private var settings: SettingsStore
    @Namespace private var ns

    // What's on screen. Each piece follows the model on its own spring (see Motion),
    // so the shape can grow wide first and then drop down, like the Dynamic Island.
    // Plain State<T> properties rather than @State: on the macOS 27 SDK @State is a
    // macro whose plugin only ships with Xcode, and this builds with the Command Line Tools.
    private let shown: State<NotchState>
    private let width: State<CGFloat>
    private let height: State<CGFloat>
    private let topRadius: State<CGFloat>
    private let bottomRadius: State<CGFloat>
    private let lift: State<Double>          // shadow under the open panel, 0...1
    private let shownBanner: State<Banner?>  // kept while a banner animates away
    private let tint: State<Color>           // the glow colour, cross-faded on its own
    private let bubble: State<CGFloat>       // the second activity's bubble: 0 tucked in … 1 out
    private let bubbleActivity: State<Activity?>   // kept while the bubble tucks away

    init(model: NotchModel, settings: SettingsStore = .shared) {
        _model = ObservedObject(wrappedValue: model)
        _settings = ObservedObject(wrappedValue: settings)
        let state = model.state
        let spec = model.liveLayout.spec(for: state, kind: model.expandedKind)
        shown = State(initialValue: state)
        width = State(initialValue: spec.size.width)
        height = State(initialValue: spec.size.height)
        topRadius = State(initialValue: spec.topRadius)
        bottomRadius = State(initialValue: spec.bottomRadius)
        lift = State(initialValue: Self.lift(for: state))
        shownBanner = State(initialValue: model.displayedBanner)
        tint = State(initialValue: model.ambientTint)
        let second = state == .compact ? model.secondaryActivity : nil
        bubble = State(initialValue: second == nil ? 0 : 1)
        bubbleActivity = State(initialValue: second)
    }

    /// How "lifted" each state is: drives the shadow, the glow and the background's light.
    static func lift(for state: NotchState) -> Double {
        switch state {
        case .expanded: 1
        case .banner: 0.7
        case .compact, .idle: 0
        }
    }

    var body: some View {
        let lift = lift.wrappedValue
        let look = settings.value
        let glowTint = tint.wrappedValue
        let shadow = look.shadow
        let glow = look.tintedGlow && shadow != .off ? 0.32 * lift : 0
        // The pill gets a faint rim too; the bare notch never does (it would outline the camera).
        let edge = look.edgeHighlight && shown.wrappedValue != .idle ? 0.35 + 0.65 * lift : 0

        // One animatable body: fill, light, edge and clip all come from the same interpolated
        // geometry every frame, so they can never drift apart mid-spring.
        IslandBody(width: width.wrappedValue, height: height.wrappedValue,
                   topRadius: topRadius.wrappedValue, bottomRadius: bottomRadius.wrappedValue,
                   bubble: bubble.wrappedValue, bubbleWidth: model.layout.bubbleWidth,
                   bubbleHeight: model.layout.geometry.notchSize.height,
                   background: look.background, tint: glowTint, glow: lift, edge: edge, backdrop: model.cinemaStill) {
            content(for: shown.wrappedValue)
        } bubbleContent: {
            if let second = bubbleActivity.wrappedValue {
                ZStack {
                    BubbleGlyph(activity: second, tint: model.waveformTint)
                    if model.moreActivities > 0 {
                        Text("+\(model.moreActivities)")
                            .font(.system(size: 8, weight: .heavy, design: .rounded))
                            .padding(.horizontal, 3)
                            .background(Capsule().fill(Color.white.opacity(0.22)))
                            .offset(x: 11, y: 11)
                    }
                }
            }
        }
        .compositingGroup()             // one shadow for the whole island, not one per label inside it
        .shadow(color: .black.opacity(shadow.opacity * lift), radius: shadow.radius * lift, y: shadow.drop * lift)
        .shadow(color: glowTint.opacity(glow), radius: 20 * lift, y: 4 * lift)        // coloured glow
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onChange(of: model.state) { old, new in move(from: old, to: new) }
        .onChange(of: model.layout) { old, new in
            if old.geometry != new.geometry { settle(on: model.state) } else { reshape() }
        }
        .onChange(of: model.expandedKind) { resizeExpanded() }
        .onChange(of: model.reappear) { growBackOut() }
        .onChange(of: model.armed) { swell() }
        .onChange(of: model.state == .compact ? model.secondaryActivity : nil) { updateBubble() }
        .onChange(of: model.displayedBanner) { _, new in
            if let new { shownBanner.wrappedValue = new }
        }
        // The glow colour cross-fades on its own; nothing else rides on its animation.
        .onChange(of: model.ambientTint) { _, new in
            withAnimation(Motion.animation(Motion.contentSwap)) { self.tint.wrappedValue = new }
        }
    }

    /// Animate to a new state: content, width and height each on their own curve.
    private func move(from old: NotchState, to new: NotchState) {
        let target = model.liveLayout.spec(for: new, kind: model.expandedKind)
        let curves = Motion.shapeCurves(from: old, to: new)
        withAnimation(Motion.animation(Motion.contentSwap)) {
            shown.wrappedValue = new        // the content transition carries its own timing
        }
        withAnimation(Motion.animation(curves.width)) {
            width.wrappedValue = target.size.width
            topRadius.wrappedValue = target.topRadius
        }
        withAnimation(Motion.animation(curves.height)) {
            height.wrappedValue = target.size.height
            bottomRadius.wrappedValue = target.bottomRadius
            lift.wrappedValue = Self.lift(for: new)
        }
    }

    /// Ready to open (Click / Hover & hold): the shape itself swells a little, like pressing
    /// the island, on the same animated geometry as everything else, so opening carries on
    /// from the swell in one continuous spring (no scaling, nothing fighting).
    private func swell() {
        let state = shown.wrappedValue
        guard model.state == state, state != .expanded else { return }
        let spec = model.liveLayout.spec(for: state, kind: model.expandedKind)
        let extra = model.armed ? CGSize(width: 16, height: 4) : .zero
        withAnimation(Motion.animation(Motion.grow)) {
            width.wrappedValue = spec.size.width + extra.width
            height.wrappedValue = spec.size.height + extra.height
        }
    }

    /// A second activity splits off into a bubble beside the pill (a beat after the pill
    /// settles, like the Dynamic Island), and tucks back in when the island opens or it ends.
    private func updateBubble() {
        let target = model.state == .compact ? model.secondaryActivity : nil
        if let target { bubbleActivity.wrappedValue = target }
        let goal: CGFloat = target == nil ? 0 : 1
        guard goal != bubble.wrappedValue else { return }
        let curve = goal == 1 ? Motion.Curve(spring: Motion.appear.spring, delay: 0.12) : Motion.disappear
        withAnimation(Motion.animation(curve)) { bubble.wrappedValue = goal }
    }

    /// Size or roundness changed in the customiser: spring to the new shape.
    private func reshape() {
        let target = model.liveLayout.spec(for: shown.wrappedValue, kind: model.expandedKind)
        withAnimation(Motion.animation(Motion.appear)) {
            width.wrappedValue = target.size.width
            height.wrappedValue = target.size.height
            topRadius.wrappedValue = target.topRadius
            bottomRadius.wrappedValue = target.bottomRadius
        }
    }

    /// Open, and the content gains or loses its timeline: grow or shrink to fit.
    private func resizeExpanded() {
        guard shown.wrappedValue == .expanded else { return }
        let target = model.liveLayout.spec(for: .expanded, kind: model.expandedKind)
        // A list fitting its content (a PR row opening or closing) moves on the same spring as
        // the row, so the edge and the content travel together; page changes use the shape's own.
        let fitting: Bool = if case .listFit = model.expandedKind { true } else { false }
        let curve = fitting ? Motion.contentSwap
            : target.size.height > height.wrappedValue ? Motion.expandHeight : Motion.collapseHeight
        withAnimation(Motion.animation(curve)) {
            height.wrappedValue = target.size.height
        }
    }

    /// The overlay was just re-placed on a Space: start from the bare notch and grow back
    /// out on the usual springs, so it reads as the island opening rather than a pop-in.
    private func growBackOut() {
        let state = model.state
        guard state != .idle else { return }
        settle(on: .idle)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))   // let the bare notch render first
            move(from: .idle, to: state)
        }
    }

    /// Jump straight to a state (screen changes).
    private func settle(on state: NotchState) {
        let spec = model.liveLayout.spec(for: state, kind: model.expandedKind)
        shown.wrappedValue = state
        width.wrappedValue = spec.size.width
        height.wrappedValue = spec.size.height
        topRadius.wrappedValue = spec.topRadius
        bottomRadius.wrappedValue = spec.bottomRadius
        lift.wrappedValue = Self.lift(for: state)
    }

    /// Each state's content is laid out at that state's final size; the animating shape
    /// reveals or hides it, so nothing reflows mid-animation.
    @ViewBuilder
    private func content(for state: NotchState) -> some View {
        let spec = model.liveLayout.spec(for: state, kind: model.expandedKind)
        let notch = model.layout.geometry.notchSize
        switch state {
        case .idle:
            Color.clear.frame(width: 0, height: 0)
        case .compact:
            // Nothing can go in the middle: that's where the camera is.
            HStack(spacing: 0) {
                CompactLeading(activity: model.compactActivity, ns: ns, wideArtwork: model.compactArtworkWide)
                Spacer(minLength: notch.width)
                CompactTrailing(activity: model.compactActivity, tint: model.waveformTint)
                    .frame(maxWidth: model.liveLayout.compactSideWidth + model.liveLayout.pillExtra - 14, alignment: .trailing)   // never past the pill's edge
            }
            .padding(.horizontal, 12)
            .frame(width: spec.size.width, height: notch.height)
            .animation(Motion.animation(Motion.contentSwap), value: model.compactActivity)
            .transition(Motion.contentTransition)
        case .banner:
            if let banner = shownBanner.wrappedValue ?? model.displayedBanner {
                BannerView(banner: banner, notchHeight: notch.height)
                    .frame(width: spec.size.width, height: spec.size.height)
                    .id(banner.id)                        // the next banner blurs in over this one
                    .transition(Motion.contentTransition)
            }
        case .expanded:
            let kinds = model.pages.map(\.kind)
            let current = model.expandedActivity?.kind
            let isListPage = current == .pullRequests || current == .builds || current == .load || current == .claudeBackground
                || ([.claude, .claudeUpdates].contains(current) && !model.backgroundTasks.isEmpty)
            let wing = (spec.size.width - notch.width) / 2 - 18
            VStack(spacing: 0) {
                // The camera row: free space either side of the camera holds the page switcher.
                HStack(spacing: 0) {
                    if kinds.count > 1 {
                        if CGFloat(kinds.count) * 27 <= wing {
                            PageTabs(pages: kinds, current: current) { kind in
                                withAnimation(Motion.animation(Motion.contentSwap)) { model.select(page: kind) }
                            }
                        } else {
                            PageDots(pages: kinds, current: current) { kind in
                                withAnimation(Motion.animation(Motion.contentSwap)) { model.select(page: kind) }
                            }
                        }
                    }
                    Spacer(minLength: notch.width + 8)
                    if kinds.count > 1, let current {
                        Text(current.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .id(current)
                            .transition(.blurReplace)
                    }
                }
                .padding(.horizontal, 18)
                .frame(height: notch.height)
                ExpandedContent(model: model, activity: model.expandedActivity,
                                openPR: model.prSummary.flatMap(model.openPRRow), copyMenu: model.copyMenuPR,
                                background: model.backgroundTasks, ns: ns)
                    .id(current)                          // a new page slides in, the old one out
                    .transition(PageTransition(step: model.pageStep))
                    .padding(.horizontal, 22)
                    .padding(.top, isListPage ? 2 : 12)
                    .padding(.bottom, 12)
                    // Centred below the camera row; a list (PRs, builds) hangs from the top, so it
                    // stays put while the island grows or shrinks around it.
                    .frame(maxHeight: .infinity, alignment: isListPage ? .top : .center)
            }
            .frame(width: spec.size.width, height: spec.size.height, alignment: .top)   // pinned to the top, always
            .animation(Motion.animation(Motion.contentSwap), value: model.expandedActivity)
            .transition(Motion.contentTransition)
        }
    }
}

/// The island's body: background, content, edge light and clip, all cut from one shape.
/// Its geometry is its animatable data, so SwiftUI hands every part the same in-between
/// values on every frame (rather than animating a layout size and a path separately,
/// which let the fill run ahead of the outline during a spring).
private struct IslandBody<Content: View, Bubble: View>: View, Animatable {
    var width: CGFloat
    var height: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var bubble: CGFloat                   // 0: tucked under the pill's edge … 1: out beside it
    let bubbleWidth: CGFloat
    let bubbleHeight: CGFloat
    let background: BackgroundStyle
    let tint: Color
    let glow: Double
    let edge: Double
    let backdrop: NSImage?                // a video's still, behind the open island
    @ViewBuilder let content: Content
    @ViewBuilder let bubbleContent: Bubble

    nonisolated var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                                   AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>> {
        get { AnimatablePair(AnimatablePair(width, height), AnimatablePair(AnimatablePair(topRadius, bottomRadius), bubble)) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            topRadius = newValue.second.first.first
            bottomRadius = newValue.second.first.second
            bubble = newValue.second.second
        }
    }

    var body: some View {
        let shape = NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                IslandBackground(style: background, tint: tint, glow: glow, backdrop: backdrop)
                content
                EdgeHighlight(shape: shape, strength: edge)
            }
            .frame(width: max(0, width + 2 * topRadius), height: max(0, height), alignment: .top)
            .clipShape(shape)

            if bubble > 0.001 {
                // Splits off the pill's right edge: starts tucked under it, small, and springs out
                // to its place beside it, on the same frame clock as the pill.
                let p = min(max(bubble, 0), 1.2)
                let flare = 5 * min(p, 1)
                let w = bubbleWidth * (0.5 + 0.5 * min(p, 1))
                let h = bubbleHeight * (0.72 + 0.28 * min(p, 1))
                let x = width / 2 + (NotchLayout.bubbleGap + bubbleWidth / 2 + 5) * p - (bubbleWidth / 2 + 5) * (1 - min(p, 1))
                let bubbleShape = NotchShape(topRadius: flare, bottomRadius: min(12, h / 2))
                ZStack {
                    Color.black
                    bubbleContent.opacity(max(0, min(1, p * 1.6 - 0.6)))
                }
                .frame(width: max(0, w + 2 * flare), height: max(0, h))
                .clipShape(bubbleShape)
                .overlay(EdgeHighlight(shape: bubbleShape, strength: edge * min(p, 1)).allowsHitTesting(false))
                .offset(x: x)
            }
        }
    }
}

/// A page sliding in from the side it comes from, softly blurred, as the old one leaves.
private struct PageTransition: Transition {
    var step: Int

    func body(content: Content, phase: TransitionPhase) -> some View {
        let shift: CGFloat = switch phase {
        case .willAppear: 46 * CGFloat(step)
        case .didDisappear: -46 * CGFloat(step)
        case .identity: 0
        }
        content
            .offset(x: shift)
            .blur(radius: phase.isIdentity ? 0 : 6)
            .opacity(phase.isIdentity ? 1 : 0)
    }
}

/// Page dots, when there are more pages than fit as tabs.
/// When the tabs don't fit beside the camera: a dot per page, the current one long. Point at
/// a dot and it opens up on a spring into a small capsule with that page's icon (its
/// neighbours glide aside); click it to go there. Two-finger swipes still turn the pages.
struct PageDots: View {
    let pages: [ActivityKind]
    let current: ActivityKind?
    let select: (ActivityKind) -> Void
    private let hovered: State<ActivityKind?>
    private let leaving = State<ActivityKind?>(initialValue: nil)

    /// `previewHover`: start with that dot open (for previews).
    init(pages: [ActivityKind], current: ActivityKind?, previewHover: ActivityKind? = nil, select: @escaping (ActivityKind) -> Void) {
        self.pages = pages
        self.current = current
        self.select = select
        hovered = State(initialValue: previewHover)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(pages, id: \.self) { kind in
                let isCurrent = kind == current
                let open = hovered.wrappedValue == kind
                let width: CGFloat = open ? 24 : isCurrent ? 14 : 6
                ZStack {
                    Capsule().fill(Color.white.opacity(open ? 0.16 : isCurrent ? 0.9 : 0.3))
                    if open {
                        SymbolImage(kind.symbol, size: 10.5, weight: .bold)
                            .foregroundStyle(Color.white.opacity(isCurrent ? 1 : 0.88))
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .frame(width: width, height: open ? 20 : 6)
                // Each dot owns the gap beside it, so the small ones are easy to point at.
                .frame(width: width + 6, height: 20)
                .contentShape(Rectangle())
                .onHover { inside in point(at: kind, inside) }
                .onTapGesture { select(kind) }
                .accessibilityLabel(kind.title)
                .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
            }
        }
        .animation(.spring(Spring(duration: 0.34, bounce: 0.24)), value: hovered.wrappedValue)
        .animation(UISpring.snap, value: current)
    }

    /// Onto a dot: open it. Off it: close a beat later, unless the pointer has already moved
    /// to the next dot (no flicker while sliding along them).
    private func point(at kind: ActivityKind, _ inside: Bool) {
        if inside {
            leaving.wrappedValue = nil
            hovered.wrappedValue = kind
        } else if hovered.wrappedValue == kind {
            leaving.wrappedValue = kind
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                if leaving.wrappedValue == kind, hovered.wrappedValue == kind {
                    hovered.wrappedValue = nil
                    leaving.wrappedValue = nil
                }
            }
        }
    }
}

// MARK: - Compact

private struct CompactLeading: View {
    let activity: Activity?
    let ns: Namespace.ID
    var wideArtwork = false               // a video's picture: wide, in the same area as the square

    var body: some View {
        switch activity {
        case .timer:
            Image(systemName: "timer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accent(or: .orange))
                .frame(width: 20, height: 20)
                .matchedGeometryEffect(id: "leading", in: ns)
        case let .meeting(meeting):
            MeetingGlyph(meeting: meeting, size: 20)
                .matchedGeometryEffect(id: "leading", in: ns)
        case let .network(trouble):
            NetworkGlyph(trouble: trouble)
                .matchedGeometryEffect(id: "leading", in: ns)
        case let .process(process):
            ProcessGlyph(process: process, size: 20)
                .matchedGeometryEffect(id: "leading", in: ns)
        case let .nowPlaying(nowPlaying):
            Artwork(url: nowPlaying.artworkURL, image: nowPlaying.artworkImage,
                    size: wideArtwork ? CGSize(width: 28, height: 16) : CGSize(width: 20, height: 20), video: wideArtwork)
                .matchedGeometryEffect(id: "leading", in: ns)
        case .claude, .claudeUpdate:
            ClaudeGlyph(size: 20)
                .matchedGeometryEffect(id: "leading", in: ns)
        case let .claudeBackground(tasks):
            BackgroundMark(tasks: tasks)
                .matchedGeometryEffect(id: "leading", in: ns)
        case let .pullRequests(summary):
            PRGlyph(summary: summary)
                .matchedGeometryEffect(id: "leading", in: ns)
        case let .builds(summary):
            BuildMark(summary: summary)
                .matchedGeometryEffect(id: "leading", in: ns)
        case let .load(load):
            LoadPillLeading(load: load)
        case .home:
            EmptyView()
        case nil:
            EmptyView()
        }
    }
}

private struct CompactTrailing: View {
    let activity: Activity?
    var tint: Color = .teal                    // the waveform: album art's colour

    var body: some View {
        switch activity {
        case let .timer(timer):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let label = formatClock(timer.endsAt.timeIntervalSince(context.date))
                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.accent(or: .orange))
                    .contentTransition(.numericText(countsDown: true))   // digits roll
                    .animation(Motion.animation(Motion.contentSwap), value: label)
            }
        case let .meeting(meeting):
            MeetingCountdown(meeting: meeting)
        case let .network(trouble):
            NetworkDownTime(trouble: trouble)
        case let .process(process):
            ProcessLoad(process: process)
        case let .pullRequests(summary):
            PRProgress(summary: summary)
        case let .builds(summary):
            BuildProgress(summary: summary)
        case let .load(load):
            LoadPillTrailing(load: load)
        case .home:
            EmptyView()
        case let .nowPlaying(nowPlaying):
            PlaybackGlyph(playing: nowPlaying.isPlaying, size: 14, tint: tint)
        case .claude:
            PulsingDot(color: .claude)
        case .claudeUpdate:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.green)
        case let .claudeBackground(tasks):
            BackgroundTime(tasks: tasks)
        case nil:
            EmptyView()
        }
    }
}

// MARK: - Expanded

private struct ExpandedContent: View {
    let model: NotchModel
    let activity: Activity?
    let openPR: String?            // an input, so opening a row redraws this (the model alone doesn't)
    var copyMenu: String? = nil    // the same for a row's Copy ▾ list
    var background: [BackgroundTask] = []   // the same for Claude's background work under its page
    let ns: Namespace.ID

    var body: some View {
        switch activity {
        case let .timer(timer):
            TimerExpanded(model: model, timer: timer, ns: ns)
        case let .nowPlaying(nowPlaying):
            NowPlayingExpanded(model: model, nowPlaying: nowPlaying, ns: ns)
        case let .claude(wait):
            claudePage(ClaudeExpanded(title: "Claude needs you", message: wait.message, project: wait.project,
                                      since: wait.since, others: model.claudeWaits.count - 1, finished: false, ns: ns,
                                      host: wait.host, open: { model.openClaudeSession?(wait.sessionID) }) {
                model.dismissClaude()
            })
        case let .claudeBackground(tasks):
            ClaudePage(tasks: tasks, measured: measureClaude) { EmptyView() }
        case let .pullRequests(summary):
            PRsExpanded(summary: summary, open: openPR, toggle: { model.togglePR($0) },
                        copyMenu: copyMenu, toggleCopy: { model.copyMenuPR = $0 },
                        measured: { height in
                            if abs(model.prContentHeight - height) > 0.5 { model.prContentHeight = height }
                        }) { action in
                model.prAction?(action)
            }
        case let .builds(summary):
            BuildsExpanded(summary: summary, server: model.jenkinsServer) { model.buildAction?($0) }
        case let .load(load):
            LoadExpanded(load: load, measured: { height in
                if abs(model.loadContentHeight - height) > 0.5 { model.loadContentHeight = height }
            }) { model.loadQuit?($0) }
        case .home:
            HomeExpanded(model: model)
        case let .meeting(meeting):
            MeetingExpanded(meeting: meeting, ns: ns) { model.meetingAction?($0, meeting) }
        case let .network(trouble):
            NetworkExpanded(trouble: trouble, ns: ns) { model.networkDismiss?() }
        case let .process(process):
            ProcessExpanded(process: process, ns: ns) { action in model.processAction?(action, process) }
        case let .claudeUpdate(update):
            claudePage(ClaudeExpanded(title: update.headline, message: update.message, project: update.project,
                                      since: update.since, others: model.claudeUpdates.count - 1,
                                      finished: update.kind == .finished, ns: ns, host: update.host,
                                      open: update.sessions.count == 1 ? {
                                          model.openClaudeSession?(update.sessions[0])
                                          model.openedClaudeSession(update.sessions[0])
                                      } : nil) {
                model.clearClaudeUpdates()
            })
        case nil:
            HomeExpanded(model: model)
        }
    }

    /// A Claude page, with the background work underneath while there is some.
    @ViewBuilder private func claudePage(_ page: some View) -> some View {
        if background.isEmpty {
            page
        } else {
            ClaudePage(tasks: background, measured: measureClaude) { page }
        }
    }

    private func measureClaude(_ height: CGFloat) {
        if abs(model.claudeContentHeight - height) > 0.5 { model.claudeContentHeight = height }
    }
}

private struct TimerExpanded: View {
    let model: NotchModel
    let timer: TimerInfo
    let ns: Namespace.ID

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, timer.endsAt.timeIntervalSince(context.date))
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(systemName: "timer")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Color.accent(or: .orange))
                        .frame(width: 44, height: 44)
                        .matchedGeometryEffect(id: "leading", in: ns)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Focus timer")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(formatClock(remaining))
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                            .animation(Motion.animation(Motion.contentSwap), value: formatClock(remaining))
                    }
                    Spacer()
                    IconButton(symbol: "plus", label: "Add 5 minutes") { model.addTime(minutes: 5) }
                    IconButton(symbol: "xmark", label: "Stop timer") { model.stopTimer() }
                }
                ProgressBar(fraction: timer.duration > 0 ? 1 - remaining / timer.duration : 1, tint: Color.accent(or: .orange))
            }
        }
    }
}

private struct NowPlayingExpanded: View {
    let model: NotchModel
    let nowPlaying: NowPlaying
    let ns: Namespace.ID

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                let wide = model.wideArtwork(nowPlaying)
                Artwork(url: nowPlaying.artworkURL, image: nowPlaying.artworkImage,
                        size: wide ? CGSize(width: 96, height: 54) : CGSize(width: 52, height: 52), video: wide)
                    .matchedGeometryEffect(id: "leading", in: ns)
                VStack(alignment: .leading, spacing: 3) {
                    Text(nowPlaying.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .id(nowPlaying.title + "\n" + nowPlaying.artist)   // new track: blur from old to new
                .transition(.blurReplace)
                Spacer(minLength: 8)
                PlaybackGlyph(playing: nowPlaying.isPlaying, size: 20, tint: model.waveformTint)
            }
            if nowPlaying.hasTimeline {
                SeekBar(nowPlaying: nowPlaying) { time in model.perform(.seek(to: time)) }
                    .transition(.blurReplace)
            }
            // Transport centred under the panel, play/pause a size up as the main control.
            HStack(spacing: 22) {
                IconButton(symbol: "backward.fill", label: "Previous", enabled: nowPlaying.canSkip) {
                    model.perform(.previoustrack)
                }
                IconButton(symbol: nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                           label: nowPlaying.isPlaying ? "Pause" : "Play", size: 36) { model.togglePlayPause() }
                IconButton(symbol: "forward.fill", label: "Next", enabled: nowPlaying.canSkip) {
                    model.perform(.nexttrack)
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                // Off to the side, so it never pulls the transport off-centre.
                if nowPlaying.origin == .demo && !model.quiet {
                    IconButton(symbol: "xmark", label: "Clear") { model.clearDemoMusic() }
                        .transition(.blurReplace)
                }
            }
        }
    }

    private var subtitle: String {
        [nowPlaying.artist, nowPlaying.source].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Shown when you hover with nothing going on.
private struct HomeExpanded: View {
    let model: NotchModel

    var body: some View {
        HStack(alignment: .center) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.date, format: .dateTime.weekday(.wide).month().day())
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if model.awake.on, let why = model.awake.why {
                        Label(why, systemImage: "cup.and.heat.waves.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.orange.opacity(0.9))
                            .lineLimit(1)
                            .transition(.blurReplace)
                    }
                }
                .animation(Motion.animation(Motion.contentSwap), value: model.awake)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                if SettingsStore.shared.value.timers {
                    PillButton(symbol: "timer", title: "25-min timer") { model.startTimer(minutes: 25) }
                }
                HStack(spacing: 8) {
                    KeepAwakeButton(state: model.awake) { model.toggleKeepAwake?() }
                    PillButton(symbol: "slider.horizontal.3", title: "Customise") { model.openCustomiser?() }
                }
            }
        }
    }
}

// MARK: - Pieces

/// Album art from the site, or a gradient placeholder while it loads (or if there is none).
private struct Artwork: View {
    let url: URL?
    var image: NSImage? = nil
    let size: CGSize
    var video = false                     // a video's picture, wide; a film placeholder

    var body: some View {
        let side = min(size.width, size.height)
        let shape = RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: video ? [Color(white: 0.32), Color(white: 0.16)] : [.teal, .indigo],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: video ? "film" : "music.note")
                .font(.system(size: side * 0.45, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .transition(.opacity)
            } else if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
    }
}

struct Waveform: View {
    let playing: Bool
    let height: CGFloat
    var tint: Color = .teal

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let level = playing ? 0.35 + 0.65 * abs(sin(t * 3.2 + Double(i) * 1.1)) : 0.25
                    Capsule().frame(width: 3, height: height * CGFloat(level))
                }
            }
            .frame(height: height)
            .foregroundStyle(tint)
            .animation(Motion.animation(Motion.contentSwap), value: tint)
        }
    }
}

/// Elapsed and remaining time around a bar with a thumb you can drag, like the island's
/// music controls. Plain playback moves the thumb continuously; anything else (a tap on the
/// bar, grabbing it away from the thumb, a seek, a correction from the browser) makes it
/// glide there on a spring instead of jumping.
struct SeekBar: View {
    let nowPlaying: NowPlaying
    let onSeek: (TimeInterval) -> Void

    /// A glide in progress: from where the thumb was drawn, towards the live target.
    struct Glide: Equatable {
        var from: Double
        var start: Date
    }

    // Plain State<T> rather than @State (see NotchView).
    private let scrub = State<Double?>(initialValue: nil)    // 0...1 under the pointer while dragging
    private let glide = State<Glide?>(initialValue: nil)
    private let hovering = State<Bool>(initialValue: false)
    private let stretch = State<CGFloat>(initialValue: 1)    // thumb stretch from drag speed
    private let lastMove = State<Int>(initialValue: 0)

    init(nowPlaying: NowPlaying, onSeek: @escaping (TimeInterval) -> Void) {
        self.nowPlaying = nowPlaying
        self.onSeek = onSeek
    }

    private var duration: Double { max(nowPlaying.duration ?? 0, 0.001) }

    /// Where the thumb belongs right now, ignoring any glide.
    private func target(at date: Date) -> Double {
        scrub.wrappedValue ?? min(1, max(0, nowPlaying.playhead(at: date) / duration))
    }

    /// Where the thumb is drawn: on its way from `glide.from` to a (possibly moving) target.
    @MainActor static func displayed(target: Double, glide: Glide?, at date: Date) -> Double {
        guard let glide else { return target }
        let t = date.timeIntervalSince(glide.start) / Motion.slowdown
        let progress = t >= Motion.seekGlide.settlingDuration ? 1 : Motion.seekGlide.value(target: 1.0, time: max(0, t))
        return min(1, max(0, glide.from + (target - glide.from) * progress))
    }

    var body: some View {
        let scrubbing = scrub.wrappedValue != nil
        let gliding = glide.wrappedValue.map { Date().timeIntervalSince($0.start) < 1.2 * Motion.slowdown } ?? false
        let smooth = scrubbing || gliding
        // Full frame rate only while something is moving by hand or gliding.
        TimelineView(.animation(minimumInterval: smooth ? nil : 1.0 / 15,
                                paused: !(nowPlaying.isPlaying || smooth))) { context in
            let fraction = Self.displayed(target: target(at: context.date), glide: glide.wrappedValue, at: context.date)
            HStack(spacing: 8) {
                Text(formatElapsed(fraction * duration))
                    .frame(width: 40, alignment: .trailing)
                track(fraction: fraction)
                Text("-" + formatClock(duration - fraction * duration))
                    .frame(width: 44, alignment: .leading)
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(scrubbing ? .primary : .secondary)
        }
        .onChange(of: nowPlaying) { old, new in
            // The playhead moved by more than plain playback (seek, resync, new track): glide.
            let now = Date()
            if let current = glide.wrappedValue, now.timeIntervalSince(current.start) < 0.05 { return }
            guard scrub.wrappedValue == nil else { return }
            let before = old.playhead(at: now), after = new.playhead(at: now)
            guard abs(after - before) > 0.75 else { return }
            let oldDuration = max(old.duration ?? 0, 0.001)
            let drawn = Self.displayed(target: min(1, max(0, before / oldDuration)), glide: glide.wrappedValue, at: now)
            glide.wrappedValue = Glide(from: drawn, start: now)
        }
    }

    private func track(fraction: Double) -> some View {
        GeometryReader { geo in
            let seekable = nowPlaying.canSeek
            let active = seekable && (scrub.wrappedValue != nil || hovering.wrappedValue)
            let bar: CGFloat = active ? 6 : 4
            let inset = SeekThumb.activeSize.width / 2          // the thumb never pokes past the ends
            let usable = max(1, geo.size.width - inset * 2)
            let x = inset + usable * CGFloat(fraction)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                    .frame(width: usable, height: bar)
                    .offset(x: inset)
                Capsule().fill(Color.white.opacity(active ? 1 : 0.9))
                    .frame(width: max(bar, x - inset), height: bar)
                    .offset(x: inset)
                if seekable {
                    SeekThumb(active: active, stretch: stretch.wrappedValue)
                        .position(x: x, y: geo.size.height / 2)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)   // same place with or without a thumb
            .contentShape(Rectangle())
            .gesture(seekable ? drag(usable: usable, inset: inset) : nil)
            .onHover { hovering.wrappedValue = $0 }
            .animation(Motion.animation(Motion.grow), value: active)        // thumb and bar grow
        }
        .frame(height: 20)
    }

    private func drag(usable: CGFloat, inset: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let fraction = Double(min(max((value.location.x - inset) / usable, 0), 1))
                if scrub.wrappedValue == nil {
                    // Pressed somewhere on the bar: glide the thumb to the pointer instead of teleporting.
                    let now = Date()
                    let drawn = Self.displayed(target: target(at: now), glide: glide.wrappedValue, at: now)
                    glide.wrappedValue = Glide(from: drawn, start: now)
                }
                scrub.wrappedValue = fraction
                // Fast drags stretch the thumb along the bar; it springs back as you slow down.
                let target = min(1.4, 1 + abs(value.velocity.width) / 1600)
                withAnimation(.spring(Spring(duration: 0.18, bounce: 0.2)).speed(1 / Motion.slowdown)) {
                    stretch.wrappedValue = target
                }
                lastMove.wrappedValue &+= 1
                let move = lastMove.wrappedValue
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                    guard move == lastMove.wrappedValue else { return }   // still moving
                    withAnimation(Motion.animation(Motion.grow)) { stretch.wrappedValue = 1 }
                }
            }
            .onEnded { value in
                let fraction = Double(min(max((value.location.x - inset) / usable, 0), 1))
                let now = Date()
                // Carry on from wherever the thumb is drawn; the seek lands under it.
                let drawn = Self.displayed(target: fraction, glide: glide.wrappedValue, at: now)
                glide.wrappedValue = Glide(from: drawn, start: now)
                scrub.wrappedValue = nil
                withAnimation(Motion.animation(Motion.grow)) { stretch.wrappedValue = 1 }
                onSeek(fraction * duration)
            }
    }
}

/// The seek thumb: a wide rounded rectangle. It grows under the pointer, and stretches
/// along the bar during a fast drag (keeping roughly the same area, so it reads as
/// squash-and-stretch rather than resizing).
struct SeekThumb: View {
    var active: Bool
    var stretch: CGFloat = 1

    static let restSize = CGSize(width: 22, height: 10)
    static let activeSize = CGSize(width: 30, height: 15)

    var body: some View {
        let base = active ? Self.activeSize : Self.restSize
        let size = CGSize(width: base.width * stretch, height: base.height / stretch.squareRoot())
        let shape = RoundedRectangle(cornerRadius: size.height * 0.42, style: .continuous)
        shape.fill(Color.white)
            .overlay(shape.strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(active ? 0.45 : 0.35), radius: active ? 5 : 2.5, y: active ? 2 : 1)
    }
}

private struct ProgressBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule().fill(tint)
                    .frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    var enabled = true
    var size: CGFloat = 30
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.43, weight: .bold))
                .contentTransition(.symbolEffect(.replace))   // play ⇄ pause morphs
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)                           // dimmed, never removed
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Buttons dip slightly when pressed and spring back, like the island's controls.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .brightness(configuration.isPressed ? 0.15 : 0)
            .animation(Motion.animation(Motion.grow), value: configuration.isPressed)
    }
}

/// The animated waveform while playing; a play icon while paused. They morph into each other.
private struct PlaybackGlyph: View {
    let playing: Bool
    let size: CGFloat
    var tint: Color = .teal

    var body: some View {
        ZStack {
            if playing {
                Waveform(playing: true, height: size, tint: tint)
                    .transition(.blurReplace)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.72, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .transition(.blurReplace)
            }
        }
        .frame(width: size * 1.1, height: size)
        .animation(Motion.animation(Motion.contentSwap), value: playing)
    }
}

struct PillButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                SymbolImage(symbol, size: 11, weight: .bold)
                Text(title)
            }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

/// Countdowns and time remaining: round up, so it never shows 0:00 with time left.
func formatClock(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds).rounded(.up))
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Time elapsed: round down.
func formatElapsed(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds).rounded(.down))
    return String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - Banners

extension Color {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)    // Claude's orange
}

extension Banner.Tint {
    var color: Color {
        switch self {
        case .white: .white
        case .purple: Color(red: 0.6, green: 0.48, blue: 1)
        case .green: .green
        case .red: .red
        case .orange: .orange
        case .claude: .claude
        }
    }
}

/// A brief drop-down: icon, title and subtitle below the camera, and an accessory on the
/// right. The icon bounces in, the accessory animates in, then the island closes.
struct BannerView: View {
    let banner: Banner
    let notchHeight: CGFloat
    private let finished: Bool
    private let appeared: State<Bool>

    /// `finished: true` starts in the end pose (for still renders, which don't run animations).
    init(banner: Banner, notchHeight: CGFloat, finished: Bool = false) {
        self.banner = banner
        self.notchHeight = notchHeight
        self.finished = finished
        appeared = State(initialValue: finished)
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)           // the camera row
            HStack(spacing: 12) {
                SymbolImage(banner.symbol, size: 20)
                    .foregroundStyle(banner.tint.color)
                    .symbolEffect(.bounce, value: appeared.wrappedValue)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(banner.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    // Overlapping, so a subtitle that changes in place (battery levels arriving)
                    // blurs across instead of pushing the old line down.
                    ZStack(alignment: .leading) {
                        if let subtitle = banner.subtitle {
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .id(subtitle)
                                .transition(.blurReplace)
                        }
                    }
                }
                Spacer(minLength: 8)
                BannerAccessory(accessory: banner.accessory, shown: appeared.wrappedValue, instant: finished)
            }
            .padding(.horizontal, 20)
            .frame(maxHeight: .infinity)
            .animation(Motion.animation(Motion.contentSwap), value: banner)
        }
        .task {
            // Let the banner land first, then the icon bounces and the accessory fills in.
            try? await Task.sleep(for: .milliseconds(Int(180 * Motion.slowdown)))
            withAnimation(Motion.animation(Motion.grow)) { appeared.wrappedValue = true }
        }
    }
}

private struct BannerAccessory: View {
    let accessory: Banner.Accessory
    let shown: Bool
    let instant: Bool

    var body: some View {
        switch accessory {
        case .none:
            EmptyView()
        case .check:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.green)
                .scaleEffect(shown ? 1 : 0.3)
                .opacity(shown ? 1 : 0)
        case .cross:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.red)
                .scaleEffect(shown ? 1 : 0.3)
                .opacity(shown ? 1 : 0)
        case let .battery(level, charging):
            // Arriving late (headphone levels) it blurs in, then fills.
            BatteryRing(level: level, charging: charging, filled: shown, instant: instant)
                .transition(.blurReplace)
        case let .count(count):
            // Several Claude updates waiting: the number rolls as more arrive.
            Text("\(count)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.claude)
                .contentTransition(.numericText(value: Double(count)))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.claude.opacity(0.2)))
                .scaleEffect(shown ? 1 : 0.3)
                .opacity(shown ? 1 : 0)
                .transition(.blurReplace)
        }
    }
}

/// Battery level as a ring that fills up to the level, with the percentage inside:
/// green, or red when 20% or lower and not charging.
private struct BatteryRing: View {
    let level: Int
    let charging: Bool
    let filled: Bool
    private let landed: State<Bool>

    /// `instant` draws it already filled (still renders); otherwise it always fills up from
    /// empty, even when it first appears with the level already known.
    init(level: Int, charging: Bool, filled: Bool, instant: Bool = false) {
        self.level = level
        self.charging = charging
        self.filled = filled
        landed = State(initialValue: instant)
    }

    var body: some View {
        let clamped = min(max(level, 0), 100)
        let fraction = filled && landed.wrappedValue ? Double(clamped) / 100 : 0
        let color: Color = clamped <= 20 && !charging ? .red : .green
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 3.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(Spring(duration: 0.9, bounce: 0.1)).speed(1 / Motion.slowdown), value: fraction)
            Text("\(clamped)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(clamped)))
        }
        .frame(width: 32, height: 32)
        .task {
            guard !landed.wrappedValue else { return }
            try? await Task.sleep(for: .milliseconds(Int(60 * Motion.slowdown)))
            landed.wrappedValue = true
        }
    }
}

// MARK: - Claude Code

/// Claude's mark: a sparkle in Claude orange.
private struct ClaudeGlyph: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: size * 0.7, weight: .bold))
            .foregroundStyle(Color.claude)
            .frame(width: size, height: size)
    }
}

/// A dot that breathes while something waits on you.
struct PulsingDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .phaseAnimator([false, true]) { dot, bright in
                dot.scaleEffect(bright ? 1 : 0.65)
                    .opacity(bright ? 1 : 0.45)
                    .shadow(color: color.opacity(bright ? 0.8 : 0), radius: bright ? 4 : 0)
            } animation: { _ in
                .easeInOut(duration: 0.9 * Motion.slowdown)
            }
            .frame(width: 20, height: 20)
    }
}

/// The open notch for Claude: someone needs you, or what finished while you were away.
private struct ClaudeExpanded: View {
    let title: String
    let message: String?
    let project: String?
    let since: Date
    let others: Int
    let finished: Bool             // a green check on the tile
    let ns: Namespace.ID
    var host: String? = nil        // "Claude", "Warp", "Terminal"…
    var open: (() -> Void)? = nil  // to that session
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.claude.opacity(0.18))
                ClaudeGlyph(size: 30)
            }
            .frame(width: 44, height: 44)
            .overlay(alignment: .bottomTrailing) {
                if finished {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .background(Circle().fill(.black).padding(-2))
                        .offset(x: 5, y: 5)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
            .matchedGeometryEffect(id: "leading", in: ns)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if let message {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text([project, ago(since, now: context.date), others > 0 ? "+\(others) more" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 7) {
                if let open {
                    PillButton(symbol: "arrow.up.forward.app", title: "Open in \(host ?? "Claude")", action: open)
                }
                PillButton(symbol: "checkmark", title: "Dismiss", action: dismiss)
            }
        }
    }

    private func ago(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}
