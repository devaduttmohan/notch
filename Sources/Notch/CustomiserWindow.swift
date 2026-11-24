import AppKit
import SwiftUI

/// The customiser: a dark window in the island's style with a live preview. While it's
/// open Notch shows in the Dock and the app switcher like any app; closing it puts Notch
/// back to living only in the notch and the menu bar.
@MainActor final class Customiser: NSObject, NSWindowDelegate {
    private let meetings: Meetings
    private let keepAwake: KeepAwake
    private let prs: PRWatcher
    private var window: NSWindow?
    private var director: PreviewDirector?

    init(meetings: Meetings, keepAwake: KeepAwake, prs: PRWatcher) {
        self.meetings = meetings
        self.keepAwake = keepAwake
        self.prs = prs
    }

    /// Opens the customiser; on `pane` if given (an open window switches to it), otherwise
    /// where you left it.
    func show(pane: Pane? = nil) {
        if window == nil { build(pane: pane ?? .appearance) }
        else if let pane { NotificationCenter.default.post(name: CustomiserView.showPane, object: pane.rawValue) }
        NSApp.setActivationPolicy(.regular)
        if let icon = AppIconArt.image(size: 512) { NSApp.applicationIconImage = icon }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func build(pane: Pane) {
        let director = PreviewDirector()
        let root = CustomiserView(store: .shared, meetings: meetings, keepAwake: keepAwake, prs: prs, director: director,
                                  login: LoginItem(), startOn: pane)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Customise Notch"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Palette.window)
        window.minSize = NSSize(width: 860, height: 640)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .documentWindow          // zooms open like a document
        window.delegate = self
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.setFrameAutosaveName("NotchCustomiser")
        self.window = window
        self.director = director
    }

    func windowWillClose(_ notification: Notification) {
        director?.touring = false
        // Drop the preview (it animates) and go back to being an accessory app.
        window?.contentView = nil
        window = nil
        director = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
