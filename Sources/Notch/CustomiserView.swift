import ServiceManagement
import SwiftUI

// MARK: - Live preview

/// Drives the customiser's preview island: its own quiet model, set up in scenes
/// (music, the player, a meeting, a banner…), optionally touring through them.
@MainActor final class PreviewDirector: ObservableObject {
    enum Scene: String, CaseIterable, Identifiable {
        case idle, music, player, meeting, join, banner, claude
        var id: Self { self }
        var title: String {
            [.idle: "Idle", .music: "Music", .player: "Player", .meeting: "Meeting",
             .join: "Join", .banner: "Banner", .claude: "Claude"][self]!
        }
    }

    let model: NotchModel
    @Published private(set) var scene: Scene = .player
    @Published var touring = false {
        didSet { touring ? startTour() : stopTour() }
    }
    private var tour: Timer?
    private static let tourOrder: [Scene] = [.music, .player, .banner, .meeting, .join, .claude, .idle]
    private static let artwork = PreviewArtwork.image()

    init() {
        model = NotchModel(layout: NotchLayout.current())
        model.quiet = true
        show(.player)
    }

    func show(_ scene: Scene) {
        self.scene = scene
        model.hovering = false
        model.dismissBanner()
        model.clearClaudeUpdates()
        model.meeting = nil
        switch scene {
        case .idle:
            model.clearDemoMusic()
        case .music:
            playMusic()
        case .player:
            playMusic()
            model.hovering = true
        case .meeting:
            model.clearDemoMusic()
            model.meeting = Self.sampleMeeting(startsIn: 4 * 60 - 5, prominent: false)
        case .join:
            model.clearDemoMusic()
            model.meeting = Self.sampleMeeting(startsIn: 55, prominent: true)
            model.hovering = true
        case .banner:
            playMusic()
            model.show(Banner(symbol: "airpodspro", title: "AirPods Pro", subtitle: "L 80% · R 75% · Case 40%",
                              accessory: .battery(level: 75, charging: false), duration: 3600))
        case .claude:
            model.clearDemoMusic()
            model.claudeUpdate(ClaudeUpdate(kind: .finished, sessions: ["preview"], headline: "Claude finished",
                                            project: "Notch", message: "Added the customiser and meetings"))
        }
    }

    /// Replays the current scene from the bare notch, to watch the motion again.
    func replay() {
        let current = scene
        show(.idle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55 * Motion.slowdown) { [weak self] in
            MainActor.assumeIsolated { self?.show(current == .idle ? .player : current) }
        }
    }

    private func playMusic() {
        model.updatePlayer("demo", NowPlaying(title: "Midnight City", artist: "M83", source: "Preview",
                                              artworkURL: nil, artworkImage: Self.artwork, isPlaying: true,
                                              canSkip: true, canSeek: true, duration: 243, position: 71, origin: .demo))
    }

    private static func sampleMeeting(startsIn seconds: TimeInterval, prominent: Bool) -> Meeting {
        Meeting(id: "preview", title: "Design review", start: Date().addingTimeInterval(seconds),
                end: Date().addingTimeInterval(seconds + 30 * 60), calendar: "Work",
                color: RGB(red: 0.2, green: 0.55, blue: 1), location: nil,
                joinURL: URL(string: "https://meet.google.com/abc-defg-hij"), service: "Google Meet",
                prominent: prominent)
    }

    private func startTour() {
        tour?.invalidate()
        advance()
        tour = Timer.scheduledTimer(withTimeInterval: 2.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
    }

    private func stopTour() {
        tour?.invalidate()
        tour = nil
    }

    private func advance() {
        let order = Self.tourOrder
        let next = order[((order.firstIndex(of: scene) ?? -1) + 1) % order.count]
        show(next)
    }
}

/// Album art for the preview track: a warm sunset, so the Ambient glow has colour to show.
enum PreviewArtwork {
    @MainActor static func image() -> NSImage? {
        let art = ZStack {
            LinearGradient(colors: [Color(red: 1, green: 0.42, blue: 0.36), Color(red: 0.55, green: 0.18, blue: 0.72)],
                           startPoint: .top, endPoint: .bottom)
            Circle().fill(Color(red: 1, green: 0.8, blue: 0.4)).frame(width: 34, height: 34).offset(y: 14)
            Rectangle().fill(Color(red: 0.12, green: 0.05, blue: 0.25)).frame(height: 30).offset(y: 34)
        }
        .frame(width: 96, height: 96)
        .clipped()
        let renderer = ImageRenderer(content: art)
        renderer.scale = 2
        return renderer.nsImage
    }
}

/// A desktop strip for the preview: wallpaper, a menu bar, and the island over the notch.
struct PreviewStage: View {
    @ObservedObject var director: PreviewDirector
    static let height: CGFloat = 268

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .top) {
                Wallpaper()
                MenuBarStrip(height: director.model.layout.geometry.notchSize.height)
                NotchView(model: director.model)
            }
            .frame(height: Self.height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.5), radius: 16, y: 8)

            HStack(spacing: 6) {
                ForEach(PreviewDirector.Scene.allCases) { scene in
                    SceneChip(title: scene.title, selected: director.scene == scene) {
                        director.touring = false
                        director.show(scene)
                    }
                }
                Spacer(minLength: 4)
                SceneChip(title: director.touring ? "Touring" : "Tour", symbol: director.touring ? "pause.fill" : "play.fill",
                          selected: director.touring) { director.touring.toggle() }
            }
        }
    }
}

private struct SceneChip: View {
    let title: String
    var symbol: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(title).font(.system(size: 11.5, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? Color.black : Color.white.opacity(0.75))
            .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .animation(UISpring.snap, value: selected)
    }
}

/// A soft macOS-style wallpaper.
private struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.22), Color(red: 0.16, green: 0.07, blue: 0.24)],
                           startPoint: .top, endPoint: .bottom)
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    Ellipse().fill(Color(red: 0.98, green: 0.45, blue: 0.32)).frame(width: w * 0.55, height: h * 0.7)
                        .offset(x: -w * 0.3, y: h * 0.42)
                    Ellipse().fill(Color(red: 0.58, green: 0.26, blue: 0.88)).frame(width: w * 0.6, height: h * 0.8)
                        .offset(x: w * 0.15, y: h * 0.5)
                    Ellipse().fill(Color(red: 0.13, green: 0.47, blue: 0.96)).frame(width: w * 0.45, height: h * 0.6)
                        .offset(x: w * 0.38, y: h * 0.2)
                }
                .frame(width: w, height: h)
                .blur(radius: 46)
                .opacity(0.85)
            }
        }
    }
}

/// A pretend menu bar, so the island sits where it does on screen.
private struct MenuBarStrip: View {
    let height: CGFloat

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "applelogo").font(.system(size: 12, weight: .semibold))
            Text("Notch").font(.system(size: 12, weight: .bold))
            Spacer()
            Image(systemName: "wifi").font(.system(size: 11, weight: .semibold))
            Image(systemName: "battery.75percent").font(.system(size: 12))
            Text(Date(), format: .dateTime.weekday(.abbreviated).hour().minute()).font(.system(size: 12))
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 14)
        .frame(height: height)
        .background(Color.black.opacity(0.2))
    }
}

// MARK: - Window content

enum Pane: String, CaseIterable, Identifiable {
    case appearance, motion, behaviour, modules, meetings, about
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var symbol: String {
        [.appearance: "paintbrush.pointed.fill", .motion: "wand.and.stars", .behaviour: "cursorarrow.click.2",
         .modules: "square.grid.2x2.fill", .meetings: MeetingIcon.calendarName + ".fill", .about: "info"][self]!
    }
    var color: Color {
        [.appearance: Color(red: 0.62, green: 0.32, blue: 0.95), .motion: Color(red: 1, green: 0.27, blue: 0.5),
         .behaviour: Color(red: 0.04, green: 0.52, blue: 1), .modules: Color(red: 0.18, green: 0.72, blue: 0.75),
         .meetings: Color(red: 1, green: 0.3, blue: 0.25), .about: Color(white: 0.45)][self]!
    }
    var subtitle: String {
        [.appearance: "Background, light, depth and shape.",
         .motion: "How the island springs, and how fast.",
         .behaviour: "How it opens, and how it responds.",
         .modules: "Choose what the island shows.",
         .meetings: "Your next meeting, one click from joining.",
         .about: "Notch, on this Mac."][self]!
    }
    /// The preview scene that shows this pane off best.
    var scene: PreviewDirector.Scene? {
        [.appearance: .player, .motion: .player, .behaviour: .music, .modules: .music, .meetings: .join][self]
    }
}

