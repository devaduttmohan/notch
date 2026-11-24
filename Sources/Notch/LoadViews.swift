import AppKit
import SwiftUI

extension Color {
    static let loadCPU = Color(red: 0.36, green: 0.80, blue: 1.0)        // cyan
    static let loadMemory = Color(red: 0.74, green: 0.52, blue: 1.0)     // violet
}

extension LoadLevel {
    /// Calm keeps the reading's own colour; busy is orange, critical red.
    func tint(_ calm: Color) -> Color {
        switch self {
        case .calm: calm
        case .busy: .orange
        case .critical: .red
        }
    }
}

private struct Reading: View {
    let text: String
    var color: Color = Color.white.opacity(0.92)
    var size: CGFloat = 12

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
            .contentTransition(.numericText())
            .animation(Motion.animation(Motion.contentSwap), value: text)
            .fixedSize()
    }
}

private func gb(_ value: Double) -> String { String(format: "%.1f", value) }

// MARK: Closed pill (numbers)

/// Left of the camera: CPU ("⌗ 23%"), or the memory chip when only memory is shown.
struct LoadPillLeading: View {
    let load: LoadSnapshot

    var body: some View {
        let show = SettingsStore.shared.value.loadShow
        HStack(spacing: 3.5) {
            Image(systemName: show == .memory ? "memorychip" : "cpu")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(show == .memory ? load.memoryLevel.tint(.loadMemory) : load.cpuLevel.tint(.loadCPU))
            if show == .both {
                Reading(text: "\(Int(load.cpu.rounded()))%", color: load.cpuLevel == .calm ? Color.white.opacity(0.92) : load.cpuLevel.tint(.white))
            }
        }
        .animation(Motion.animation(Motion.contentSwap), value: load.cpuLevel)
    }
}

/// Right of the camera: memory used ("14.2 GB"), or CPU % when only CPU is shown.
struct LoadPillTrailing: View {
    let load: LoadSnapshot

    var body: some View {
        if SettingsStore.shared.value.loadShow == .cpu {
            Reading(text: "\(Int(load.cpu.rounded()))%", color: load.cpuLevel == .calm ? Color.white.opacity(0.92) : load.cpuLevel.tint(.white))
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 2.5) {
                Reading(text: gb(load.usedGB), color: load.memoryLevel == .calm ? Color.white.opacity(0.92) : load.memoryLevel.tint(.white))
                Text("GB")
                    .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(load.memoryLevel.tint(.loadMemory))
            }
            .animation(Motion.animation(Motion.contentSwap), value: load.memoryLevel)
        }
    }
}

/// In the bubble beside the pill: CPU as a filling ring.
struct LoadBubble: View {
    let load: LoadSnapshot

    var body: some View {
        ProgressRing(fraction: load.cpu / 100, color: load.cpuLevel.tint(.loadCPU), lineWidth: 2.6)
            .frame(width: 15, height: 15)
            .animation(Motion.animation(Motion.contentSwap), value: load.cpu)
    }
}

// MARK: Open island (graphs)

/// The CPU & memory page: CPU over the last minute, memory split like Activity Monitor,
/// and your apps using the most (click one to quit it).
struct LoadExpanded: View {
    let load: LoadSnapshot
    var measured: (CGFloat) -> Void = { _ in }
    let quit: (LoadProcess) -> Void
    private let picked = State<String?>(initialValue: nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                cpu.frame(maxWidth: .infinity, alignment: .leading)
                memory.frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Your apps using the most").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("CPU").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.loadCPU.opacity(0.8))
                        .frame(width: 42, alignment: .trailing)
                    Text("Memory").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.loadMemory.opacity(0.8))
                        .frame(width: 54, alignment: .trailing)
                }
                ForEach(load.top) { process in
                    LoadProcessRow(process: process, picked: picked.wrappedValue == process.id,
                                   pick: {
                                       withAnimation(Motion.animation(Motion.contentSwap)) {
                                           picked.wrappedValue = picked.wrappedValue == process.id ? nil : process.id
                                       }
                                   },
                                   quit: {
                                       quit(process)
                                       withAnimation(Motion.animation(Motion.contentSwap)) { picked.wrappedValue = nil }
                                   })
                }
                if load.top.isEmpty {
                    Text("Looking…").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in measured(height) }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 4)
    }

    private var cpu: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("CPU").font(.system(size: 11, weight: .bold)).foregroundStyle(load.cpuLevel.tint(.loadCPU))
                Reading(text: "\(Int(load.cpu.rounded()))%", size: 20)
            }
            Text("user \(Int(load.user.rounded()))% · system \(Int(load.system.rounded()))% · \(load.cores) cores")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            CPUGraph(points: load.history, now: load.time, color: load.cpuLevel.tint(.loadCPU))
                .frame(height: 36)
                .padding(.top, 3)
            Text("last minute").font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
    }

    private var memory: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("MEMORY").font(.system(size: 11, weight: .bold)).foregroundStyle(load.memoryLevel.tint(.loadMemory))
                Reading(text: gb(load.usedGB), size: 20)
                Text("of \(Int(load.totalGB.rounded())) GB").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            }
            HStack(spacing: 5) {
                Circle().fill(load.memoryLevel.tint(.green)).frame(width: 6, height: 6)
                Text("pressure \(load.pressureName)" + (load.swapGB >= 0.05 ? " · swap \(gb(load.swapGB)) GB" : ""))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }
            MemoryBar(load: load).padding(.top, 7)
        }
    }
}

