import AppKit
import Combine
import SwiftUI

/// Borderless panel above the menu bar that never activates the app.
final class NotchPanel: NSPanel {
    convenience init(frame: NSRect) {
        self.init(contentRect: frame,
                  styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = Self.onEverySpace
        isMovable = false
        acceptsMouseMovedEvents = true
        // Panels hide whenever their app stops being the active app, which happens every
        // time you switch Spaces or full-screen apps. The overlay must stay put.
        hidesOnDeactivate = false
    }

    /// Normal: on every Space, staying put while you swipe between desktops. But a
    /// full-screen app's Space doesn't show other apps' "every Space" windows...
    static let onEverySpace: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    /// ...so there the panel moves into the current Space instead (like a hotkey window).
    static let followCurrentSpace: NSWindow.CollectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]

    // Lets SwiftUI buttons take clicks; .nonactivatingPanel keeps the frontmost app active.
    override var canBecomeKey: Bool { true }
}

/// Takes the first click even though the panel isn't key yet.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the panel and turns the mouse position into hover state.
@MainActor final class NotchController {
    let model: NotchModel
    private let panel: NotchPanel
    private var monitors: [Any] = []
    private var observers: [any NSObjectProtocol] = []
    private var followingCurrentSpace = false
    private var holdTimer: DispatchWorkItem?
    private var armedPage: ActivityKind?        // armed from the bubble: open on its page
    private var swipe: CGFloat = 0
    private var swipeUsed = false
    private var settingsWatch: AnyCancellable?
    private var display = SettingsStore.shared.value.display