struct CustomiserView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var meetings: Meetings
    @ObservedObject var keepAwake: KeepAwake
    @ObservedObject var prs: PRWatcher
    @ObservedObject var director: PreviewDirector
    @ObservedObject var login: LoginItem
    @ObservedObject var updater = Updater.shared
    private let pane: State<Pane>
    private let appeared: State<Bool>
    @Namespace private var ns

    /// Asks an open customiser to show a pane (the menu bar's "Update to …").
    static let showPane = Notification.Name("dev.notch.customiser.showPane")

    /// `animateIn: false` starts with everything in place (still renders).
    init(store: SettingsStore, meetings: Meetings, keepAwake: KeepAwake, prs: PRWatcher, director: PreviewDirector,
         login: LoginItem, startOn: Pane = .appearance, animateIn: Bool = true) {
        _prs = ObservedObject(wrappedValue: prs)
        _store = ObservedObject(wrappedValue: store)
        _meetings = ObservedObject(wrappedValue: meetings)
        _keepAwake = ObservedObject(wrappedValue: keepAwake)
        _director = ObservedObject(wrappedValue: director)
        _login = ObservedObject(wrappedValue: login)
        pane = State(initialValue: startOn)
        appeared = State(initialValue: !animateIn)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 216)
                .background(Palette.sidebar)
            Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
            detail
        }
        .background(Palette.window)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .tint(Palette.tint)
        .onAppear {
            withAnimation(UISpring.soft.delay(0.05)) { appeared.wrappedValue = true }
            if let scene = pane.wrappedValue.scene { director.show(scene) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.showPane)) { note in
            // The same as clicking it in the sidebar (its preview scene too).
            if let wanted = (note.object as? String).flatMap(Pane.init(rawValue:)) { select(wanted) }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                AppIconArt().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Notch").font(.system(size: 15, weight: .bold))
                    Text("Customise").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 18)
            ForEach(Pane.allCases) { item in
                let selected = item == pane.wrappedValue
                HStack(spacing: 10) {
                    IconTile(symbol: item.symbol, color: item.color, size: 24)
                    Text(item.title).font(.system(size: 13, weight: selected ? .semibold : .medium))
                    Spacer()
                    if item == .about && updater.hasUpdate {
                        Circle().fill(Palette.blue).frame(width: 7, height: 7)
                            .transition(.scale.combined(with: .opacity))
                            .help("A new version of Notch is available")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.1))
                            .matchedGeometryEffect(id: "selection", in: ns)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { select(item) }
                .opacity(appeared.wrappedValue ? 1 : 0)
                .offset(x: appeared.wrappedValue ? 0 : -12)
                .animation(UISpring.soft.delay(0.03 * Double(Pane.allCases.firstIndex(of: item) ?? 0)),
                           value: appeared.wrappedValue)
            }
            Spacer()
            Text("Changes apply instantly.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiary)
                .padding(.horizontal, 10)
        }
        .padding(.top, 46)
        .padding(.bottom, 16)
        .padding(.horizontal, 10)
    }

    private func select(_ item: Pane) {
        guard item != pane.wrappedValue else { return }
        withAnimation(UISpring.snap) { pane.wrappedValue = item }
        if let scene = item.scene {
            director.touring = false
            director.show(scene)
        }
    }

    private var detail: some View {
        let current = pane.wrappedValue
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(current.title).font(.system(size: 24, weight: .bold))
                Text(current.subtitle).font(.system(size: 13)).foregroundStyle(Palette.secondary)
            }
            .id(current)
            .transition(.blurReplace)
            .padding(.horizontal, 26)
            .padding(.bottom, 16)

            if current != .about {
                PreviewStage(director: director)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }

            ScrollView {
                paneContent(current)
                    .id(current)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)), removal: .opacity))
                    .padding(.horizontal, 26)
                    .padding(.vertical, 14)
            }
            .scrollIndicators(.never)
        }
        .padding(.top, 40)
        .animation(UISpring.soft, value: current)
    }

    @ViewBuilder
    private func paneContent(_ pane: Pane) -> some View {
        switch pane {
        case .appearance: AppearancePane(store: store)
        case .motion: MotionPane(store: store, director: director)
        case .behaviour: BehaviourPane(store: store, login: login, keepAwake: keepAwake)
        case .modules: ModulesPane(store: store, prs: prs)
        case .meetings: MeetingsPane(store: store, meetings: meetings)
        case .about: AboutPane(store: store)
        }
    }
}

// MARK: - Appearance

struct AppearancePane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        let tint = store.value.accent.color ?? Color(red: 0.95, green: 0.45, blue: 0.5)
        VStack(spacing: 14) {
            NCard(title: "Background", symbol: "circle.lefthalf.filled") {
                HStack(spacing: 10) {
                    ForEach(BackgroundStyle.allCases) { style in
                        ChoiceTile(title: style.name, detail: style.detail, selected: store.value.background == style,
                                   tint: Palette.tint, action: { store.value.background = style }) {
                            MiniIsland(style: style, tint: tint)
                        }
                    }
                }
            }
            NCard(title: "Accent", symbol: "paintpalette.fill") {
                NRow(title: "Colour", detail: "Automatic gives each activity its own colour: album art, Claude orange, your calendar's colour.") {
                    EmptyView()
                }
                AccentPicker(selection: $store.value.accent)
            }
            NCard(title: "Depth", symbol: "square.3.layers.3d") {
                NRow(title: "Shadow", detail: "Under the open island and banners.") {
                    NSegmented(selection: $store.value.shadow,
                               options: ShadowStyle.allCases.map { ($0, $0.name) })
                        .frame(width: 340)
                }
                NRow(title: "Coloured glow", detail: "The shadow picks up the island's colour.") {
                    NToggle(isOn: $store.value.tintedGlow, tint: Palette.tint)
                }
                NRow(title: "Edge highlight", detail: "A hairline of light along the lower edge.") {
                    NToggle(isOn: $store.value.edgeHighlight, tint: Palette.tint)
                }
            }
            NCard(title: "Shape", symbol: "capsule.portrait") {
                NRow(title: "Size", detail: "How wide the pill and the open island get.") {
                    NSegmented(selection: $store.value.size, options: IslandSize.allCases.map { ($0, $0.name) })
                        .frame(width: 260)
                }
                NRow(title: "Corner roundness", detail: "\(Int((store.value.roundness * 100).rounded()))%") {
                    NSlider(value: $store.value.roundness, range: 0.7...1.3, step: 0.05, tint: Palette.tint)
                        .frame(width: 260)
                }
            }
        }
    }
}

/// A tiny island lit in one background style, for the style tiles.
struct MiniIsland: View {
    let style: BackgroundStyle
    let tint: Color

    var body: some View {
        let shape = NotchShape(topRadius: 6, bottomRadius: 16)
        ZStack(alignment: .top) {
            IslandBackground(style: style, tint: tint, glow: 1, topFade: 12)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tint.gradient).frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(Color.white.opacity(0.9)).frame(width: 38, height: 4)
                    Capsule().fill(Color.white.opacity(0.4)).frame(width: 26, height: 3)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
        }
        .frame(width: 118, height: 52)
        .clipShape(shape)
        .overlay(EdgeHighlight(shape: shape, strength: 1))
        .shadow(color: tint.opacity(style == .midnight ? 0 : 0.35), radius: 8, y: 2)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Motion

struct MotionPane: View {
    @ObservedObject var store: SettingsStore
    let director: PreviewDirector

