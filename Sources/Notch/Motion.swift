import AppKit
import SwiftUI

/// Dynamic Island-style motion, all in one place so it can be tuned.
///
/// Apple doesn't publish the island's curves; these are tuned by eye to what it does:
/// - Each part of the shape moves on its own spring. Opening grows wide first, then
///   drops down with a touch more bounce. Closing pulls up first, then narrows.
/// - Opening is slower and springier than closing.
/// - Content is laid out at its final size and *revealed* by the growing shape. It
///   blurs and scales in just after the shape gets going, and blurs out at once on
///   the way back, so the shape never has to clip visible content.
///
/// Run with `--slow 5` to watch everything five times slower. The customiser's Motion
/// settings (personality, speed, content effect, Reduce Motion) bend all of these.
enum Motion {
    struct Curve: Sendable {
        var spring: Spring
        var delay: TimeInterval = 0
    }

    // MARK: Shape

    /// Opening: width leads...
    static let expandWidth = Curve(spring: Spring(duration: 0.42, bounce: 0.24))
    /// ...and the drop down follows a beat later, a little bouncier.
    static let expandHeight = Curve(spring: Spring(duration: 0.50, bounce: 0.30), delay: 0.03)
    /// Closing: pulls up first...
    static let collapseHeight = Curve(spring: Spring(duration: 0.34, bounce: 0.10))
    /// ...then narrows.
    static let collapseWidth = Curve(spring: Spring(duration: 0.40, bounce: 0.16), delay: 0.04)
    /// The compact pill stretching out of the notch when something starts.
    static let appear = Curve(spring: Spring(duration: 0.45, bounce: 0.32))
    /// ...and tucking back in when it stops.
    static let disappear = Curve(spring: Spring(duration: 0.32, bounce: 0.08), delay: 0.05)

    // MARK: Content

    static let contentIn = Curve(spring: Spring(duration: 0.36, bounce: 0.12), delay: 0.10)
    static let contentOut = Curve(spring: Spring(duration: 0.14, bounce: 0))
    /// Changes inside a state: new track, play/pause, countdown digits.
    static let contentSwap = Curve(spring: Spring(duration: 0.35, bounce: 0.10))

    // MARK: Controls

    /// The seek thumb gliding to a new position (tap, seek, a correction from the browser).
    static let seekGlide = Spring(duration: 0.38, bounce: 0.18)
    /// Thumb and bar growing under the pointer.
    static let grow = Curve(spring: Spring(duration: 0.30, bounce: 0.30))

    /// `--slow N` plays every animation N times slower, like the Simulator's slow animations
    /// (banner timings too, so you can watch them).
    @MainActor static var debugSlowdown: Double = 1

    /// How much slower than designed animations run: `--slow`, divided by the Speed setting.
    @MainActor static var slowdown: Double {
        debugSlowdown / min(max(SettingsStore.shared.value.speed, 0.4), 2)
    }

    /// Reduce Motion: the customiser's choice, or the system's accessibility setting.
    @MainActor static var reduced: Bool {
        switch SettingsStore.shared.value.reduceMotion {
        case .always: true
        case .never: false
        case .system: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    /// Every animation goes through here, bent by the Motion personality (snappier, bouncier…)
    /// and speed. With Reduce Motion it becomes a short ease with no overshoot.
    @MainActor static func animation(_ curve: Curve) -> Animation {
        if reduced { return Animation.easeInOut(duration: 0.2).speed(1 / slowdown) }
        let tuning = SettingsStore.shared.value.motion.tuning
        let spring = Spring(duration: curve.spring.duration * tuning.duration,
                            bounce: min(max(curve.spring.bounce + tuning.bounce, 0), 0.6))
        return Animation.spring(spring).delay(curve.delay * tuning.duration).speed(1 / slowdown)
    }

    /// The (width, height) curves for a change between two states.
    static func shapeCurves(from old: NotchState, to new: NotchState) -> (width: Curve, height: Curve) {
        switch (old, new) {
        case (_, .expanded), (_, .banner): return (expandWidth, expandHeight)
        case (.expanded, _), (.banner, _): return (collapseWidth, collapseHeight)
        case (_, .compact):                return (appear, appear)
        default:                           return (disappear, disappear)
        }
    }

    /// Content arrives after the shape gets going and leaves straight away, in the chosen
    /// style: blur, zoom or fade (always fade with Reduce Motion).
    @MainActor static var contentTransition: some Transition {
        let effect = reduced ? .fade : SettingsStore.shared.value.contentEffect
        return AsymmetricTransition(
            insertion: IslandContentTransition(effect: effect).animation(animation(contentIn)),
            removal: IslandContentTransition(effect: effect).animation(animation(contentOut)))
    }
}

/// How content enters and leaves the island.
struct IslandContentTransition: Transition {
    var effect: ContentEffect

    func body(content: Content, phase: TransitionPhase) -> some View {
        let hidden = !phase.isIdentity
        content
            .blur(radius: hidden ? (effect == .blur ? 10 : effect == .zoom ? 4 : 0) : 0)
            .scaleEffect(hidden ? (effect == .blur ? 0.94 : effect == .zoom ? 0.72 : 1) : 1, anchor: .top)
            .opacity(hidden ? 0 : 1)
    }
}