    init(model: NotchModel) {
        self.model = model
        panel = NotchPanel(frame: model.layout.panelFrame)
        let hosting = NotchHostingView(rootView: NotchView(model: model))
        hosting.sizingOptions = []          // don't let SwiftUI resize the panel
        panel.contentView = hosting
        panel.orderFrontRegardless()

        // The global monitor sees moves sent to other apps; the local one covers our own panel.
        // Mouse-move monitors need no Accessibility permission (key monitors do).
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return event
        }) { monitors.append(local) }
        // Two-finger swipe across the open island turns its pages.
        if let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.scrolled(event) }
            return event
        }) { monitors.append(scroll) }
        // "Open on click": the panel takes clicks only while the pointer is on the island.
        if let click = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.model.armed, SettingsStore.shared.value.openOn == .click else { return }
                self.open(page: self.armedPage)
            }
            return event
        }) { monitors.append(click) }

        // A different display, or a different way to open, in the customiser.
        settingsWatch = SettingsStore.shared.$value.dropFirst().sink { [weak self] new in
            MainActor.assumeIsolated {
                guard let self else { return }
                if new.display != self.display {
                    self.display = new.display
                    DispatchQueue.main.async { self.screensChanged() }
                }
                if new.openOn != SettingsStore.shared.value.openOn {
                    self.disarm()
                    DispatchQueue.main.async { self.updateClickThrough() }
                }
            }
        }

        // Lid closed, monitor plugged in, scaling changed: re-read the notch.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })

        // Switched Space or full-screen app: make sure the overlay is still in front.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChanged() }
        })
        // Diagnostics: the app becoming inactive is what used to hide the panel.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            log("app stopped being active (this used to hide the overlay)")
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                log("overlay \(self.panel.occlusionState.contains(.visible) ? "visible" : "hidden by the system")"
                    + " (front app: \(front), on this Space: \(self.panel.isOnActiveSpace), "
                    + "\(self.followingCurrentSpace ? "following the current Space" : "on every Space"))")
            }
        })

        updateClickThrough()
    }

    private func mouseMoved() {
        let point = NSEvent.mouseLocation
        let layout = model.layout
        // The zone to leave is bigger than the zone to enter, so the edge doesn't flicker.
        if model.hovering {
            let zone = layout.screenRect(for: .expanded, kind: model.expandedKind).insetBy(dx: -12, dy: -12)
            if !zone.contains(point) { close() }
            return
        }
        let onPill = layout.screenRect(for: model.restingState).insetBy(dx: -6, dy: -6).contains(point)
        // The bubble beside the pill opens the island on its own activity's page.
        let bubble = model.restingState == .compact ? model.secondaryActivity?.kind : nil
        let onBubble = bubble != nil && layout.bubbleRect().insetBy(dx: -4, dy: -6).contains(point)
        let inside = onPill || onBubble
        let page = onBubble ? bubble : nil
        switch SettingsStore.shared.value.openOn {
        case .hover:
            if inside { open(page: page) }
        case .hold:
            // Swell first; open if the pointer is still there a moment later.
            if inside, !model.armed {
                model.armed = true
                armedPage = page
                let wait = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { if self?.model.armed == true { self?.open(page: self?.armedPage) } }
                }
                holdTimer = wait
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: wait)
            } else if !inside, model.armed {
                disarm()
            }
        case .click:
            if inside != model.armed {
                model.armed = inside
                armedPage = page
                updateClickThrough()
            }
        }
    }

    private func open(page: ActivityKind? = nil) {
        disarm()
        if let page { model.select(page: page) }
        model.hovering = true
        Haptics.tap(.levelChange)
        updateClickThrough()
    }

    private func close() {
        model.hovering = false
        updateClickThrough()
    }

    /// One page per swipe, whichever way the fingers went (natural scrolling or not).
    private func scrolled(_ event: NSEvent) {
        guard model.state == .expanded, event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.began) { swipe = 0; swipeUsed = false }
        let fingers = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 0.8 || abs(swipe) > 0 else { return }
        swipe += fingers
        if !swipeUsed, abs(swipe) > 48 {
            swipeUsed = true
            withAnimation(Motion.animation(Motion.contentSwap)) { model.turnPage(by: swipe < 0 ? 1 : -1) }
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { swipe = 0; swipeUsed = false }
    }

    private func disarm() {
        holdTimer?.cancel()
        holdTimer = nil
        model.armed = false
    }

    /// Clicks pass through to the menu bar unless the panel is open (or, with "open on
    /// click", the pointer is on the island).
    private func updateClickThrough() {
        let clickable = model.state == .expanded || (model.armed && SettingsStore.shared.value.openOn == .click)
        panel.ignoresMouseEvents = !clickable
    }

    private func spaceChanged() {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        panel.orderFrontRegardless()
        // Visibility updates a beat after the switch; check then.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated { self?.ensureVisible(front: front, attempt: 0) }
        }
    }

    /// After a Space switch the overlay must be showing. If it isn't: coming back from a
    /// full-screen Space, rejoin every Space; landing on one, move into it. Checked again
    /// after each step, and logged, so a failure shows exactly where.
    private func ensureVisible(front: String, attempt: Int) {
        let showing = panel.isOnActiveSpace && panel.occlusionState.contains(.visible)
        if showing {
            log("space changed (front app: \(front)): overlay showing\(followingCurrentSpace ? " (inside this full-screen Space)" : "")")
            return
        }
        guard attempt < 2 else {
            log("space changed (front app: \(front)): overlay STILL hidden after re-placing it")
            return
        }
        let rejoin = attempt == 0 && followingCurrentSpace && !panel.isOnActiveSpace
        place(followingCurrentSpace: !rejoin)
        log("space changed (front app: \(front)): overlay was hidden, \(rejoin ? "rejoined every Space" : "moved it into this Space")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated { self?.ensureVisible(front: front, attempt: attempt + 1) }
        }
    }

    private func place(followingCurrentSpace follow: Bool) {
        followingCurrentSpace = follow
        panel.collectionBehavior = follow ? NotchPanel.followCurrentSpace : NotchPanel.onEverySpace
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        model.reappear &+= 1          // the pill grows back out of the notch
    }

    private func screensChanged() {
        model.layout = NotchLayout.current()
        panel.setFrame(model.layout.panelFrame, display: true)
    }
}
