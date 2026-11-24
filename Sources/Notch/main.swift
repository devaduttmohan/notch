import AppKit
import SwiftUI

// bin/notch: draw the app icon into an .iconset folder, then quit.
if let flag = CommandLine.arguments.firstIndex(of: "--write-iconset"), flag + 1 < CommandLine.arguments.count {
    let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
        let pixels = CGFloat(points * scale)
        guard let image = MainActor.assumeIsolated({ AppIconArt.image(size: pixels) }),
              let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { continue }
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try? png.write(to: folder.appendingPathComponent(name))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon
app.run()
