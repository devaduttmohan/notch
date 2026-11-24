import AppKit

/// Keeps the overlay on screen through Space switches and full-screen apps.
///
/// Supported APIs can't: a window always belongs to some Space, and macOS slides Spaces in
/// and out, so the overlay vanished for the length of every swipe. The window server
/// (SkyLight, a private framework) can make a Space of our own that sits above all the
/// others and never moves, the way macOS keeps its own volume and brightness pop-ups up.
/// Notch puts its panel in it. Nothing is injected anywhere and no permission is involved:
/// Notch only tells the window server where its own window lives.
///
/// The functions are undocumented, so each is looked up when Notch starts. If a macOS update
/// renames or drops one, `make()` returns nil, the reason is logged, and the panel keeps the
/// supported behaviour (moving into each Space after the switch).
@MainActor final class PinnedSpace {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpaceSetLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias SpacesCall = @convention(c) (Int32, CFArray) -> Int32
    private typealias WindowsCall = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias SpaceDestroy = @convention(c) (Int32, UInt64) -> Int32

    /// Above every Space, full-screen ones included (the level other notch apps use).
    private static let level: Int32 = .max

    private let connection: Int32
    private let space: UInt64
    private let addWindows: WindowsCall
    private let removeWindows: WindowsCall
    private let hideSpaces: SpacesCall
    private let destroySpace: SpaceDestroy
    private(set) var windows: Set<Int> = []

    /// Our own Space, shown and ready for windows; nil (with the reason logged) when this
    /// macOS doesn't offer what it needs.
    static func make() -> PinnedSpace? {
        let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        /// The SkyLight name, or the older CoreGraphics alias for it.
        func find<T>(_ names: String..., as type: T.Type) -> T? {
            for name in names {
                if let skyLight, let symbol = dlsym(skyLight, name) { return unsafeBitCast(symbol, to: type) }
                if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) { return unsafeBitCast(symbol, to: type) }  // RTLD_DEFAULT
            }
            return nil
        }
        guard let main = find("SLSMainConnectionID", "_CGSDefaultConnection", as: MainConnection.self),
              let create = find("SLSSpaceCreate", "CGSSpaceCreate", as: SpaceCreate.self),
              let setLevel = find("SLSSpaceSetAbsoluteLevel", "CGSSpaceSetAbsoluteLevel", as: SpaceSetLevel.self),
              let show = find("SLSShowSpaces", "CGSShowSpaces", as: SpacesCall.self),
              let hide = find("SLSHideSpaces", "CGSHideSpaces", as: SpacesCall.self),
              let add = find("SLSAddWindowsToSpaces", "CGSAddWindowsToSpaces", as: WindowsCall.self),
              let remove = find("SLSRemoveWindowsFromSpaces", "CGSRemoveWindowsFromSpaces", as: WindowsCall.self),
              let destroy = find("SLSSpaceDestroy", "CGSSpaceDestroy", as: SpaceDestroy.self) else {
            log("overlay: this macOS doesn't offer a pinned Space; keeping the usual Space handling")
            return nil
        }
        let connection = main()
        // 1 = a plain Space (other values make Finder draw desktop icons into it).
        let space = create(connection, 1, nil)
        guard connection != 0, space != 0 else {
            log("overlay: the window server didn't make a pinned Space (connection \(connection)); keeping the usual Space handling")
            return nil
        }
        let levelError = setLevel(connection, space, level)
        let showError = show(connection, [NSNumber(value: space)] as CFArray)
        log("overlay: made a pinned Space above every other (level \(levelError == 0 ? "set" : "error \(levelError)"), "
            + "shown \(showError == 0 ? "yes" : "error \(showError)"))")
        return PinnedSpace(connection: connection, space: space, add: add, remove: remove, hide: hide, destroy: destroy)
    }

    private init(connection: Int32, space: UInt64, add: @escaping WindowsCall, remove: @escaping WindowsCall,
                 hide: @escaping SpacesCall, destroy: @escaping SpaceDestroy) {
        self.connection = connection
        self.space = space
        self.addWindows = add
        self.removeWindows = remove
        self.hideSpaces = hide
        self.destroySpace = destroy
    }

    func pin(_ window: NSWindow) {
        guard window.windowNumber > 0 else { return }
        addWindows(connection, [NSNumber(value: window.windowNumber)] as CFArray, [NSNumber(value: space)] as CFArray)
        windows.insert(window.windowNumber)
    }

    func unpin(_ window: NSWindow) {
        guard windows.remove(window.windowNumber) != nil else { return }
        removeWindows(connection, [NSNumber(value: window.windowNumber)] as CFArray, [NSNumber(value: space)] as CFArray)
    }

    /// Takes the Space down (switched off in the customiser).
    func close() {
        let ids = windows.map { NSNumber(value: $0) } as CFArray
        if !windows.isEmpty { removeWindows(connection, ids, [NSNumber(value: space)] as CFArray) }
        windows.removeAll()
        _ = hideSpaces(connection, [NSNumber(value: space)] as CFArray)
        _ = destroySpace(connection, space)
    }
}