/// CPU over the last minute, as a soft line with a glow under it; time runs left to right.
private struct CPUGraph: View {
    let points: [LoadSnapshot.Point]
    let now: Date
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let window: TimeInterval = 60
            let plotted = points.map { point in
                CGPoint(x: geo.size.width * CGFloat(1 - min(window, now.timeIntervalSince(point.time)) / window),
                        y: geo.size.height * (1 - CGFloat(min(point.cpu, 100) / 100)) * 0.94 + 1)
            }
            ZStack {
                // A faint baseline, so an idle Mac still shows a graph.
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).frame(maxHeight: .infinity, alignment: .bottom)
                if plotted.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: plotted[0].x, y: geo.size.height))
                        plotted.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: plotted.last!.x, y: geo.size.height))
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.38), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { path in
                        path.move(to: plotted[0])
                        plotted.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .animation(.linear(duration: 0.9), value: points.count)
    }
}

/// Memory as Activity Monitor splits it: app, wired, compressed; the rest available.
private struct MemoryBar: View {
    let load: LoadSnapshot

    private var parts: [(name: String, gb: Double, color: Color)] {
        [("App", load.appGB, .loadMemory), ("Wired", load.wiredGB, Color(red: 1, green: 0.55, blue: 0.35)),
         ("Compressed", load.compressedGB, Color(red: 1, green: 0.8, blue: 0.3))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.name) { part in
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(part.color.gradient)
                            .frame(width: max(2, geo.size.width * part.gb / max(load.totalGB, 1)))
                    }
                    RoundedRectangle(cornerRadius: 2.5).fill(Color.white.opacity(0.13))
                }
                .animation(Motion.animation(Motion.contentSwap), value: load.usedGB)
            }
            .frame(height: 8)
            let items = parts + [("Free", load.availableGB, Color.white.opacity(0.25))]
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                ForEach([0, 2], id: \.self) { row in
                    GridRow {
                        ForEach(row..<row + 2, id: \.self) { index in
                            HStack(spacing: 4) {
                                Circle().fill(items[index].2).frame(width: 6, height: 6)
                                Text("\(items[index].0) \(gb(items[index].1))").font(.system(size: 10)).foregroundStyle(.secondary)
                                    .lineLimit(1).fixedSize()
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One app: its icon, name (and folder, for a dev server), CPU and memory. Click it and the
/// numbers give way to Quit.
private struct LoadProcessRow: View {
    let process: LoadProcess
    let picked: Bool
    let pick: () -> Void
    let quit: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            icon.frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(process.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let folder = process.folder {
                    Text(folder).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 6)
            if picked {
                Button(action: quit) {
                    Label("Quit", systemImage: "xmark.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.red.opacity(0.75).gradient))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .help(process.appPath == nil ? "Ask \(process.name) to stop" : "Quit \(process.name), like the Dock does")
                .transition(.blurReplace)
            } else {
                Reading(text: "\(Int(process.cpu.rounded()))%", color: .loadCPU, size: 11.5)
                    .frame(width: 42, alignment: .trailing)
                    .transition(.blurReplace)
                Reading(text: "\(gb(process.memoryGB)) GB", color: .loadMemory, size: 11.5)
                    .frame(width: 54, alignment: .trailing)
                    .transition(.blurReplace)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: pick)
    }

    @ViewBuilder private var icon: some View {
        if let path = process.appPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(0.14))
                .overlay(Image(systemName: "terminal.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.8)))
        }
    }
}
