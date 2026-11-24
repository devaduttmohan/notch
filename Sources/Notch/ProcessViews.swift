import AppKit
import SwiftUI

/// The runaway process in the pill: its app icon if it has one, else a flame tile.
struct ProcessGlyph: View {
    let process: RunawayProcess
    let size: CGFloat

    var body: some View {
        Group {
            if let icon = NSRunningApplication(processIdentifier: process.pid)?.icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(LinearGradient(colors: [.orange, .red], startPoint: .top, endPoint: .bottom))
                    .overlay {
                        Image(systemName: process.reason == .cpu ? "flame.fill" : "memorychip.fill")
                            .font(.system(size: size * 0.52, weight: .bold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
    }
}

/// Right side of the pill: how hard it's working ("320%", "9.1 GB"), digits rolling.
struct ProcessLoad: View {
    let process: RunawayProcess

    var body: some View {
        let label = process.reason == .cpu ? "\(Int(process.cpu.rounded()))%" : String(format: "%.1f GB", process.memoryGB)
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color.orange)
            .contentTransition(.numericText())
            .animation(Motion.animation(Motion.contentSwap), value: label)
            .fixedSize()
    }
}

/// The open island for a runaway process: what, where, a live CPU sparkline, and what to do.
struct ProcessExpanded: View {
    let process: RunawayProcess
    let ns: Namespace.ID
    let act: (ProcessAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ProcessGlyph(process: process, size: 44)
                    .matchedGeometryEffect(id: "leading", in: ns)
                VStack(alignment: .leading, spacing: 2) {
                    Text(process.reason == .cpu ? "\(process.name) is working hard" : "\(process.name) is using a lot of memory")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(stats)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(Motion.animation(Motion.contentSwap), value: stats)
                    Text(process.folder ?? "pid \(process.pid)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Sparkline(values: process.history)
                    .frame(width: 70, height: 30)
            }
            HStack(spacing: 8) {
                Spacer()
                IconButton(symbol: "eye.slash", label: "Never warn about \(process.name)") { act(.ignore) }
                PillButton(symbol: "moon.zzz.fill", title: "Not now") { act(.snooze) }
                if process.quitting {
                    QuitButton(title: "Force Quit", symbol: "xmark.octagon.fill") { act(.forceQuit) }
                        .transition(.blurReplace)
                } else {
                    QuitButton(title: "Quit", symbol: "xmark.circle.fill") { act(.quit) }
                        .transition(.blurReplace)
                }
            }
            .animation(Motion.animation(Motion.contentSwap), value: process.quitting)
        }
    }

    private var stats: String {
        let minutes = max(2, Int(Date().timeIntervalSince(process.since) / 60))
        return "\(Int(process.cpu.rounded()))% CPU · " + String(format: "%.1f GB", process.memoryGB) + " · for \(minutes) min"
    }
}

/// A red-tinted capsule for stopping something.
private struct QuitButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.red.opacity(0.75).gradient))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

/// CPU over the last few minutes, as a soft orange line with a glow under it.
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let points = Self.points(values, in: geo.size)
            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                    }
                    .fill(LinearGradient(colors: [Color.orange.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .animation(Motion.animation(Motion.contentSwap), value: values)
    }

    private static func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
        let recent = Array(values.suffix(36))
        guard recent.count > 1 else { return [] }
        let top = max(recent.max() ?? 100, 100)
        return recent.enumerated().map { index, value in
            CGPoint(x: size.width * CGFloat(index) / CGFloat(recent.count - 1),
                    y: size.height * (1 - CGFloat(value / top)) * 0.92 + 1)
        }
    }
}

/// ☕ in the open island: keeps the Mac awake on a click; glows while anything holds it awake.
struct KeepAwakeButton: View {
    let state: AwakeState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state.on ? "cup.and.heat.waves.fill" : "cup.and.saucer")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(state.on ? Color.orange : Color.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
                .background(Circle().fill(state.manual ? Color.orange.opacity(0.28) : Color.white.opacity(0.14)))
                .overlay(Circle().strokeBorder(Color.orange.opacity(state.manual ? 0.6 : 0), lineWidth: 1))
                .shadow(color: .orange.opacity(state.on ? 0.55 : 0), radius: state.on ? 6 : 0)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .animation(Motion.animation(Motion.contentSwap), value: state)
        .help(state.manual ? "Stop keeping the Mac awake" : state.on ? (state.why ?? "Keeping awake") : "Keep the Mac awake")
    }
}
