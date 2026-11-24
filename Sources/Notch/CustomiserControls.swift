import SwiftUI

/// The customiser's controls, drawn by hand so they share the island's look and motion.
/// (Plain `State<T>` properties instead of `@State`: see NotchView.)
enum Palette {
    static let window = Color(red: 0.035, green: 0.035, blue: 0.045)
    static let sidebar = Color(white: 0.075)
    static let card = Color.white.opacity(0.045)
    static let cardStroke = Color.white.opacity(0.075)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.36)
    static let blue = Color(red: 0.04, green: 0.52, blue: 1.0)

    /// The accent picked for the island, or blue on Automatic.
    @MainActor static var tint: Color { SettingsStore.shared.value.accent.color ?? blue }
}

/// Springs for the customiser itself.
enum UISpring {
    static let snap = Animation.spring(Spring(duration: 0.32, bounce: 0.22))
    static let soft = Animation.spring(Spring(duration: 0.45, bounce: 0.12))
}

// MARK: - Switch

/// An iOS-style switch: the knob stretches while pressed and springs across.
struct NToggle: View {
    @Binding var isOn: Bool
    var tint: Color = Palette.blue
    private let pressed = State(initialValue: false)

    var body: some View {
        let knob: CGFloat = 20
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? tint : Color.white.opacity(0.16))
            Capsule()
                .fill(Color.white)
                .frame(width: knob + (pressed.wrappedValue ? 6 : 0), height: knob)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .padding(2)
        }
        .frame(width: 42, height: 24)
        .contentShape(Capsule())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !pressed.wrappedValue { pressed.wrappedValue = true } }
            .onEnded { _ in
                pressed.wrappedValue = false
                withAnimation(UISpring.snap) { isOn.toggle() }
            })
        .animation(UISpring.snap, value: isOn)
        .animation(UISpring.snap, value: pressed.wrappedValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: - Segmented picker

/// Options in a capsule; the selection is a lit pill that slides between them.
struct NSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Text(option.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.white : Palette.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color.white.opacity(0.17))
                                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "selection", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(UISpring.snap) { selection = option.value } }
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.05)))
    }
}

// MARK: - Slider

/// A bar with the island's own seek thumb: grows when grabbed, glides to a tap.
struct NSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    var tint: Color = Palette.blue
    private let dragging = State(initialValue: false)

    var body: some View {
        GeometryReader { geo in
            let inset = SeekThumb.activeSize.width / 2
            let usable = max(1, geo.size.width - inset * 2)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let x = inset + usable * CGFloat(min(max(fraction, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                    .frame(width: usable, height: 5)
                    .offset(x: inset)
                Capsule().fill(tint)
                    .frame(width: max(5, x - inset), height: 5)
                    .offset(x: inset)
                SeekThumb(active: dragging.wrappedValue)
                    .position(x: x, y: geo.size.height / 2)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let first = !dragging.wrappedValue
                    dragging.wrappedValue = true
                    var new = range.lowerBound + Double(min(max((drag.location.x - inset) / usable, 0), 1))
                        * (range.upperBound - range.lowerBound)
                    if step > 0 { new = (new / step).rounded() * step }
                    // A tap glides there; a drag follows the pointer exactly.
                    withAnimation(first ? UISpring.soft : nil) { value = new }
                }
                .onEnded { _ in dragging.wrappedValue = false })
            .animation(Motion.animation(Motion.grow), value: dragging.wrappedValue)
        }
        .frame(height: 22)
    }
}

// MARK: - Layout pieces

/// A rounded group of settings.
struct NCard<Content: View>: View {
    var title: String? = nil
    var symbol: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(spacing: 7) {
                    if let symbol {
                        SymbolImage(symbol, size: 11, weight: .bold)
                            .foregroundStyle(Palette.secondary)
                    }
                    Text(title.uppercased())
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(Palette.secondary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.cardStroke))
    }
}

/// A label on the left, a control on the right.
struct NRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
    }
}

