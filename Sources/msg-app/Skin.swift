import AppKit
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
    func skinnedPage(_ skin: SkinStyle, shade: Double = 0.45) -> some View {
        environment(\.skin, skin)
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
