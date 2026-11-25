import AppKit
import SwiftUI

// The Mac offline, or a VPN you use down: Wi-Fi or a shield crossed out, in orange, and how
// long it's been.

/// The mark, in the pill and the bubble.
struct NetworkGlyph: View {
    let trouble: NetworkTrouble
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: trouble.symbol)
            .font(.system(size: size * 0.66, weight: .semibold))
            .foregroundStyle(.orange)
            .frame(width: size, height: size)
    }
}

/// Right of the pill: how long it's been down ("45s", "6m"), rounded down.
struct NetworkDownTime: View {
    let trouble: NetworkTrouble

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let text = BackgroundTime.elapsed(context.date.timeIntervalSince(trouble.since))
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.9))
                .contentTransition(.numericText())
                .animation(Motion.animation(Motion.contentSwap), value: text)
                .fixedSize()
        }
    }
}

/// The open island: what's down, since when, what that means, and Dismiss (until it's back).
struct NetworkExpanded: View {
    let trouble: NetworkTrouble
    let ns: Namespace.ID
    let dismiss: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.orange.opacity(0.16))
                        .overlay { NetworkGlyph(trouble: trouble, size: 30) }
                        .frame(width: 44, height: 44)
                        .matchedGeometryEffect(id: "leading", in: ns)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trouble.title)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Text("Since " + trouble.since.formatted(date: .omitted, time: .shortened) + " · "
                             + CommandAlerts.duration(context.date.timeIntervalSince(trouble.since)))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(trouble.kind == .offline ? "PRs and builds catch up when you're back" : "VPN · sites that need it won't load")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                HStack(spacing: 8) {
                    Spacer()
                    PillButton(symbol: "checkmark", title: "Dismiss", action: dismiss)
                        .help("Hide this until it's back")
                    if case .vpn(_, let app?) = trouble.kind {
                        PillButton(symbol: "arrow.up.forward.app", title: "Open " + app.deletingPathExtension().lastPathComponent) {
                            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                        }
                    } else {
                        PillButton(symbol: "gearshape.fill", title: "Network Settings") { NetworkWatch.openNetworkSettings() }
                    }
                }
            }
        }
    }
}
