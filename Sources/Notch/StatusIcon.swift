import AppKit
import SwiftUI

/// The menu bar icon: a MacBook screen outline with the island hanging from its top edge.
/// The little island mirrors the real one: a small notch when nothing's happening, a wider
/// pill when something is, and a dot underneath when something needs you. It springs
/// between them like the island does. A template image, so macOS tints it for light and
/// dark menu bars (and the pressed state) like its own icons.
@MainActor final class StatusIcon {
    struct Pose: Equatable {
        var width: CGFloat         // the island's width, in points
        var height: CGFloat        // how far it hangs below the top edge
        var dot: CGFloat           // the "needs you" dot, 0…1

        static let idle = Pose(width: 6.5, height: 2.4, dot: 0)
        static let active = Pose(width: 11.5, height: 3.1, dot: 0)
        static let attention = Pose(width: 11.5, height: 3.1, dot: 1)

        func mixed(with other: Pose, _ t: CGFloat) -> Pose {
            Pose(width: width + (other.width - width) * t, height: height + (other.height - height) * t,
                 dot: dot + (other.dot - dot) * t)
        }
    }

    private weak var button: NSStatusBarButton?
    private(set) var pose = Pose.idle
    private var timer: Timer?

    init(button: NSStatusBarButton?) {
        self.button = button
        button?.image = Self.image(.idle)
        button?.imagePosition = .imageOnly
        button?.setAccessibilityLabel("Notch")
    }

    /// Morph to a pose on a soft spring (or switch straight away with Reduce Motion).
    func show(_ target: Pose, tooltip: String) {
        button?.toolTip = tooltip
        guard target != pose else { return }
        timer?.invalidate()
        if Motion.reduced {
            pose = target
            button?.image = Self.image(target)
            return
        }
        let from = pose
        let start = Date()
        let spring = Spring(duration: 0.42, bounce: 0.28)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = Date().timeIntervalSince(start) / Motion.slowdown
                let done = t >= spring.settlingDuration
                let progress = done ? 1 : CGFloat(spring.value(target: 1.0, time: t))
                self.pose = done ? target : from.mixed(with: target, progress)
                self.button?.image = Self.image(self.pose)
                if done { self.timer?.invalidate(); self.timer = nil }
            }
        }
    }

    /// The icon at one pose, on a 22 × 16 pt canvas (drawn sharp at any scale).
    nonisolated static func image(_ pose: Pose) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 16), flipped: true) { _ in
            NSColor.black.set()
            // The screen.
            let screen = NSRect(x: 1.75, y: 1.5, width: 18.5, height: 13)
            let outline = NSBezierPath(roundedRect: screen, xRadius: 3.2, yRadius: 3.2)
            outline.lineWidth = 1.5
            outline.stroke()

            // The island, hanging from the top edge, with the concave flares where it meets it.
            let mid: CGFloat = 11
            let w = max(pose.width, 3), h = max(pose.height, 1.5)
            let top = screen.minY - 0.75, bottom = screen.minY + h
            let left = mid - w / 2, right = mid + w / 2
            let flare: CGFloat = 1.1
            let radius = min(h * 0.9, w / 2)
            let island = NSBezierPath()
            island.move(to: NSPoint(x: left - flare, y: top))
            island.line(to: NSPoint(x: right + flare, y: top))
            island.curve(to: NSPoint(x: right, y: top + flare + 0.75),
                         controlPoint1: NSPoint(x: right, y: top), controlPoint2: NSPoint(x: right, y: top + 0.4))
            island.line(to: NSPoint(x: right, y: bottom - radius))
            island.appendArc(from: NSPoint(x: right, y: bottom), to: NSPoint(x: mid, y: bottom), radius: radius)
            island.appendArc(from: NSPoint(x: left, y: bottom), to: NSPoint(x: left, y: bottom - radius), radius: radius)
            island.line(to: NSPoint(x: left, y: top + flare + 0.75))
            island.curve(to: NSPoint(x: left - flare, y: top),
                         controlPoint1: NSPoint(x: left, y: top + 0.4), controlPoint2: NSPoint(x: left, y: top))
            island.close()
            island.fill()

            // Something needs you: a dot below the island.
            if pose.dot > 0.02 {
                let r = 1.35 * pose.dot
                NSBezierPath(ovalIn: NSRect(x: mid - r, y: bottom + 2.6 - r + (1 - pose.dot) * 1.5, width: r * 2, height: r * 2)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Notch"
        return image
    }
}

extension NotchModel {
    /// What the menu bar icon should show, and its tooltip.
    var statusPose: (pose: StatusIcon.Pose, tooltip: String) {
        if let wait = claudeWaits.first { return (.attention, "Notch · Claude needs you in \(wait.project)") }
        if let runaway { return (.attention, "Notch · \(runaway.name) is working hard") }
        let news = unreadNews
        if news > 0 { return (.attention, "Notch · \(news) update\(news == 1 ? "" : "s") waiting") }
        if let activity = compactActivity { return (.active, "Notch · \(activity.kind.title)") }
        return (.idle, "Notch")
    }
}