    var body: some View {
        VStack(spacing: 14) {
            NCard(title: "Personality", symbol: "sparkles") {
                HStack(spacing: 10) {
                    ForEach(MotionStyle.allCases) { style in
                        ChoiceTile(title: style.name, detail: style.detail, selected: store.value.motion == style,
                                   tint: Palette.tint, action: {
                                       store.value.motion = style
                                       director.replay()
                                   }) {
                            SpringDemo(style: style, tint: Palette.tint)
                        }
                    }
                }
            }
            NCard(title: "Speed", symbol: "speedometer") {
                NRow(title: "Animation speed", detail: String(format: "%.1f×", store.value.speed)) {
                    HStack(spacing: 10) {
                        Image(systemName: "tortoise.fill").foregroundStyle(Palette.tertiary)
                        NSlider(value: $store.value.speed, range: 0.6...1.6, step: 0.1, tint: Palette.tint)
                            .frame(width: 220)
                        Image(systemName: "hare.fill").foregroundStyle(Palette.tertiary)
                    }
                    .font(.system(size: 12))
                }
                HStack {
                    Spacer()
                    NButton(title: "Replay", symbol: "arrow.counterclockwise") { director.replay() }
                }
            }
            NCard(title: "Content", symbol: "square.stack.3d.up.fill") {
                NRow(title: "Content effect", detail: "How things appear inside the island.") {
                    NSegmented(selection: $store.value.contentEffect, options: ContentEffect.allCases.map { ($0, $0.name) })
                        .frame(width: 240)
                }
                NRow(title: "Reduce motion", detail: "No overshoot; content fades. Follows Accessibility by default.") {
                    NSegmented(selection: $store.value.reduceMotion, options: ReduceMotion.allCases.map { ($0, $0.name) })
                        .frame(width: 250)
                }
            }
        }
    }
}

/// A dot swinging on a track with one motion personality's spring.
private struct SpringDemo: View {
    let style: MotionStyle
    let tint: Color

    var body: some View {
        let tuning = style.tuning
        let spring = Spring(duration: 0.55 * tuning.duration, bounce: min(max(0.24 + tuning.bounce, 0), 0.6))
        ZStack {
            Capsule().fill(Color.white.opacity(0.08)).frame(height: 6).padding(.horizontal, 16)
            Circle()
                .fill(tint.gradient)
                .frame(width: 16, height: 16)
                .shadow(color: tint.opacity(0.6), radius: 5)
                .phaseAnimator([false, true]) { dot, right in
                    dot.offset(x: right ? 34 : -34)
                } animation: { _ in .spring(spring).delay(0.4) }
        }
    }
}

// MARK: - Behaviour

struct BehaviourPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var login: LoginItem
    @ObservedObject var keepAwake: KeepAwake

    var body: some View {
        VStack(spacing: 14) {
            NCard(title: "Opening", symbol: "hand.point.up.left.fill") {
                NRow(title: "Open the island", detail: openDetail) {
                    NSegmented(selection: $store.value.openOn, options: OpenTrigger.allCases.map { ($0, $0.name) })
                        .frame(width: 330)
                }
            }
            AlertsCard(store: store)
            NCard(title: "Keep awake", symbol: "cup.and.heat.waves.fill") {
                NRow(title: "While Claude Code is working",
                     detail: "From your prompt until Claude stops; not while it waits on you.") {
                    NToggle(isOn: $store.value.keepAwakeClaude, tint: Palette.tint)
                }
                NRow(title: "While notchctl run commands run", detail: "Builds, tests, deploys started with notchctl run.") {
                    NToggle(isOn: $store.value.keepAwakeCommands, tint: Palette.tint)
                }
                NRow(title: "Keep awake now", detail: keepAwake.state.on ? (keepAwake.state.why ?? "Keeping awake")
                     : "Until you switch it off. Also in the open island (☕) and the menu bar.") {
                    NToggle(isOn: Binding(get: { keepAwake.state.manual }, set: { _ in keepAwake.toggleManual() }),
                            tint: .orange)
                }
            }
            NCard(title: "Feedback", symbol: "waveform") {
                NRow(title: "Haptic feedback", detail: "A tap on the trackpad when the island opens or something arrives.") {
                    NToggle(isOn: $store.value.haptics, tint: Palette.tint)
                }
                NRow(title: "Sounds", detail: "Timer finished, meeting starting.") {
                    NToggle(isOn: $store.value.sounds, tint: Palette.tint)
                }
            }
            NCard(title: "Display", symbol: "display") {
                NRow(title: "Show on", detail: "Without a notch, Notch draws one at the top of the screen.") {
                    NSegmented(selection: $store.value.display, options: DisplayChoice.allCases.map { ($0, $0.name) })
                        .frame(width: 290)
                }
                NRow(title: "Stay put when switching Spaces",
                     detail: "Keeps the island on screen through swipes and full-screen apps, using a private macOS window-server feature. If a macOS update breaks it, Notch falls back by itself; turn it off if anything looks wrong.") {
                    NToggle(isOn: $store.value.pinAboveSpaces, tint: Palette.tint)
                }
            }
            NCard(title: "Startup", symbol: "power") {
                NRow(title: "Open at login", detail: login.problem ?? (login.available
                    ? "Start Notch when you log in."
                    : "Available when Notch runs as an app (bin/notch).")) {
                    NToggle(isOn: Binding(get: { login.enabled }, set: { login.set($0) }), tint: Palette.tint)
                        .disabled(!login.available)
                        .opacity(login.available ? 1 : 0.4)
                }
            }
        }
    }

    private var openDetail: String {
        switch store.value.openOn {
        case .hover: "As soon as the pointer reaches it."
        case .hold: "Rest the pointer on it for a moment: it swells, then opens."
        case .click: "It swells under the pointer; click to open."
        }
    }
}

/// Behaviour › Alerts: for each source, stay on the notch until you've looked, or hide after
/// some seconds.
struct AlertsCard: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        NCard(title: "Alerts", symbol: "bell.badge.fill") {
            ForEach(AlertSource.allCases) { source in
                AlertRow(source: source, stays: binding(source.stays), seconds: binding(source.seconds))
            }
            Text("Until seen: on the notch until you've looked at it in the open island (a command's, until you open it after it showed). Hide after: on the notch for that long (Auto: each alert's usual 4–7 s); Claude's and Flock's news then waits, unread, in the open island, and their seconds don't count while you're away.")
                .font(.system(size: 11)).foregroundStyle(Palette.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<NotchSettings, Value>) -> Binding<Value> {
        Binding(get: { store.value[keyPath: path] }, set: { store.value[keyPath: path] = $0 })
    }
}

private struct AlertRow: View {
    let source: AlertSource
    @Binding var stays: Bool
    @Binding var seconds: Double

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: source.symbol, color: source.color, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.title).font(.system(size: 13, weight: .medium))
                Text(source.detail).font(.system(size: 11.5)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer(minLength: 10)
            NSegmented(selection: $stays, options: [(true, "Until seen"), (false, "Hide after")])
                .frame(width: 196)
            NSecondsStepper(value: $seconds, steps: source.steps, enabled: !stays)
        }
    }
}

extension AlertSource {
    var title: String {
        [.claude: "Claude Code", .pullRequests: "Pull requests", .flock: "Flock reviews",
         .builds: "Jenkins builds", .commands: "Commands"][self]!
    }
    var detail: String {
        [.claude: "Finished, session ended", .pullRequests: "Checks, reviews, comments",
         .flock: "Flock's news on your PRs", .builds: "Passed, failed",
         .commands: "notchctl say and run"][self]!
    }
    var symbol: String {
        [.claude: "sparkle", .pullRequests: PullRequestIcon.symbolName, .flock: "bird.fill",
         .builds: "hammer.fill", .commands: "terminal.fill"][self]!
    }
    var color: Color {
        [.claude: .claude, .pullRequests: .prGreen, .flock: Color(red: 0.55, green: 0.42, blue: 0.95),
         .builds: .buildBlue, .commands: Color(white: 0.4)][self]!
    }
}

