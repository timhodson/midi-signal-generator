import AppKit
import Controls
import SwiftUI

/// How the app looks. "System" is plain macOS; "Studio" is the hardware-style skin (roadmap: a
/// hardware-style skin), drawn in code over textures generated on the local ComfyUI (art/textures.md).
/// Every page follows it: shared pieces (VisualCard, SkinBox, knobs, LED buttons) switch on `\.skin`.
enum SkinStyle: String, CaseIterable, Identifiable {
    case system = "System", studio = "Studio"
    var id: String { rawValue }
}

private struct SkinKey: EnvironmentKey {
    static let defaultValue = SkinStyle.system
}

extension EnvironmentValues {
    var skin: SkinStyle {
        get { self[SkinKey.self] }
        set { self[SkinKey.self] = newValue }
    }
}

/// The skin's textures and type, loaded once from the app's resources.
@MainActor
enum Studio {
    /// 1024 px drawn as a 512 pt tile: fine grain on Retina.
    static let panel: NSImage? = {
        guard let img = image("panel") else { return nil }
        img.size = NSSize(width: 512, height: 512)
        return img
    }()
    static let knobCap = image("knob-cap")
    static let lcd = image("lcd")

    static let lcdText = Color(red: 0.72, green: 0.90, blue: 0.62)
    static let label = Color(white: 0.78)

    private static func image(_ name: String) -> NSImage? {
        Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Skin").flatMap(NSImage.init(contentsOf:))
    }

    /// Small capitals in a technical face, like the panel legends on hardware.
    static func legend(_ size: CGFloat = 10, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// The grainy charcoal panel, tiled, with a bevel: light along the top edge, dark along the bottom.
struct PanelBackground: View {
    var cornerRadius: CGFloat = 8
    var shade: Double = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        ZStack {
            if let img = Studio.panel {
                Image(nsImage: img).resizable(resizingMode: .tile)
            } else {
                Color(white: 0.17)
            }
            Color.black.opacity(shade)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.14), .clear, .black.opacity(0.55)],
                                                   startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
    }
}

/// A backlit monochrome LCD: the generated glass, a recessed bezel, glowing pale-green text.
struct LCDScreen: View {
    let lines: [String]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                // Only the title in capitals: chord names need their case (Gm isn't GM).
                Text(i == 0 ? line.uppercased() : line)
                    .font(.system(size: i == 0 ? 15 : 11, weight: i == 0 ? .bold : .medium, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(Studio.lcdText.opacity(i == 0 ? 1 : 0.8))
                    .shadow(color: Studio.lcdText.opacity(0.55), radius: 3)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if let img = Studio.lcd { Image(nsImage: img).resizable() } else { Color(red: 0.12, green: 0.15, blue: 0.12) }
        }
        .clipShape(shape)
        .overlay(shape.stroke(Color.black.opacity(0.8), lineWidth: 6).blur(radius: 4).clipShape(shape)) // inner shadow
        .overlay(shape.strokeBorder(LinearGradient(colors: [.black.opacity(0.7), .white.opacity(0.12)],
                                                   startPoint: .top, endPoint: .bottom), lineWidth: 1.5))
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.55)))
    }
}

