import AppKit
import SwiftUI

// MARK: - Background

/// What fills the island. The top always stays pure black, so the shape still reads as one
/// with the hardware notch; the styles differ in what happens lower down as it opens.
/// `glow` is how open the island is (0 closed, 1 open), so a closed pill stays black.
struct IslandBackground: View {
    let style: BackgroundStyle
    let tint: Color
    let glow: Double
    var topFade: CGFloat = 46                 // how far down the top stays black
    /// A video's still, while its page is open: softly blurred behind the island, over the
    /// chosen style, fading to black towards the controls.
    var backdrop: NSImage? = nil

    var body: some View {
        ZStack {
            Color.black
            switch style {
            case .midnight:
                EmptyView()
            case .graphite:
                LinearGradient(stops: [.init(color: .black, location: 0.3),
                                       .init(color: Color(white: 0.16), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .opacity(glow)
                    .transition(.opacity)
            case .ambient:
                GeometryReader { geo in
                    RadialGradient(colors: [tint.opacity(0.55), tint.opacity(0.16), .clear],
                                   center: .bottom, startRadius: 0,
                                   endRadius: max(geo.size.width, geo.size.height) * 0.62)
                        .scaleEffect(x: 1.3, y: 1, anchor: .bottom)
                }
                .opacity(glow)
                .transition(.opacity)
            case .aurora:
                Aurora(tint: tint)
                    .opacity(glow)
                    .transition(.opacity)
            }
            if let backdrop {
                CinemaBackdrop(image: backdrop)
                    .opacity(glow)
                    .transition(.opacity)
                    .id(ObjectIdentifier(backdrop))      // a new still cross-fades in
            }
        }
        .animation(Motion.animation(Motion.contentSwap), value: backdrop.map(ObjectIdentifier.init))
        // Keep the top black wherever the light comes from.
        .overlay(alignment: .top) {
            LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: topFade)
                .allowsHitTesting(false)
        }
    }
}

/// A video's still, blurred and dimmed, darkest at the bottom where the controls are.
private struct CinemaBackdrop: View {
    let image: NSImage

    var body: some View {
        GeometryReader { geo in
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .blur(radius: 22, opaque: true)
                .opacity(0.6)
                .overlay(LinearGradient(stops: [.init(color: .black.opacity(0.1), location: 0),
                                                .init(color: .black.opacity(0.55), location: 0.55),
                                                .init(color: .black.opacity(0.92), location: 1)],
                                        startPoint: .top, endPoint: .bottom))
        }
        .allowsHitTesting(false)
    }
}

/// Soft colour light drifting slowly along the bottom of the open island.
private struct Aurora: View {
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
            let t = context.date.timeIntervalSinceReferenceDate / Motion.slowdown
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    blob(tint, w * 0.75, h * 0.9)
                        .offset(x: CGFloat(sin(t * 0.37)) * w * 0.22, y: h * 0.42 + CGFloat(cos(t * 0.29)) * h * 0.06)
                    blob(tint.rotatedHue(0.12), w * 0.6, h * 0.8)
                        .offset(x: CGFloat(cos(t * 0.31 + 1.7)) * w * 0.26, y: h * 0.48)
                    blob(tint.rotatedHue(-0.14), w * 0.5, h * 0.7)
                        .offset(x: CGFloat(sin(t * 0.23 + 3.1)) * w * 0.3, y: h * 0.52 + CGFloat(sin(t * 0.41)) * h * 0.05)
                }
                .frame(width: w, height: h)
                .blur(radius: 28)
            }
        }
    }

    private func blob(_ color: Color, _ width: CGFloat, _ height: CGFloat) -> some View {
        Ellipse().fill(color.opacity(0.42)).frame(width: width, height: height)
    }
}

/// A hairline that catches the light along the island's lower edge, like the bevel on
/// Apple's dark glass. Fades out towards the top so it never outlines the notch.
struct EdgeHighlight<S: Shape>: View {
    let shape: S
    let strength: Double