/// "Open at login", through macOS's login items.
@MainActor final class LoginItem: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var problem: String?
    let available = Meetings.runningAsApp

    init() {
        if available { enabled = SMAppService.mainApp.status == .enabled }
    }

    func set(_ on: Bool) {
        guard available else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            problem = nil
        } catch {
            problem = "Couldn't change it: \(error.localizedDescription)"
        }
        let status = SMAppService.mainApp.status
        withAnimation(UISpring.snap) { enabled = status == .enabled }
        if status == .requiresApproval { problem = "Approve Notch in System Settings › General › Login Items." }
        if status == .enabled { UserDefaults.standard.set(Bundle.main.bundlePath, forKey: Self.pathKey) }
    }

    private static let pathKey = "loginItemPath"

    /// A login item opens the copy that registered it. When Notch runs from somewhere new
    /// (installed into Applications, say) with "Open at login" on, move the registration here,
    /// so login opens this copy and not the one left behind.
    static func followMove() {
        guard Meetings.runningAsApp, SMAppService.mainApp.status == .enabled else { return }
        let here = Bundle.main.bundlePath
        guard UserDefaults.standard.string(forKey: pathKey) != here else { return }
        do {
            try SMAppService.mainApp.unregister()
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(here, forKey: pathKey)
            log("login item: now opens \(here)")
        } catch {
            log("login item: couldn't move it to \(here): \(error.localizedDescription)")
        }
    }
}

// MARK: - Modules

struct ModulesPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var prs: PRWatcher

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ModuleCard(symbol: "music.note", color: Color(red: 1, green: 0.27, blue: 0.45), title: "Now Playing",
                       detail: "Browser tabs, Spotify and Apple Music.", isOn: $store.value.music)
            ModuleCard(symbol: MeetingIcon.calendarName + ".fill", color: Color(red: 1, green: 0.3, blue: 0.25), title: "Meetings",
                       detail: "Countdown to your next meeting, and Join.", isOn: $store.value.meetings)
            ModuleCard(symbol: "sparkle", color: .claude, title: "Claude Code",
                       detail: "Needs you, finished, background tasks.", isOn: $store.value.claude)
            ModuleCard(symbol: "terminal.fill", color: Color(white: 0.4), title: "Command alerts",
                       detail: "notchctl say and notchctl run.", isOn: $store.value.commands)
            ModuleCard(symbol: "timer", color: .orange, title: "Timers",
                       detail: "A focus timer from the open island.", isOn: $store.value.timers)
            ModuleCard(symbol: "bolt.fill", color: Color(red: 0.19, green: 0.78, blue: 0.35), title: "Battery",
                       detail: "Charging and low battery.", isOn: $store.value.battery)
            ModuleCard(symbol: "headphones", color: Palette.blue, title: "Headphones",
                       detail: "Connected, with their battery.", isOn: $store.value.headphones)
            ModuleCard(symbol: "flame.fill", color: Color(red: 1, green: 0.42, blue: 0.2), title: "System health",
                       detail: "Runaway processes, low disk, a hot Mac.", isOn: $store.value.systemHealth)
            ModuleCard(symbol: "gauge.with.dots.needle.67percent", color: Color(red: 0.1, green: 0.62, blue: 0.85), title: "CPU & memory",
                       detail: "Live CPU and memory, in the island.", isOn: $store.value.loadMonitor)
            ModuleCard(symbol: PullRequestIcon.symbolName, color: Color.prGreen, title: "Pull requests",
                       detail: "Checks, reviews and comments via gh.", isOn: $store.value.pullRequests)
            ModuleCard(symbol: "hammer.fill", color: .buildBlue, title: "Jenkins builds",
                       detail: "Builds you start, stage by stage.", isOn: $store.value.builds)
        }
        if store.value.pullRequests {
            PullRequestsCard(store: store, prs: prs, account: prs.account)
                .padding(.top, 14)
                .transition(.opacity.combined(with: .offset(y: -8)))
        }
        if store.value.builds {
            JenkinsCard(store: store, jenkins: .shared, prs: prs)
                .padding(.top, 14)
                .transition(.opacity.combined(with: .offset(y: -8)))
        }
        if store.value.systemHealth {
            SystemHealthCard(store: store)
                .padding(.top, 14)
                .transition(.opacity.combined(with: .offset(y: -8)))
        }
        if store.value.loadMonitor {
            LoadCard(store: store)
                .padding(.top, 14)
                .transition(.opacity.combined(with: .offset(y: -8)))
        }
    }
}

/// CPU & memory: when the closed island shows it, what it shows, and what counts as busy.
private struct LoadCard: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        NCard(title: "CPU & memory", symbol: "gauge.with.dots.needle.67percent") {
            NRow(title: "In the closed island", detail: "Always, only while the Mac is busy, or only on its page in the open island.") {
                NSegmented(selection: $store.value.loadPill, options: LoadPill.allCases.map { ($0, $0.name) })
                    .frame(width: 300)
            }
            NRow(title: "Show") {
                NSegmented(selection: $store.value.loadShow, options: LoadShow.allCases.map { ($0, $0.name) })
                    .frame(width: 300)
            }
            NRow(title: "Busy means", detail: "CPU averaging this or more over 30 s, or memory pressure raised (as in Activity Monitor).") {
                NSegmented(selection: $store.value.loadBusyCPU, options: [70, 80, 90].map { ($0, "\($0)%") })
                    .frame(width: 200)
            }
            Text("Reads the Mac's totals every 2 s (every second while its page is open), well under 0.1% CPU, and nothing while you're away. The apps list shows your own apps; macOS keeps other users' and the system's private.")
                .font(.system(size: 11)).foregroundStyle(Palette.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Where PR news comes from (your GitHub account, through gh), and whose comments to leave out.
private struct PullRequestsCard: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var prs: PRWatcher
    @ObservedObject var account: GitHubAccount

    var body: some View {
        NCard(title: "Pull requests", symbol: PullRequestIcon.symbolName) {
            GitHubAccountSection(account: account)
            if account.phase == .signedIn {
                CardHairline()
                NRow(title: prs.status, detail: "Every minute, every 20 s while checks run, paused while you're away."
                     + (prs.rate.map { " API: \($0.remaining.formatted()) of \($0.limit.formatted()) points left this hour (shared with gh); a look costs about 1." } ?? "")) {
                    NButton(title: "Refresh", symbol: "arrow.clockwise") { prs.refresh() }
                }
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
            CardHairline()
            IgnoredAuthorsEditor(store: store, prs: prs)
        }
        .animation(UISpring.soft, value: account.phase)
        .onAppear { account.load() }
    }
}

private struct CardHairline: View {
    var body: some View { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
}

// MARK: GitHub account

/// Who Notch reads pull requests as: the account, a way to switch, or gh's browser sign-in.
struct GitHubAccountSection: View {
    @ObservedObject var account: GitHubAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
                .id(phaseKey)
                .transition(.blurReplace.combined(with: .opacity))
            if let notice = account.notice, phaseKey != "signing" {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(notice).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11.5))
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(UISpring.soft, value: phaseKey)
        .animation(UISpring.soft, value: account.notice)
    }

    private var phaseKey: String {
        switch account.phase {
        case .checking: "checking"
        case .noCLI: "nocli"
        case .signedOut: "out"
        case .signingIn: "signing"
        case .signedIn: "in"
        case .failed: "failed"
        }
    }

    @ViewBuilder private var content: some View {
        switch account.phase {
        case .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking your GitHub sign-in…").font(.system(size: 13)).foregroundStyle(Palette.secondary)
            }
            .frame(height: 38)
        case .noCLI:
            AccountPrompt(tile: IconTile(symbol: "terminal.fill", color: Color(white: 0.3), size: 38),
                          title: "Install the GitHub CLI",
                          detail: "Notch reads your pull requests through gh. Install it (brew install gh), then sign in here.") {
                NButton(title: "Get gh", symbol: "arrow.up.right") { NSWorkspace.shared.open(URL(string: "https://cli.github.com")!) }
            }
        case .signedOut:
            AccountPrompt(tile: IconTile(symbol: PullRequestIcon.symbolName, color: Color(white: 0.26), size: 38),
                          title: "Sign in to GitHub",
                          detail: "Notch reads your pull requests through the GitHub CLI. Sign in once in your browser; gh keeps the token.") {
                NButton(title: "Sign in with GitHub", symbol: "arrow.right", prominent: true, tint: Palette.tint) { account.signIn() }
            }
        case .signingIn(let code, _):
            DeviceCodePanel(account: account, code: code)
        case .signedIn:
            SignedInRow(account: account)
        case .failed(let message):
            AccountPrompt(tile: IconTile(symbol: "exclamationmark.triangle.fill", color: .orange, size: 38),
                          title: "GitHub sign-in needs you", detail: message) {
                NButton(title: "Sign in again", symbol: "arrow.right", prominent: true, tint: Palette.tint) { account.signIn() }
            }
        }
    }
}