/// The face of a studio knob: shadow, machined cap (held still, so its sheen behaves like real
/// light), a rim, the value arc around it and a light pointer line that turns.
struct StudioKnobFace: View {
    let position: Double
    let origin: Double
    let modulated: Double?
    let color: Color
    static let sweep = 0.75, startDegrees = 135.0

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            let cap = d * 0.72
            let angle = Angle(degrees: Self.startDegrees + 360 * Self.sweep * position)
            ZStack {
                // Scale track and value arc around the cap.
                Circle().trim(from: 0, to: Self.sweep)
                    .stroke(Color.black.opacity(0.55), style: StrokeStyle(lineWidth: d * 0.05, lineCap: .round))
                    .rotationEffect(.degrees(Self.startDegrees))
                    .frame(width: d * 0.92, height: d * 0.92)
                Circle().trim(from: Self.sweep * min(origin, position), to: Self.sweep * max(origin, position) + 0.0005)
                    .stroke(color, style: StrokeStyle(lineWidth: d * 0.05, lineCap: .round))
                    .shadow(color: color.opacity(0.6), radius: 2)
                    .rotationEffect(.degrees(Self.startDegrees))
                    .frame(width: d * 0.92, height: d * 0.92)
                if let m = modulated {
                    let a = Angle(degrees: Self.startDegrees + 360 * Self.sweep * m)
                    Circle().fill(.orange).frame(width: d * 0.09, height: d * 0.09)
                        .offset(x: cos(a.radians) * d * 0.46, y: sin(a.radians) * d * 0.46)
                }
                // The cap.
                Group {
                    if let img = Studio.knobCap { Image(nsImage: img).resizable().interpolation(.high) } else { Circle().fill(Color(white: 0.23)) }
                }
                .frame(width: cap, height: cap)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.25), .black.opacity(0.7)],
                                                              startPoint: .top, endPoint: .bottom), lineWidth: max(1, cap * 0.04)))
                .shadow(color: .black.opacity(0.75), radius: cap * 0.08, y: cap * 0.06)
                // Pointer.
                Capsule().fill(Color.white.opacity(0.9))
                    .frame(width: cap * 0.36, height: max(1.5, cap * 0.05))
                    .offset(x: cap * 0.26)
                    .rotationEffect(angle)
                    .shadow(color: .black.opacity(0.6), radius: 1)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// A square latching button with an LED lens, for toggles in the studio skin.
struct StudioLEDButton: View {
    let label: String
    let on: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(on ? color : Color(white: 0.12))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.7), lineWidth: 1))
                    .shadow(color: on ? color.opacity(0.9) : .clear, radius: 4)
                    .frame(width: 22, height: 14)
                Text(label).font(Studio.legend(9)).foregroundStyle(Studio.label)
            }
        }
        .buttonStyle(.plain)
    }
}

/// A slim LCD strip for a tile's summary lines.
struct LCDLines: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Studio.lcdText.opacity(0.9))
                    .shadow(color: Studio.lcdText.opacity(0.45), radius: 2)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if let img = Studio.lcd { Image(nsImage: img).resizable() } else { Color(red: 0.12, green: 0.15, blue: 0.12) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.black.opacity(0.75), lineWidth: 1.5))
    }
}

// MARK: - Page-level pieces

extension View {
    /// Passes the skin down to a whole page and, in the studio skin, paints the panel behind it
    /// (lists and scroll views drop their own background so the panel shows through).
    /// The studio skin is dark hardware whatever the system appearance, so its text and controls
    /// always draw in their dark-mode colours.
    func skinnedPage(_ skin: SkinStyle, shade: Double = 0.45) -> some View {
        modifier(SkinControls(skin: skin))
            .environment(\.skin, skin)
            .transformEnvironment(\.colorScheme) { if skin == .studio { $0 = .dark } }
            .scrollContentBackground(skin == .studio ? .hidden : .automatic)
            .background { if skin == .studio { PanelBackground(cornerRadius: 0, shade: shade).ignoresSafeArea() } }
    }
}

/// A titled box of controls: a GroupBox in the system look, an engraved panel section in the studio skin.
struct SkinBox<Content: View>: View {
    @Environment(\.skin) private var skin
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        if skin == .studio {
            VStack(alignment: .leading, spacing: 8) {
                if let title {
                    Text(title.uppercased()).font(Studio.legend(11, weight: .bold)).tracking(1).foregroundStyle(Studio.label)
                }
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PanelBackground(cornerRadius: 8, shade: 0.2))
        } else if let title {
            GroupBox(title) { content }
        } else {
            GroupBox { content }
        }
    }
}

/// A small backlit readout: one big value and an optional detail line, like a synth's parameter display.
struct LCDReadout: View {
    let value: String
    var detail: String?
    var warn = false

    var body: some View {
        let ink = warn ? Color(red: 1, green: 0.45, blue: 0.4) : Studio.lcdText
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 19, weight: .bold, design: .monospaced))
                .foregroundStyle(ink).shadow(color: ink.opacity(0.55), radius: 3)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let detail {
                Text(detail).font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.75)).lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if let img = Studio.lcd { Image(nsImage: img).resizable() } else { Color(red: 0.12, green: 0.15, blue: 0.12) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.black.opacity(0.75), lineWidth: 1.5))
    }
}

