import AppKit

/// Where the physical notch is, read from the hardware.
struct NotchGeometry: Equatable {
    var screenFrame: NSRect
    var notchSize: CGSize
    var hasNotch: Bool

    /// `.notched`: the display with a notch (falling back to the main one). `.primary`: the
    /// display with the menu bar, notch or not.
    @MainActor static func current(display: DisplayChoice = .notched) -> NotchGeometry {
        if display == .primary, let primary = NSScreen.screens.first {
            if let left = primary.auxiliaryTopLeftArea, let right = primary.auxiliaryTopRightArea, primary.safeAreaInsets.top > 0 {
                return NotchGeometry(screenFrame: primary.frame,
                                     notchSize: CGSize(width: primary.frame.width - left.width - right.width,
                                                       height: primary.safeAreaInsets.top),
                                     hasNotch: true)
            }
            let menuBarHeight = primary.frame.maxY - primary.visibleFrame.maxY
            return NotchGeometry(screenFrame: primary.frame,
                                 notchSize: CGSize(width: 190, height: max(menuBarHeight, 24)), hasNotch: false)
        }
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            return NotchGeometry(
                screenFrame: screen.frame,
                notchSize: CGSize(width: screen.frame.width - left.width - right.width,
                                  height: screen.safeAreaInsets.top),
                hasNotch: true)
        }
        // No notched display (lid closed, external monitor only): fake a notch on the main screen.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(screenFrame: screen.frame,
                             notchSize: CGSize(width: 190, height: max(menuBarHeight, 24)),
                             hasNotch: false)
    }
}

/// The three sizes the island moves between.
enum NotchState: Equatable {
    case idle       // exactly the physical notch, so it's invisible
    case compact    // wider, with a glyph on each side of the camera
    case expanded   // drops down into a panel (on hover)
    case banner     // a brief drop-down (charging, headphones, Claude finished…), closes by itself
}

/// The open panel has two heights: the standard one, and a taller one for media with
/// a timeline (room for the seek slider).
enum ExpandedKind: Equatable {
    case standard, media
    case list                         // the PR page before its content has been measured
    case listFit(CGFloat)             // the PR page, exactly as tall as its content (measured)
}

/// Size and corner radii for one state.
struct NotchSpec: Equatable {
    var size: CGSize            // body size, not counting the top flares
    var topRadius: CGFloat      // concave flare where the shape meets the bezel
    var bottomRadius: CGFloat
    var outerWidth: CGFloat { size.width + 2 * topRadius }
}

struct NotchLayout: Equatable {
    var geometry: NotchGeometry
    var size: IslandSize = .standard
    var roundness: Double = 1                     // scales the bottom corners
    var pillExtra: CGFloat = 0                    // each side of the closed pill, for a wider reading

    /// The hardware plus the customiser's size and roundness.
    @MainActor static func current() -> NotchLayout {
        let settings = SettingsStore.shared.value
        return NotchLayout(geometry: .current(display: settings.display), size: settings.size,
                           roundness: settings.roundness)
    }

    var compactSideWidth: CGFloat { [.compact: 46, .standard: 54, .large: 64][size]! }
    var expandedSize: CGSize {
        [.compact: CGSize(width: 404, height: 154), .standard: CGSize(width: 440, height: 164),
         .large: CGSize(width: 500, height: 178)][size]!
    }
    var expandedMediaHeight: CGFloat { [.compact: 186, .standard: 196, .large: 212][size]! }
    var expandedListHeight: CGFloat { [.compact: 292, .standard: 302, .large: 318][size]! }
    /// The most the PR page may grow past its usual height.
    static let maxListGrowth: CGFloat = 120

    func expandedHeight(_ kind: ExpandedKind) -> CGFloat {
        switch kind {
        case .standard: expandedSize.height
        case .media: expandedMediaHeight
        case .list: expandedListHeight
        case .listFit(let height): min(max(height, expandedSize.height), expandedListHeight + Self.maxListGrowth)
        }
    }

    /// The bubble beside the pill (a second activity): its body width and its gap from the pill.
    var bubbleWidth: CGFloat { geometry.notchSize.height }
    static let bubbleGap: CGFloat = 6
    var bannerWidth: CGFloat { [.compact: 376, .standard: 400, .large: 440][size]! }
    static let bannerDrop: CGFloat = 54          // how far a banner hangs below the notch

    private func round(_ radius: CGFloat, cap: CGFloat) -> CGFloat {
        min(radius * CGFloat(min(max(roundness, 0.5), 1.5)), cap)
    }

    func spec(for state: NotchState, kind: ExpandedKind = .standard) -> NotchSpec {
        let notch = geometry.notchSize
        switch state {
        case .idle:
            return NotchSpec(size: notch, topRadius: 0, bottomRadius: 10)
        case .compact:
            return NotchSpec(size: CGSize(width: notch.width + 2 * (compactSideWidth + pillExtra), height: notch.height),
                             topRadius: 6, bottomRadius: round(12, cap: notch.height / 2))
        case .banner:
            return NotchSpec(size: CGSize(width: max(bannerWidth, notch.width + 2 * compactSideWidth),
                                          height: notch.height + Self.bannerDrop),
                             topRadius: 12, bottomRadius: round(26, cap: (notch.height + Self.bannerDrop) / 2 - 4))
        case .expanded:
            return NotchSpec(size: CGSize(width: max(expandedSize.width, notch.width + 2 * compactSideWidth),
                                          height: expandedHeight(kind)),
                             topRadius: 14, bottomRadius: round(32, cap: 46))
        }
    }

    /// Body rect for a state in global screen coordinates (used for hover hit-testing).
    func screenRect(for state: NotchState, kind: ExpandedKind = .standard) -> NSRect {
        let size = spec(for: state, kind: kind).size
        let screen = geometry.screenFrame
        return NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// Where the bubble sits on screen (for hover), beside the compact pill.
    func bubbleRect() -> NSRect {
        let pill = screenRect(for: .compact)
        return NSRect(x: pill.maxX + Self.bubbleGap, y: pill.minY, width: bubbleWidth + 10, height: pill.height)
    }

    /// The overlay panel is sized for the largest state, centred at the top of the screen,
    /// with room around it for the spring overshoot and the open panel's shadow.
    var panelFrame: NSRect {
        // Sized for the largest island, whatever the current size setting, so changing it
        // never has to move the window.
        let largest = NotchLayout(geometry: geometry, size: .large, roundness: roundness)
        let expanded = largest.spec(for: .expanded, kind: .listFit(.greatestFiniteMagnitude))   // the tallest
        let size = CGSize(width: expanded.outerWidth + 100, height: expanded.size.height + 70)
        let screen = geometry.screenFrame
        return NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height,
                      width: size.width, height: size.height)
    }
}