/// A tile, what's going on, and the one thing to do about it.
private struct AccountPrompt<Tile: View, Control: View>: View {
    let tile: Tile
    let title: String
    let detail: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            tile
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control
        }
    }
}

private struct SignedInRow: View {
    @ObservedObject var account: GitHubAccount

    var body: some View {
        let login = account.active?.login ?? ""
        let others = account.accounts.filter { !$0.active }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                GitHubAvatar(login: login, url: account.profile?.avatar, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.profile?.name ?? "@\(login)")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Text((account.profile?.name == nil ? "" : "@\(login) · ") + "signed in through gh")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Menu {
                    ForEach(others) { other in
                        Button("Switch to @\(other.login)") { account.switchTo(other.login) }
                    }
                    if !others.isEmpty { Divider() }
                    Button("Sign in to another account…") { account.signIn() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.fill").font(.system(size: 10, weight: .bold))
                        Text("Switch account").font(.system(size: 12.5, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.06)))
                    .contentShape(Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Text("Notch uses gh's active account, the same one your terminal uses; switching changes it there too.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiary)
        }
    }
}

/// The account's picture, over its initial while it loads (or if it can't).
struct GitHubAvatar: View {
    let login: String
    let url: URL?
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.17)], startPoint: .top, endPoint: .bottom))
            Text(login.prefix(1).uppercased())
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: UISpring.soft)) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                            .transition(.opacity.combined(with: .scale(scale: 1.08)))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }
}

/// gh's device sign-in: the one-time code, big, and a button that copies it and opens GitHub.
private struct DeviceCodePanel: View {
    @ObservedObject var account: GitHubAccount
    let code: String?
    private let copied = State(initialValue: false)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(code == nil ? "Asking GitHub for a code…" : copied.wrappedValue ? "Waiting for GitHub…" : "Enter this code on GitHub")
                    .font(.system(size: 13, weight: .semibold))
                    .contentTransition(.opacity)
            }
            if let code {
                CodeTiles(code: code)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                Text(copied.wrappedValue
                     ? "Code copied. Paste it on the page that opened and authorise GitHub CLI; Notch carries on by itself."
                     : "GitHub will ask you to authorise GitHub CLI, the tool Notch reads your pull requests through.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                HStack(spacing: 8) {
                    NButton(title: copied.wrappedValue ? "Open GitHub again" : "Copy code & open GitHub", symbol: "arrow.up.right",
                            prominent: true, tint: Palette.tint) {
                        withAnimation(UISpring.soft) { copied.wrappedValue = true }
                        account.copyCodeAndOpen()
                    }
                    NButton(title: "Cancel") { account.cancelSignIn() }
                }
            } else {
                NButton(title: "Cancel") { account.cancelSignIn() }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
        .animation(UISpring.soft, value: code)
    }
}

/// "AB12-CD34" as letter tiles that spring in one after another.
private struct CodeTiles: View {
    let code: String
    private let shown = State(initialValue: false)

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(code.enumerated()), id: \.offset) { index, character in
                if character == "-" {
                    Capsule().fill(Palette.tertiary).frame(width: 10, height: 2.5).padding(.horizontal, 3)
                } else {
                    Text(String(character))
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .frame(width: 32, height: 42)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                        .scaleEffect(shown.wrappedValue ? 1 : 0.7)
                        .opacity(shown.wrappedValue ? 1 : 0)
                        .blur(radius: shown.wrappedValue ? 0 : 3)
                        .animation(UISpring.snap.delay(Motion.reduced ? 0 : Double(index) * 0.035), value: shown.wrappedValue)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("One-time code \(code)")
        .onAppear { shown.wrappedValue = true }
    }
}

// MARK: Ignored authors

/// Whose comments never raise a banner: remove with ×, add by typing a login or picking
/// someone who has commented on your PRs.
struct IgnoredAuthorsEditor: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var prs: PRWatcher
    private let adding: State<Bool>
    private let draft: State<String>
    private let invalid = State(initialValue: false)
    @FocusState private var focused: Bool

    /// `adding` and `draft` open it with the add field showing (for previews).
    init(store: SettingsStore, prs: PRWatcher, adding: Bool = false, draft: String = "") {
        self.store = store
        self.prs = prs
        self.adding = State(initialValue: adding)
        self.draft = State(initialValue: draft)
    }

    enum Chip: Hashable {
        case name(String)
        case add
    }

    var body: some View {
        let ignored = store.value.prIgnoredAuthors
        let defaults = NotchSettings().prIgnoredAuthors
        let suggestions = suggested(ignored)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ignore comments from").font(.system(size: 13, weight: .medium))
                Spacer()
                if ignored != defaults {
                    Button("Restore defaults") {
                        withAnimation(UISpring.snap) { store.value.prIgnoredAuthors = defaults }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .transition(.opacity)
                }
            }
            Text("Their comments and reviews won't raise banners: bots that only post boilerplate, say. Click × to hear from one again.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            FlowRow(items: ignored.map(Chip.name) + [.add]) { chip in
                switch chip {
                case .name(let name): ignoredChip(name)
                case .add: addChip
                }
            }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Commented on your PRs").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.tertiary)
                    FlowRow(items: suggestions) { name in suggestionChip(name) }
                }
                .padding(.top, 2)
                .transition(.opacity)
            }
        }
        .animation(UISpring.snap, value: ignored)
        .animation(UISpring.snap, value: adding.wrappedValue)
    }

    private func ignoredChip(_ name: String) -> some View {
        HStack(spacing: 5) {
            Text(name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .contentShape(Capsule())
        .onTapGesture { withAnimation(UISpring.snap) { store.value.prIgnoredAuthors.removeAll { $0 == name } } }
        .help("Hear from \(name) again")
    }

    private func suggestionChip(_ name: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "plus").font(.system(size: 8, weight: .bold))
            Text(name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(Palette.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.03)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
        .contentShape(Capsule())
        .onTapGesture { add(name) }
        .help("Ignore \(name)'s comments")
    }

    @ViewBuilder private var addChip: some View {
        if adding.wrappedValue {
            HStack(spacing: 6) {
                TextField("github-login", text: draft.projectedValue)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 130)
                    .focused($focused)
                    .focusEffectDisabled()
                    .onSubmit(commit)
                    .onExitCommand(perform: close)
                    .onChange(of: draft.wrappedValue) { if invalid.wrappedValue { invalid.wrappedValue = false } }
                Button(action: commit) {
                    Image(systemName: "return").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.secondary)
                .help("Add")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.1)))
            .overlay(Capsule().strokeBorder(invalid.wrappedValue ? Color.orange : Palette.tint.opacity(0.75), lineWidth: 1))
            .animation(UISpring.snap, value: invalid.wrappedValue)
            .onAppear { DispatchQueue.main.async { focused = true } }
            .help(invalid.wrappedValue ? "A GitHub login: letters, numbers and dashes (bots end in [bot])" : "Type a GitHub login, then Return")
        } else {
            Button {
                withAnimation(UISpring.snap) { adding.wrappedValue = true }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 8, weight: .bold))
                    Text("Add")
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(Capsule().strokeBorder(Palette.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
                .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            .help("Ignore someone else's comments")
        }
    }

    private func commit() {
        let name = Self.clean(draft.wrappedValue)
        if name.isEmpty { return close() }
        guard Self.isLogin(name) else {
            withAnimation(UISpring.snap) { invalid.wrappedValue = true }
            return
        }
        add(name)
        close()
    }

    private func close() {
        withAnimation(UISpring.snap) {
            adding.wrappedValue = false
            draft.wrappedValue = ""
            invalid.wrappedValue = false
        }
    }

    private func add(_ name: String) {
        guard !store.value.prIgnoredAuthors.contains(where: { $0.lowercased() == name.lowercased() }) else { return }
        withAnimation(UISpring.snap) { store.value.prIgnoredAuthors.append(name) }
    }

    /// "@someone", " someone ", or their profile link → "someone".
    static func clean(_ text: String) -> String {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: name), url.host?.hasSuffix("github.com") == true, let last = url.pathComponents.last, last != "/" {
            name = last
        }
        if name.hasPrefix("@") { name.removeFirst() }
        return name
    }

    /// GitHub logins: letters, numbers and single dashes, up to 39; apps end in "[bot]".
    static func isLogin(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}(\[bot\])?$"#, options: .regularExpression) != nil
    }

    /// People and bots who've commented on or reviewed your PRs, bots first, then the
    /// chattiest. Not you, not Flock, not anyone already ignored.
    private func suggested(_ ignored: [String]) -> [String] {
        let me = prs.login?.lowercased()
        let skip = Set(ignored.map { $0.lowercased() })
        var counts: [String: Int] = [:]
        for pr in prs.prs {
            for who in pr.comments.map(\.author) + pr.reviews.map(\.author) {
                let plain = who.lowercased()
                guard plain != me, plain != "ghost", !plain.hasPrefix("flock"), !skip.contains(plain),
                      !skip.contains(plain.replacingOccurrences(of: "[bot]", with: "")) else { continue }
                counts[who, default: 0] += 1
            }
        }
        func rank(_ name: String) -> (Int, Int, String) {
            (name.lowercased().contains("bot") ? 0 : 1, -(counts[name] ?? 0), name.lowercased())
        }
        return Array(counts.keys.sorted { rank($0) < rank($1) }.prefix(6))
    }
}


