import Controls
import Params
import SwiftUI

/// An AudioKit-style arc knob for one parameter. Drag up/down to turn (AudioKit Controls'
/// `Control`, vertical drag). The arc grows from the left, or from the centre for bipolar
/// params such as pan; an orange dot marks the live value when modulation moves it.
struct ParamKnob: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin
    let spec: ParamSpec
    var label: String?
    var color: Color = .accentColor
    var size: CGFloat = 54
    @State private var dragging = false

    private var isLog: Bool { spec.unit == "B/s" }
    private var bipolar: Bool { spec.range.lowerBound < 0 && spec.range.upperBound > 0 }

    /// Position on the knob, 0...1 (log scale for byte rates).
    private func position(_ v: Double) -> Double {
        if isLog {
            let lo = log10(max(spec.range.lowerBound, 1)), hi = log10(max(spec.range.upperBound, 10))
            return (log10(max(v, 1)) - lo) / (hi - lo)
        }
        return (v - spec.range.lowerBound) / max(spec.span, .ulpOfOne)
    }

    private func value(_ p: Double) -> Double {
        if isLog {
            let lo = log10(max(spec.range.lowerBound, 1)), hi = log10(max(spec.range.upperBound, 10))
            return pow(10, lo + p * (hi - lo))
        }
        return spec.range.lowerBound + p * spec.span
    }

    /// A 270° arc opening at the bottom: drawn from 0 and rotated to start at 135° (trim doesn't wrap past 1).
    private static let sweep = 0.75, startDegrees = 135.0

    var body: some View {
        let base = model.base(spec.id), effective = model.effective(spec.id)
        let p = min(max(position(base), 0), 1)
        let e = min(max(position(effective), 0), 1)
        let origin = bipolar ? min(max(position(0), 0), 1) : 0
        let binding = Binding<Float>(
            get: { Float(p) },
            set: { model.set(spec.id, value(Double($0))) }
        )
        VStack(spacing: 3) {
            Control(value: binding, in: 0 ... 1, geometry: .verticalDrag(ySensitivity: 1.5),
                    onStarted: { dragging = true }, onEnded: { dragging = false }) { geo in
                let d = min(geo.size.width, geo.size.height)
                if skin == .studio {
                    StudioKnobFace(position: p, origin: origin, modulated: abs(e - p) > 0.004 ? e : nil, color: color)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                ZStack {
                    Circle().trim(from: 0, to: Self.sweep)
                        .stroke(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: d / 10, lineCap: .round))
                        .rotationEffect(.degrees(Self.startDegrees))
                        .frame(width: d * 0.8, height: d * 0.8)
                    Circle().trim(from: Self.sweep * min(origin, p), to: Self.sweep * max(origin, p) + 0.0005)
                        .stroke(color, style: StrokeStyle(lineWidth: d / 10, lineCap: .round))
                        .rotationEffect(.degrees(Self.startDegrees))
                        .frame(width: d * 0.8, height: d * 0.8)
                    if abs(e - p) > 0.004 {
                        let angle = Angle(degrees: Self.startDegrees + 360 * Self.sweep * e)
                        Circle().fill(.orange).frame(width: d / 8, height: d / 8)
                            .offset(x: cos(angle.radians) * d * 0.4, y: sin(angle.radians) * d * 0.4)
                    }
                    Text(ParamRow.format(dragging ? base : (abs(e - p) > 0.004 ? effective : base), spec))
                        .font(.system(size: d * 0.17, weight: .semibold)).monospacedDigit()
                        .minimumScaleFactor(0.5).lineLimit(1)
                        .frame(width: d * 0.62)
                        .foregroundStyle(abs(e - p) > 0.004 && !dragging ? Color.orange : .primary)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .frame(width: size, height: size)
            if skin == .studio {
                // Hardware legends: the name in small caps; the value only while turning or modulated.
                let shown = dragging || abs(e - p) > 0.004
                Text(shown ? ParamRow.format(dragging ? base : effective, spec)
                     : (label ?? (spec.label == spec.id ? ParamRow.shortLabel(spec.id) : spec.label)).uppercased())
                    .font(Studio.legend(9)).tracking(0.5)
                    .foregroundStyle(shown ? (dragging ? Color.white : .orange) : Studio.label)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(width: size + 24)
            } else {
                Text(label ?? (spec.label == spec.id ? ParamRow.shortLabel(spec.id) : spec.label))
                    .font(.caption).lineLimit(2).multilineTextAlignment(.center)
                    .frame(width: size + 34)
            }
        }
        .help(spec.help)
    }
}

/// A group's knobs in a grid. With explanations on, the hovered knob's explanation shows above
/// the grid, so the plain-language help is still one glance away.
struct KnobGrid: View {
    @Environment(AppModel.self) private var model
    let specs: [ParamSpec]
    var color: Color = .accentColor
    @State private var hovered: ParamSpec?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.showExplanations {
                Text(hovered.map { "\(ParamRow.shortLabel($0.id)): \($0.help)" } ?? "Hover a knob to see what it does. Drag up or down to turn it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], alignment: .leading, spacing: 12) {
                ForEach(specs, id: \.id) { spec in
                    ParamKnob(spec: spec, color: color)
                        .onHover { inside in
                            if inside { hovered = spec } else if hovered == spec { hovered = nil }
                        }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

extension ParamSpec {
    /// Shown as a knob (continuous values and wide integer ranges); toggles and pickers stay rows.
    var isKnob: Bool {
        switch kind {
        case .normalised, .continuous: true
        case .integer: true
        case .choice, .toggle: false
        }
    }
}

/// A hardware-style on/off button with an LED, for toggle params.
struct LEDButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin
    let spec: ParamSpec
    var label: String?
    var color: Color = .green

    var body: some View {
        let on = model.base(spec.id) >= 0.5
        if skin == .studio {
            StudioLEDButton(label: (label ?? (spec.label == spec.id ? ParamRow.shortLabel(spec.id) : spec.label)).uppercased(),
                            on: on, color: color) { model.set(spec.id, on ? 0 : 1) }
                .help(spec.help)
        } else {
            plain(on)
        }
    }

    private func plain(_ on: Bool) -> some View {
        Button { model.set(spec.id, on ? 0 : 1) } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(on ? color : Color.black.opacity(0.55))
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.white.opacity(on ? 0.6 : 0.15), lineWidth: 0.5))
                    .shadow(color: on ? color.opacity(0.9) : .clear, radius: 4)
                Text(label ?? (spec.label == spec.id ? ParamRow.shortLabel(spec.id) : spec.label))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(on ? .primary : .secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(LinearGradient(colors: [Color.primary.opacity(on ? 0.16 : 0.10), Color.primary.opacity(on ? 0.08 : 0.04)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.18), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(spec.help)
    }
}