// MARK: - Controls

/// Studio: every plain button on the page becomes a hardware-style key and every menu a button
/// that opens its menu. Buttons with their own style (icons, cells, cards) keep it.
struct SkinControls: ViewModifier {
    let skin: SkinStyle

    func body(content: Content) -> some View {
        if skin == .studio {
            content.buttonStyle(StudioButtonStyle()).menuStyle(.button)
        } else {
            content
        }
    }
}

/// A key on a synth's front panel: a raised, bevelled cap that sinks when pressed. `lit` tints it
/// for the main action on a page (the system look's "prominent" button).
struct StudioButtonStyle: ButtonStyle {
    var lit: Color?

    func makeBody(configuration: Configuration) -> some View {
        StudioButtonBody(configuration: configuration, lit: lit)
    }
}

private struct StudioButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    let configuration: ButtonStyleConfiguration
    let lit: Color?

    var body: some View {
        let small = controlSize == .small || controlSize == .mini
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 4)
        configuration.label
            .font(.system(size: small ? 11 : 12, weight: .semibold))
            .foregroundStyle(lit != nil ? Color.white : Studio.label)
            .padding(.horizontal, small ? 8 : 10).padding(.vertical, small ? 3 : 5)
            .background {
                ZStack {
                    shape.fill(LinearGradient(colors: pressed ? [Color(white: 0.15), Color(white: 0.2)] : [Color(white: 0.31), Color(white: 0.19)],
                                              startPoint: .top, endPoint: .bottom))
                    if let lit { shape.fill(lit.opacity(pressed ? 0.5 : 0.35)) }
                }
            }
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(pressed ? 0.05 : 0.2), .black.opacity(0.65)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: lit?.opacity(0.5) ?? .clear, radius: 3)
            .shadow(color: .black.opacity(0.55), radius: pressed ? 0.5 : 1.5, y: pressed ? 0 : 1)
            .offset(y: pressed ? 0.5 : 0)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(shape)
    }
}

extension View {
    /// The window's appearance for a skin: dark for the studio skin (sidebar and toolbar included),
    /// the system's choice otherwise.
    func skinWindow(_ skin: SkinStyle) -> some View { preferredColorScheme(skin == .studio ? .dark : nil) }

    /// The page's main action: bordered-prominent in the system look, a lit key in the studio skin.
    func skinProminent(_ color: Color = .accentColor) -> some View { modifier(SkinProminent(color: color)) }

    /// A text field: rounded-border in the system look, a dark recessed field with LCD-green text in the studio skin.
    func skinField() -> some View { modifier(SkinField()) }
}

private struct SkinProminent: ViewModifier {
    @Environment(\.skin) private var skin
    let color: Color

    func body(content: Content) -> some View {
        if skin == .studio { content.buttonStyle(StudioButtonStyle(lit: color)) } else { content.buttonStyle(.borderedProminent) }
    }
}

private struct SkinField: ViewModifier {
    @Environment(\.skin) private var skin

    func body(content: Content) -> some View {
        if skin == .studio {
            content.textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Studio.lcdText)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(LinearGradient(colors: [.black.opacity(0.8), .white.opacity(0.1)],
                                                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
        } else {
            content.textFieldStyle(.roundedBorder)
        }
    }
}

/// A slider: the system one, or in the studio skin a recessed slot with a lit track and a fader
/// cap, driven by AudioKit Controls (as the knobs are). Click anywhere on it to jump there.
struct SkinSlider: View {
    @Environment(\.skin) private var skin
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double?
    var color: Color = .accentColor