// MARK: Jenkins

/// Signing in to Jenkins (an API token, kept in the keychain), and what Notch is watching.
struct JenkinsCard: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var jenkins: JenkinsWatcher
    let prs: PRWatcher
    private let server: State<String>
    private let user: State<String>
    private let token = State(initialValue: "")

    init(store: SettingsStore, jenkins: JenkinsWatcher, prs: PRWatcher) {
        self.store = store
        self.jenkins = jenkins
        self.prs = prs
        let saved = store.value.jenkinsURL
        server = State(initialValue: saved.isEmpty ? (Self.detectedServer(prs)?.absoluteString ?? "") : saved)
        user = State(initialValue: store.value.jenkinsUser)
    }

    var body: some View {
        NCard(title: "Jenkins builds", symbol: "hammer.fill") {
            Group {
                if jenkins.phase == .signedIn { signedIn } else { signInForm }
            }
            .transition(.blurReplace.combined(with: .opacity))
        }
        .animation(UISpring.soft, value: jenkins.phase)
    }

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.buildBlue.gradient)
                    Text((jenkins.account?.fullName ?? store.value.jenkinsUser).prefix(1).uppercased())
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                }
                .frame(width: 38, height: 38)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(jenkins.account?.fullName ?? store.value.jenkinsUser).font(.system(size: 13, weight: .semibold))
                    Text("\(jenkins.account?.id ?? store.value.jenkinsUser) on \(JenkinsWatcher.serverURL(store.value.jenkinsURL)?.host ?? "Jenkins")")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 12)
                NButton(title: "Sign out", symbol: "rectangle.portrait.and.arrow.right") { jenkins.signOut() }
            }
            CardHairline()
            NRow(title: jenkins.status,
                 detail: "Any job: builds started by you, or by your pushes, found by asking Jenkins what's running. Every 20 s while one of yours runs; otherwise every 1½ to 5 minutes, slower the longer it's quiet, and soon after you push. Paused while you're away."
                    + (jenkins.lastLook.map { " Last look \($0.formatted(date: .omitted, time: .standard))." } ?? "")) {
                NButton(title: "Refresh", symbol: "arrow.clockwise") { jenkins.refresh() }
            }
        }
    }

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in to Jenkins").font(.system(size: 13, weight: .semibold))
                Text("Make an API token in Jenkins (your name › Security › API Token › Add new token) and paste it here. It stays in your keychain; Notch only reads builds.")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            JenkinsField(label: "Server", text: server.projectedValue, prompt: "jenkins.example.com")
            HStack(spacing: 10) {
                JenkinsField(label: "Username", text: user.projectedValue, prompt: "your Jenkins id")
                JenkinsField(label: "API token", text: token.projectedValue, prompt: "paste the token", secure: true)
            }
            if case .failed(let message) = jenkins.phase {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(message).foregroundStyle(Palette.secondary)
                }
                .font(.system(size: 11.5))
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
            HStack(spacing: 8) {
                if let url = JenkinsWatcher.serverURL(server.wrappedValue) {
                    NButton(title: "Make a token", symbol: "arrow.up.right") {
                        NSWorkspace.shared.open(url.appendingPathComponent("me/security/"))
                    }
                }
                Spacer()
                if jenkins.phase == .signingIn { ProgressView().controlSize(.small) }
                NButton(title: "Sign in", symbol: "arrow.right", prominent: true, tint: Palette.tint) {
                    jenkins.signIn(server: server.wrappedValue, user: user.wrappedValue, token: token.wrappedValue)
                    token.wrappedValue = ""
                }
                .disabled(jenkins.phase == .signingIn || user.wrappedValue.isEmpty || token.wrappedValue.isEmpty)
                .opacity(user.wrappedValue.isEmpty || token.wrappedValue.isEmpty ? 0.5 : 1)
            }
        }
    }

    /// The Jenkins your PR checks link to (`…/job/…`), to fill in the server.
    static func detectedServer(_ prs: PRWatcher) -> URL? {
        prs.prs.lazy.flatMap(\.checks).compactMap(\.url).first { $0.path.contains("/job/") }
            .flatMap { url in url.host.flatMap { URL(string: "\(url.scheme ?? "https")://\($0)") } }
    }
}

/// A labelled text field in the customiser's style.
private struct JenkinsField: View {
    let label: String
    @Binding var text: String
    let prompt: String
    var secure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
            Group {
                if secure { SecureField(prompt, text: $text) } else { TextField(prompt, text: $text) }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .autocorrectionDisabled()
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        }
    }
}

/// When a process counts as runaway, and the programs never to warn about.
private struct SystemHealthCard: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        NCard(title: "System health", symbol: "flame.fill") {
            NRow(title: "CPU", detail: "Warn when one of your processes stays above this for 2 minutes (100% = one core).") {
                NSegmented(selection: $store.value.cpuAlert, options: [100, 150, 200, 300].map { ($0, "\($0)%") })
                    .frame(width: 260)
            }
            NRow(title: "Memory", detail: "Warn when a process holds more than this.") {
                NSegmented(selection: $store.value.memoryAlertGB, options: [4, 8, 16].map { ($0, "\($0) GB") })
                    .frame(width: 200)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Never warn about").font(.system(size: 13, weight: .medium))
                Text("Build tools and VMs work hard on purpose. Click × to watch one again.")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                FlowRow(items: store.value.ignoredProcesses) { name in
                    HStack(spacing: 5) {
                        Text(name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(UISpring.snap) { store.value.ignoredProcesses.removeAll { $0 == name } }
                    }
                    .help("Watch \(name) again")
                }
            }
            HStack {
                Spacer()
                NButton(title: "Restore defaults", symbol: "arrow.counterclockwise") {
                    withAnimation(UISpring.snap) { store.value.ignoredProcesses = SystemMonitor.defaultIgnored }
                }
            }
        }
    }
}

