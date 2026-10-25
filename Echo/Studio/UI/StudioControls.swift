import SwiftUI
import UIKit

/// A slider for an animatable value, with After Effects-style stopwatch
/// (animate on/off) and keyframe diamond (add/remove at the playhead).
struct ParamRow: View {
    let label: String
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    let value: AnimatableValue
    let time: Double
    let onChange: (AnimatableValue) -> Void

    var body: some View {
        let current = value.at(time)
        let onKey = value.keyframe(near: time) != nil
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    var v = value
                    v.toggleAnimation(at: time)
                    onChange(v)
                } label: {
                    Image(systemName: value.isAnimated ? "stopwatch.fill" : "stopwatch")
                        .foregroundStyle(value.isAnimated ? Theme.accent : .white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(value.isAnimated ? "Stop animating \(label)" : "Animate \(label)")
                Text(label)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                Spacer()
                Text(format(current))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
                if value.isAnimated {
                    Button {
                        var v = value
                        v.toggleKeyframe(at: time)
                        onChange(v)
                    } label: {
                        Image(systemName: onKey ? "diamond.fill" : "diamond")
                            .foregroundStyle(onKey ? Color.yellow : .white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(onKey ? "Remove keyframe" : "Add keyframe")
                }
            }
            Slider(
                value: Binding(
                    get: { min(max(current, range.lowerBound), range.upperBound) },
                    set: { newValue in
                        var v = value
                        v.set(newValue, at: time)
                        onChange(v)
                    }
                ),
                in: range
            )
            .tint(value.isAnimated ? Color.yellow.opacity(0.9) : Theme.accent)
        }
    }
}

/// Color picker for an animatable RGB color.
struct ColorRow: View {
    let label: String
    let color: AnimatableColor
    let time: Double
    let onChange: (AnimatableColor) -> Void

    var body: some View {
        let (r, g, b) = color.at(time)
        let animated = color.r.isAnimated
        HStack(spacing: 8) {
            Button {
                var c = color
                c.r.toggleAnimation(at: time)
                c.g.toggleAnimation(at: time)
                c.b.toggleAnimation(at: time)
                onChange(c)
            } label: {
                Image(systemName: animated ? "stopwatch.fill" : "stopwatch")
                    .foregroundStyle(animated ? Theme.accent : .white.opacity(0.45))
            }
            .buttonStyle(.plain)
            ColorPicker(selection: Binding(
                get: { Color(red: r, green: g, blue: b) },
                set: { newColor in
                    var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
                    UIColor(newColor).getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
                    var c = color
                    c.r.set(Double(cr), at: time)
                    c.g.set(Double(cg), at: time)
                    c.b.set(Double(cb), at: time)
                    onChange(c)
                }
            ), supportsOpacity: false) {
                Text(label).font(.system(size: 14, weight: .medium, design: .rounded))
            }
        }
    }
}

/// Grouped card used by the inspector.
struct InspectorSection<Content: View>: View {
    let title: String
    var systemImage: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let systemImage {
                    Image(systemName: systemImage).foregroundStyle(Theme.accent)
                }
                Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                if let trailing { trailing }
            }
            content
        }
        .padding(14)
        .background(Theme.surfaceRaised.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Playhead, keyframe markers and transport.
struct TimelineBar: View {
    @Bindable var model: StudioModel

    var body: some View {
        let duration = max(model.comp.duration, 0.1)
        let keys = keyframeTimes
        HStack(spacing: 12) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .echoGlass(Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1)).frame(height: 6)
                    Capsule().fill(Theme.accent.opacity(0.7))
                        .frame(width: max(6, w * model.time / duration), height: 6)
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, t in
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                            .position(x: w * t / duration, y: geo.size.height / 2)
                    }
                    Capsule()
                        .fill(.white)
                        .frame(width: 3, height: 26)
                        .position(x: w * model.time / duration, y: geo.size.height / 2)
                }
                .frame(height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    if model.isPlaying { model.pause() }
                    model.time = min(max(g.location.x / w, 0), 1) * duration
                })
            }
            .frame(height: 36)

            Text(timeLabel(model.time) + " / " + timeLabel(duration))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
                .fixedSize()
        }
    }

    private var keyframeTimes: [Double] {
        guard let layer = model.selectedLayer else { return model.comp.allKeyframeTimes }
        var times: [Double] = []
        layer.visitValues { times += $0.keyframes.map(\.time) }
        return Array(Set(times)).sorted()
    }

    private func timeLabel(_ t: Double) -> String {
        String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }
}