    var body: some View {
        shape
            .stroke(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.07), .white.opacity(0.2)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1.5)
            .opacity(strength)
            .allowsHitTesting(false)
    }
}

// MARK: - Colour

extension Color {
    /// The accent the customiser picked, or this activity's own colour on Automatic.
    @MainActor static func accent(or fallback: Color) -> Color {
        SettingsStore.shared.value.accent.color ?? fallback
    }

    /// The same colour with its hue turned a little (for Aurora's second and third lights).
    func rotatedHue(_ amount: Double) -> Color {
        let color = NSColor(self).usingColorSpace(.deviceRGB) ?? .systemTeal
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let hue = (h + CGFloat(amount)).truncatingRemainder(dividingBy: 1)
        return Color(hue: Double(hue < 0 ? hue + 1 : hue), saturation: Double(s), brightness: Double(b))
    }
}

/// An RGB colour that can cross threads.
struct RGB: Equatable, Sendable {
    var red: Double, green: Double, blue: Double
    var color: Color { Color(red: red, green: green, blue: blue) }
}

/// The colour of album art, for the Ambient and Aurora backgrounds and the glow.
enum ArtworkColor {
    /// The image's dominant colour, nudged brighter and richer so it reads as light on black.
    /// Colourful pixels count for more than greys, so a bright cover on a white
    /// background still gives its colour.
    nonisolated static func dominant(of data: Data) -> RGB? {
        guard let image = NSImage(data: data) else { return nil }
        return dominant(of: image)
    }

    nonisolated static func dominant(of image: NSImage) -> RGB? {
        var rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let pr = Double(pixels[i]) / 255, pg = Double(pixels[i + 1]) / 255, pb = Double(pixels[i + 2]) / 255
            let high = max(pr, pg, pb), low = min(pr, pg, pb)
            let weight = 0.08 + (high - low) * 2 + high * 0.2     // colourful and bright pixels lead
            r += pr * weight; g += pg * weight; b += pb * weight; total += weight
        }
        guard total > 0 else { return nil }
        let color = NSColor(deviceRed: r / total, green: g / total, blue: b / total, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let vivid = NSColor(deviceHue: h, saturation: min(1, s * 1.35 + 0.08), brightness: max(v, 0.82), alpha: 1)
        return RGB(red: Double(vivid.redComponent), green: Double(vivid.greenComponent), blue: Double(vivid.blueComponent))
    }
}

extension NotchModel {
    /// The waveform's colour: the accent, else the album art's, else teal (like iOS).
    var waveformTint: Color {
        SettingsStore.shared.value.accent.color ?? artworkTint?.color ?? .teal
    }

    /// The colour the island glows with: the accent if one is picked, otherwise whatever is
    /// showing (album art, Claude orange, the timer's orange, the meeting's calendar…).
    var ambientTint: Color {
        if let accent = SettingsStore.shared.value.accent.color { return accent }
        if state == .banner, let banner = displayedBanner {
            return banner.tint == .white ? Color(white: 0.85) : banner.tint.color
        }
        let activity = state == .expanded ? expandedActivity : compactActivity
        switch activity {
        case .nowPlaying: return artworkTint?.color ?? .teal
        case .timer: return .orange
        case .claude, .claudeUpdate, .claudeBackground: return .claude
        case .meeting(let meeting): return meeting.color.color
        case .process: return .orange
        case .pullRequests(let summary): return summary.needsYou ? .red : .prGreen
        case .builds(let summary): return summary.running.isEmpty && summary.unseenFailure ? .red : .buildBlue
        case .load(let load): return load.busy ? (load.cpuLevel == .critical || load.memoryLevel == .critical ? .red : .orange) : .loadCPU
        case .home, nil: return Color(red: 0.36, green: 0.42, blue: 1)
        }
    }
}