/// Chips that wrap onto new lines.
struct FlowRow<Item: Hashable, Chip: View>: View {
    let items: [Item]
    @ViewBuilder let chip: (Item) -> Chip

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in chip(item).transition(.scale.combined(with: .opacity)) }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 600, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, origin) in arrange(width: bounds.width, subviews: subviews).origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, CGSize(width: widest, height: y + rowHeight))
    }
}

private struct ModuleCard: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: symbol, color: color, size: 32)
                .saturation(isOn ? 1 : 0)
                .opacity(isOn ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            NToggle(isOn: $isOn, tint: Palette.tint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.cardStroke))
        .animation(UISpring.snap, value: isOn)
    }
}

// MARK: - Meetings

struct MeetingsPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var meetings: Meetings

    var body: some View {
        VStack(spacing: 14) {
            NCard {
                HStack(alignment: .center, spacing: 14) {
                    IconTile(symbol: MeetingIcon.calendarName + ".fill", color: Color(red: 1, green: 0.3, blue: 0.25), size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(status.title).font(.system(size: 15, weight: .semibold))
                        Text(status.detail).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    switch meetings.access {
                    case .notDetermined:
                        NButton(title: "Allow Access", symbol: "lock.open.fill", prominent: true) { meetings.requestAccess() }
                    case .denied:
                        NButton(title: "Open Settings", symbol: "gearshape.fill") { Meetings.openPrivacySettings() }
                    case .granted:
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 22))
                            .symbolRenderingMode(.palette).foregroundStyle(.white, Color.green)
                    case .unavailable:
                        EmptyView()
                    }
                }
            }
            if meetings.access == .granted {
                if meetings.calendars.isEmpty {
                    NCard(title: "No calendars yet", symbol: "exclamationmark.circle") {
                        NRow(title: "Add your work calendar",
                             detail: "Notch reads the calendars in the Calendar app. Add your Google or Exchange account in Internet Accounts.") {
                            NButton(title: "Internet Accounts", symbol: "at") { Meetings.openInternetAccounts() }
                        }
                    }
                } else {
                    calendarsCard
                }
            }
            NCard(title: "Timing", symbol: "clock.fill") {
                NRow(title: "Show the pill", detail: "Before a meeting starts. It outranks music in the last two minutes.") {
                    NSegmented(selection: $store.value.meetingLead,
                               options: [2, 5, 10, 15].map { ($0, "\($0) min") })
                        .frame(width: 270)
                }
                NRow(title: "Time left during meetings", detail: "A ring and the minutes left while it runs.") {
                    NToggle(isOn: $store.value.meetingTimeLeft, tint: Palette.tint)
                }
                NRow(title: "Chime when a meeting starts") {
                    NToggle(isOn: $store.value.meetingChime, tint: Palette.tint)
                }
                NRow(title: "Only meetings with a video link", detail: "Meet, Zoom, Teams, Webex, Slack, Chime, Whereby.") {
                    NToggle(isOn: $store.value.videoMeetingsOnly, tint: Palette.tint)
                }
            }
            if meetings.access == .granted, !meetings.calendars.isEmpty {
                NCard(title: "Coming up", symbol: "list.bullet") {
                    if meetings.upcoming.isEmpty {
                        Text("Nothing for the rest of today.").font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                    }
                    ForEach(meetings.upcoming) { meeting in
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 2).fill(meeting.color.color).frame(width: 4, height: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(meeting.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(meeting.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
                                     + (meeting.service.map { " · \($0)" } ?? ""))
                                    .font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                            }
                            Spacer()
                            if let url = meeting.joinURL {
                                NButton(title: "Join", symbol: MeetingIcon.videoName + ".fill") { NSWorkspace.shared.open(url) }
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: store.value) { meetings.evaluate() }
    }

    private var calendarsCard: some View {
        NCard(title: "Calendars", symbol: "checklist") {
            let accounts = Dictionary(grouping: meetings.calendars, by: \.account)
            ForEach(accounts.keys.sorted(), id: \.self) { account in
                VStack(alignment: .leading, spacing: 8) {
                    Text(account).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.tertiary)
                    ForEach(accounts[account] ?? []) { calendar in
                        NRow(title: calendar.title) {
                            NToggle(isOn: Binding(
                                get: { !store.value.hiddenCalendars.contains(calendar.id) },
                                set: { on in
                                    store.value.hiddenCalendars.removeAll { $0 == calendar.id }
                                    if !on { store.value.hiddenCalendars.append(calendar.id) }
                                }), tint: calendar.color.color)
                        }
                    }
                }
            }
        }
    }

    private var status: (title: String, detail: String) {
        switch meetings.access {
        case .notDetermined:
            ("Connect your calendar", "Notch reads your calendars to show the next meeting and a Join button. Nothing leaves your Mac.")
        case .denied:
            ("Calendar access is off", "Turn Notch on in Privacy & Security › Calendars.")
        case .granted:
            ("Calendar connected", "\(meetings.calendars.count) calendar\(meetings.calendars.count == 1 ? "" : "s") · \(meetings.upcoming.count) coming up")
        case .unavailable:
            ("Run Notch as an app", "macOS only lets apps read calendars. Start Notch with bin/notch to set this up.")
        }
    }
}

// MARK: - About

struct AboutPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var updater = Updater.shared
    private let confirmReset = State(initialValue: false)

    var body: some View {
        VStack(spacing: 14) {
            NCard {
                HStack(spacing: 18) {
                    AppIconArt().frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notch").font(.system(size: 22, weight: .bold))
                        Text(version).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        Text("A Dynamic Island for your Mac. Everything runs on this Mac; it talks only to the services you switch on (GitHub, Jenkins) and checks GitHub for updates.")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Created by Devadutt Mohan")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.78))
                            .padding(.top, 4)
                    }
                }
            }
            UpdatesCard(store: store, updater: updater)
            NCard(title: "Files", symbol: "folder.fill") {
                NRow(title: "Settings", detail: SettingsStore.fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    NButton(title: "Show in Finder", symbol: "magnifyingglass") {
                        NSWorkspace.shared.activateFileViewerSelecting([SettingsStore.fileURL])
                    }
                }
                NRow(title: "Log", detail: logURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    NButton(title: "Open", symbol: "doc.text") { NSWorkspace.shared.open(logURL) }
                }
            }
            NCard(title: "Reset", symbol: "arrow.counterclockwise") {
                NRow(title: "Reset all settings", detail: "Back to the defaults. Your calendar choices are cleared too.") {
                    NButton(title: confirmReset.wrappedValue ? "Click again to reset" : "Reset…",
                            prominent: confirmReset.wrappedValue, tint: .red) {
                        if confirmReset.wrappedValue {
                            withAnimation(UISpring.soft) { store.reset() }
                            confirmReset.wrappedValue = false
                        } else {
                            withAnimation(UISpring.snap) { confirmReset.wrappedValue = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                withAnimation(UISpring.snap) { confirmReset.wrappedValue = false }
                            }
                        }
                    }
                }
            }
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        if let version = info?["CFBundleShortVersionString"] as? String { return "Version \(version)" }
        return "Development build (swift run)"
    }

    private var logURL: URL { LogFile.url }
}

// MARK: - Updates