/// A coloured rounded square with a white symbol, like System Settings' sidebar.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(color.gradient)
            .overlay {
                SymbolImage(symbol, size: size * 0.5)
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.35), radius: 4, y: 1)
    }
}

/// A capsule button in the customiser's style.
struct NButton: View {
    let title: String
    var symbol: String? = nil
    var prominent = false
    var tint: Color = Palette.blue
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { SymbolImage(symbol, size: 11, weight: .bold) }
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(Capsule().fill(prominent ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.white.opacity(0.12))))
            .overlay(Capsule().strokeBorder(Color.white.opacity(prominent ? 0.18 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

/// − 8 s +, in the segmented control's capsule, stepping through `steps`; the number rolls as
/// it changes. Dimmed, not hidden, while it doesn't apply.
struct NSecondsStepper: View {
    @Binding var value: Double
    let steps: [Double]
    var enabled = true

    var body: some View {
        let index = steps.indices.min { abs(steps[$0] - value) < abs(steps[$1] - value) } ?? 0
        HStack(spacing: 0) {
            step(-1, from: index, symbol: "minus")
            Text(Self.label(value))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText(value: value))
                .frame(minWidth: 44)
            step(1, from: index, symbol: "plus")
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.05)))
        .opacity(enabled ? 1 : 0.35)
        .allowsHitTesting(enabled)
        .animation(UISpring.snap, value: enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Seconds")
        .accessibilityValue(Self.label(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(1, from: index)
            case .decrement: move(-1, from: index)
            @unknown default: break
            }
        }
    }

    private func step(_ by: Int, from index: Int, symbol: String) -> some View {
        let possible = steps.indices.contains(index + by)
        return Button { move(by, from: index) } label: {
            SymbolImage(symbol, size: 10, weight: .bold)
                .frame(width: 26, height: 28)
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(possible ? Color.white : Palette.secondary)
        .disabled(!possible)
    }

    private func move(_ by: Int, from index: Int) {
        guard steps.indices.contains(index + by) else { return }
        withAnimation(UISpring.snap) { value = steps[index + by] }
    }

    /// 0 is Auto: each alert's own time.
    static func label(_ seconds: Double) -> String {
        guard seconds > 0 else { return "Auto" }
        let whole = Int(min(seconds, 86_400).rounded())
        return whole >= 60 && whole % 60 == 0 ? "\(whole / 60) min" : "\(whole) s"
    }
}

/// A row of colour dots; the chosen one gets a ring that springs in.
struct AccentPicker: View {
    @Binding var selection: AccentChoice

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AccentChoice.allCases) { choice in
                let selected = choice == selection
                ZStack {
                    Circle()
                        .strokeBorder(Color.white.opacity(selected ? 0.9 : 0), lineWidth: 2)
                        .frame(width: 30, height: 30)
                        .scaleEffect(selected ? 1 : 0.7)
                    Group {
                        if let color = choice.color {
                            Circle().fill(color.gradient)
                        } else {
                            Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .teal, .blue, .purple, .pink, .red],
                                                          center: .center))
                        }
                    }
                    .frame(width: 22, height: 22)
                    .shadow(color: (choice.color ?? .white).opacity(0.4), radius: selected ? 5 : 0)
                }
                .contentShape(Circle())
                .onTapGesture { withAnimation(UISpring.snap) { selection = choice } }
                .help(choice.name)
                .animation(UISpring.snap, value: selected)
            }
        }
    }
}

/// A tile you pick from a row of them: lifts and outlines when chosen.
struct ChoiceTile<Preview: View>: View {
    let title: String
    let detail: String
    let selected: Bool
    var tint: Color = Palette.blue
    let action: () -> Void
    @ViewBuilder let preview: Preview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.black.opacity(0.55)))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(Palette.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(selected ? 0.09 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(selected ? tint : Color.white.opacity(0.06), lineWidth: selected ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, tint)
                    .padding(6)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .scaleEffect(selected ? 1 : 0.985)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { withAnimation(UISpring.snap) { action() } }
        .animation(UISpring.snap, value: selected)
    }
}