    var body: some View {
        if skin == .studio {
            let span = max(range.upperBound - range.lowerBound, .ulpOfOne)
            let p = min(max((value - range.lowerBound) / span, 0), 1)
            let binding = Binding<Float>(get: { Float(p) }, set: { n in
                var v = range.lowerBound + Double(n) * span
                if let step { v = range.lowerBound + ((v - range.lowerBound) / step).rounded() * step }
                value = min(max(v, range.lowerBound), range.upperBound)
            })
            Control(value: binding, in: 0...1, geometry: .horizontalPoint) { geo in
                StudioSliderFace(position: p, color: color).frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(minWidth: 60, maxWidth: .infinity)
            .frame(height: 22)
        } else if let step {
            Slider(value: $value, in: range, step: step)
        } else {
            Slider(value: $value, in: range)
        }
    }
}

/// The slot, lit track and cap of a studio slider.
struct StudioSliderFace: View {
    let position: Double
    let color: Color
    static let cap = CGSize(width: 12, height: 18)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, cap = Self.cap
            let x = cap.width / 2 + (w - cap.width) * position
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.75)).frame(height: 5)
                    .overlay(Capsule().strokeBorder(LinearGradient(colors: [.black, .white.opacity(0.12)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                Capsule().fill(color).frame(width: max(x - 1, 0), height: 3).padding(.leading, 1)
                    .shadow(color: color.opacity(0.7), radius: 2)
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(LinearGradient(colors: [Color(white: 0.8), Color(white: 0.42)], startPoint: .top, endPoint: .bottom))
                    .overlay(Rectangle().fill(Color.black.opacity(0.65)).frame(width: 1.5, height: cap.height * 0.55))
                    .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(Color.black.opacity(0.5), lineWidth: 0.5))
                    .frame(width: cap.width, height: cap.height)
                    .shadow(color: .black.opacity(0.6), radius: 1.5, y: 1)
                    .offset(x: x - cap.width / 2)
            }
            .frame(width: w, height: geo.size.height)
        }
    }
}

/// A choice from a list: a pop-up menu in the system look; in the studio skin a key showing the
/// current choice that opens the list.
struct SkinPicker<Value: Hashable>: View {
    @Environment(\.skin) private var skin
    var title: String?
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        if skin == .studio {
            HStack(spacing: 8) {
                if let title { Text(title) }
                Menu {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                        Button { selection = o.value } label: {
                            if o.value == selection { Label(o.label, systemImage: "checkmark") } else { Text(o.label) }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(options.first { $0.value == selection }?.label ?? "–").lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .menuStyle(.button)
                .buttonStyle(StudioButtonStyle())
                .menuIndicator(.hidden)
            }
        } else {
            Picker(title ?? "", selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, o in Text(o.label).tag(o.value) }
            }
            .labelsHidden(title == nil)
        }
    }
}

/// − / + for whole-number settings: the system stepper, or two small keys in the studio skin.
struct SkinStepper: View {
    @Environment(\.skin) private var skin
    var label: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 1.0

    var body: some View {
        if skin == .studio {
            HStack(spacing: 4) {
                if let label { Text(label).monospacedDigit() }
                Button { value = max(range.lowerBound, value - step) } label: { Image(systemName: "minus") }
                    .disabled(value <= range.lowerBound)
                Button { value = min(range.upperBound, value + step) } label: { Image(systemName: "plus") }
                    .disabled(value >= range.upperBound)
            }
            .buttonStyle(StudioButtonStyle())
            .controlSize(.small)
        } else {
            Stepper(label ?? "", value: $value, in: range, step: step).labelsHidden(label == nil)
        }
    }
}

/// On/off: a switch in the system look, an LED key in the studio skin.
struct SkinSwitch: View {
    @Environment(\.skin) private var skin
    @Binding var isOn: Bool
    var color: Color = .green

    var body: some View {
        if skin == .studio {
            Button { isOn.toggle() } label: {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isOn ? color : Color(white: 0.12))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.7), lineWidth: 1))
                    .shadow(color: isOn ? color.opacity(0.9) : .clear, radius: 4)
                    .frame(width: 26, height: 14)
            }
            .buttonStyle(.plain)
        } else {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

extension View {
    /// `labelsHidden()` only when asked.
    @ViewBuilder func labelsHidden(_ hidden: Bool) -> some View {
        if hidden { labelsHidden() } else { self }
    }
}