/// New versions from GitHub: where things stand, and Update when there's one.
struct UpdatesCard: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var updater: Updater

    var body: some View {
        NCard(title: "Updates", symbol: "arrow.down.circle") {
            status
                .animation(UISpring.soft, value: updater.phase)
            if let release = shownNotes, !release.highlights.isEmpty, !isBusy {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(release.highlights, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Circle().fill(Palette.blue).frame(width: 5, height: 5).offset(y: -1)
                            Text(line).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
            CardHairline()
            NRow(title: "Check automatically", detail: "About every 6 hours, and when you open this page. Nothing is sent but the request.") {
                NToggle(isOn: $store.value.checkForUpdates, tint: Palette.tint)
            }
        }
        .onAppear { updater.checkIfStale() }
        .onChange(of: store.value.checkForUpdates) { _, _ in updater.scheduleChecks() }
    }

    /// The notes to show: an available update's, or, right after updating, this version's.
    private var shownNotes: NotchRelease? {
        if let release = updater.available { return release }
        if updater.phase == .upToDate, updater.updatedFrom != nil, let latest = updater.latest,
           latest.version == updater.currentVersion { return latest }
        return nil
    }

    private var isBusy: Bool {
        switch updater.phase {
        case .downloading, .installing: true
        default: false
        }
    }

    @ViewBuilder private var status: some View {
        let current = updater.currentVersion ?? "?"
        switch updater.phase {
        case .unavailable(let reason):
            StatusLine(symbol: "exclamationmark.triangle.fill", tint: Palette.tertiary, title: "Updates aren't available here", detail: reason) { EmptyView() }
        case .idle:
            StatusLine(symbol: "arrow.down.circle", tint: Palette.secondary, title: "Not checked yet", detail: "You have \(current).") {
                NButton(title: "Check now", symbol: "arrow.clockwise") { updater.check(manual: true) }
            }
        case .checking:
            StatusLine(symbol: nil, tint: Palette.secondary, title: "Checking GitHub…", detail: "You have \(current).") {
                NButton(title: "Check now", symbol: "arrow.clockwise") {}.opacity(0.4).disabled(true)
            }
        case .upToDate:
            if let from = updater.updatedFrom, let latest = updater.latest, latest.version == current {
                StatusLine(symbol: "checkmark.seal.fill", tint: .green, title: "Updated to \(current)", detail: "From \(from). Here's what's new.") {
                    HStack(spacing: 8) {
                        NButton(title: "What's new", symbol: "arrow.up.right") { NSWorkspace.shared.open(latest.page) }
                        NButton(title: "Check now", symbol: "arrow.clockwise") { updater.check(manual: true) }
                    }
                }
            } else {
                StatusLine(symbol: "checkmark.seal.fill", tint: .green, title: "Notch is up to date", detail: checkedLine(current)) {
                    NButton(title: "Check now", symbol: "arrow.clockwise") { updater.check(manual: true) }
                }
            }
        case .available(let release):
            StatusLine(symbol: "arrow.down.circle.fill", tint: Palette.blue, title: "Version \(release.version) is available",
                       detail: "You have \(current)" + (release.size > 0 ? " · \(megabytes(release.size)) download" : "")) {
                HStack(spacing: 8) {
                    NButton(title: "What's new", symbol: "arrow.up.right") { NSWorkspace.shared.open(release.page) }
                    NButton(title: "Update", symbol: "arrow.down", prominent: true) { updater.install() }
                }
            }
        case .downloading(let release, let fraction):
            VStack(alignment: .leading, spacing: 10) {
                StatusLine(symbol: nil, tint: Palette.blue, title: "Downloading Notch \(release.version)…",
                           detail: release.size > 0 ? "\(megabytes(Int(Double(release.size) * fraction))) of \(megabytes(release.size))" : "\(Int(fraction * 100))%") { EmptyView() }
                UpdateProgress(fraction: fraction)
            }
        case .installing(let release):
            VStack(alignment: .leading, spacing: 10) {
                StatusLine(symbol: nil, tint: Palette.blue, title: "Installing Notch \(release.version)…",
                           detail: "Checking the download; Notch will restart in a moment.") { EmptyView() }
                UpdateProgress(fraction: 1)
            }
        case .installFailed(let version, let message):
            StatusLine(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "Notch \(version) wasn't installed", detail: message) {
                NButton(title: "Try again", symbol: "arrow.clockwise") { updater.check(manual: true) }
            }
        case .failed(let message, let release):
            StatusLine(symbol: "exclamationmark.triangle.fill", tint: .orange,
                       title: release == nil ? "Couldn't check for updates" : "Couldn't update to \(release!.version)", detail: message) {
                NButton(title: "Try again", symbol: "arrow.clockwise") {
                    release == nil ? updater.check(manual: true) : updater.install()
                }
            }
        }
    }

    private func checkedLine(_ current: String) -> String {
        guard let checked = updater.lastChecked else { return "Version \(current)." }
        let ago = Date().timeIntervalSince(checked)
        let when = ago < 60 ? "just now" : ago < 3600 ? "\(Int(ago / 60)) min ago" : "\(Int(ago / 3600)) h ago"
        return "Version \(current) · checked \(when)"
    }

    private func megabytes(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_000_000) }
}

/// An icon (or a spinner), what's happening, and what you can do.
private struct StatusLine<Actions: View>: View {
    let symbol: String?
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(tint)
                        .contentTransition(.symbolEffect(.replace))
                } else {
                    Spinner(tint: tint)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).contentTransition(.interpolate)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 12)
            actions
        }
    }
}

/// A turning arc, for checking and installing.
private struct Spinner: View {
    let tint: Color
    private let turning = State(initialValue: false)

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 0.82)
            .stroke(tint, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            .frame(width: 18, height: 18)
            .rotationEffect(.degrees(turning.wrappedValue ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: turning.wrappedValue)
            .onAppear { turning.wrappedValue = true }
    }
}

/// A slim bar that fills as the update downloads.
private struct UpdateProgress: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(Palette.blue.gradient).frame(width: max(6, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.25), value: fraction)
    }
}

// MARK: - Icon

/// Notch's icon: a dark squircle with the island hanging from the top, lit from below.
struct AppIconArt: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let squircle = RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(white: 0.17), Color(red: 0.03, green: 0.03, blue: 0.05)],
                               startPoint: .top, endPoint: .bottom)
                ZStack {
                    Ellipse().fill(Color(red: 0.18, green: 0.75, blue: 0.95)).frame(width: s * 0.62, height: s * 0.34)
                        .offset(x: -s * 0.14, y: s * 0.02)
                    Ellipse().fill(Color(red: 0.66, green: 0.3, blue: 0.95)).frame(width: s * 0.6, height: s * 0.32)
                        .offset(x: s * 0.16, y: s * 0.07)
                    Ellipse().fill(Color(red: 1, green: 0.45, blue: 0.4)).frame(width: s * 0.4, height: s * 0.22)
                        .offset(x: 0, y: s * 0.16)
                }
                .blur(radius: s * 0.09)
                .opacity(0.9)
                .offset(y: s * 0.36)
                NotchShape(topRadius: s * 0.035, bottomRadius: s * 0.1)
                    .fill(Color.black)
                    .frame(width: s * 0.7, height: s * 0.27)
                    .overlay(alignment: .center) {
                        HStack(spacing: s * 0.025) {
                            RoundedRectangle(cornerRadius: s * 0.025, style: .continuous)
                                .fill(LinearGradient(colors: [Color(red: 1, green: 0.45, blue: 0.4), Color(red: 0.66, green: 0.3, blue: 0.95)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: s * 0.1, height: s * 0.1)
                            Spacer()
                            HStack(alignment: .center, spacing: s * 0.015) {
                                ForEach([0.5, 0.9, 0.65, 1.0], id: \.self) { level in
                                    Capsule().fill(Color(red: 0.25, green: 0.85, blue: 0.95))
                                        .frame(width: s * 0.022, height: s * 0.1 * level)
                                }
                            }
                        }
                        .padding(.horizontal, s * 0.1)
                        .offset(y: s * 0.035)
                    }
                    .shadow(color: .black.opacity(0.5), radius: s * 0.03, y: s * 0.01)
            }
            .frame(width: s, height: s)
            .clipShape(squircle)
            .overlay(squircle.strokeBorder(Color.white.opacity(0.12), lineWidth: max(0.5, s * 0.004)))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// The Dock icon: the art on Apple's icon grid (an 824-pt squircle on a 1024-pt canvas).
    @MainActor static func image(size: CGFloat = 1024) -> NSImage? {
        let canvas = AppIconArt()
            .frame(width: size * 0.805, height: size * 0.805)
            .shadow(color: .black.opacity(0.35), radius: size * 0.012, y: size * 0.01)
            .frame(width: size, height: size)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 1
        return renderer.nsImage
    }
}
