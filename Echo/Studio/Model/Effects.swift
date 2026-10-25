import CoreImage
import Foundation

/// One effect in a layer's stack.
struct Effect: Codable, Hashable, Identifiable {
    var id = UUID()
    var type: EffectType
    var isEnabled = true
    var params: [String: AnimatableValue]
    /// For the Echo Look effect.
    var styleName: String?
    var dna: StyleDNA?

    init(_ type: EffectType) {
        self.type = type
        params = Dictionary(uniqueKeysWithValues: (type.params + [ParamSpec.mix]).map { ($0.key, AnimatableValue($0.defaultValue)) })
    }

    func value(_ key: String, at t: Double) -> Double {
        params[key]?.at(t) ?? (type.params.first { $0.key == key }?.defaultValue ?? 0)
    }
}

struct ParamSpec: Hashable {
    enum Unit { case plain, percent, degrees, kelvin, ev, color }

    let key: String
    let label: String
    let min: Double
    let max: Double
    let defaultValue: Double
    var unit: Unit = .plain

    static let mix = ParamSpec(key: "mix", label: "Mix", min: 0, max: 1, defaultValue: 1, unit: .percent)

    func format(_ v: Double) -> String {
        switch unit {
        case .percent, .color: "\(Int((v * 100).rounded()))%"
        case .degrees: "\(Int(v.rounded()))°"
        case .kelvin: "\(Int(v.rounded()))K"
        case .ev: String(format: "%+.2f EV", v)
        case .plain: abs(v) >= 10 ? "\(Int(v.rounded()))" : String(format: "%.2f", v)
        }
    }
}

enum EffectCategory: String, CaseIterable, Identifiable {
    case color = "Color", light = "Light", blur = "Blur & Sharpen", stylize = "Stylize", distort = "Distort", motion = "Motion"
    var id: String { rawValue }
}

enum EffectType: String, Codable, CaseIterable, Identifiable {
    // Color
    case look, exposure, contrast, saturation, temperature, curves, hue, duotone, blackWhite, posterize, invert
    // Light
    case glow, lightLeak, halation, vignette
    // Blur
    case gaussian, motionBlur, zoomBlur, portraitBlur, sharpen, denoise
    // Stylize
    case grain, glitch, chromatic, halftone, pixelate, comic, edges, scanlines
    // Distort
    case kaleidoscope, twirl, bulge
    // Motion
    case shake

    var id: String { rawValue }

    var title: String {
        switch self {
        case .look: "Echo Look"
        case .exposure: "Exposure"
        case .contrast: "Brightness & Contrast"
        case .saturation: "Saturation & Vibrance"
        case .temperature: "Temperature & Tint"
        case .curves: "Curves"
        case .hue: "Hue Shift"
        case .duotone: "Duotone"
        case .blackWhite: "Black & White"
        case .posterize: "Posterize"
        case .invert: "Invert"
        case .glow: "Glow"
        case .lightLeak: "Light Leak"
        case .halation: "Halation"
        case .vignette: "Vignette"
        case .gaussian: "Gaussian Blur"
        case .motionBlur: "Motion Blur"
        case .zoomBlur: "Zoom Blur"
        case .portraitBlur: "Background Blur"
        case .sharpen: "Sharpen"
        case .denoise: "Noise Reduction"
        case .grain: "Film Grain"
        case .glitch: "Glitch"
        case .chromatic: "RGB Split"
        case .halftone: "Halftone"
        case .pixelate: "Pixelate"
        case .comic: "Comic"
        case .edges: "Ink Edges"
        case .scanlines: "Scanlines"
        case .kaleidoscope: "Kaleidoscope"
        case .twirl: "Twirl"
        case .bulge: "Bulge"
        case .shake: "Camera Shake"
        }
    }

    var icon: String {
        switch self {
        case .look: "sparkles"
        case .exposure: "plusminus.circle"
        case .contrast: "circle.lefthalf.filled"
        case .saturation: "drop.fill"
        case .temperature: "thermometer.medium"
        case .curves: "point.topleft.down.to.point.bottomright.curvepath"
        case .hue: "paintpalette"
        case .duotone: "circle.grid.2x1.fill"
        case .blackWhite: "camera.filters"
        case .posterize: "square.stack.3d.up"
        case .invert: "circle.righthalf.filled.inverse"
        case .glow: "sun.max.fill"
        case .lightLeak: "light.max"
        case .halation: "sun.haze.fill"
        case .vignette: "circle.dashed"
        case .gaussian: "aqi.medium"
        case .motionBlur: "wind"
        case .zoomBlur: "scope"
        case .portraitBlur: "person.crop.circle.badge.checkmark"
        case .sharpen: "triangle"
        case .denoise: "waveform.path.badge.minus"
        case .grain: "circle.dotted"
        case .glitch: "rectangle.split.3x1"
        case .chromatic: "camera.aperture"
        case .halftone: "circle.grid.3x3.fill"
        case .pixelate: "square.grid.3x3.fill"
        case .comic: "book.closed"
        case .edges: "scribble"
        case .scanlines: "line.3.horizontal"
        case .kaleidoscope: "seal"
        case .twirl: "tornado"
        case .bulge: "circle.circle"
        case .shake: "iphone.radiowaves.left.and.right"
        }
    }

    var category: EffectCategory {
        switch self {
        case .look, .exposure, .contrast, .saturation, .temperature, .curves, .hue, .duotone, .blackWhite, .posterize, .invert: .color
        case .glow, .lightLeak, .halation, .vignette: .light
        case .gaussian, .motionBlur, .zoomBlur, .portraitBlur, .sharpen, .denoise: .blur
        case .grain, .glitch, .chromatic, .halftone, .pixelate, .comic, .edges, .scanlines: .stylize
        case .kaleidoscope, .twirl, .bulge: .distort
        case .shake: .motion
        }
    }

    var params: [ParamSpec] {
        switch self {
        case .look: [.init(key: "intensity", label: "Intensity", min: 0, max: 1, defaultValue: 0.8, unit: .percent)]
        case .exposure: [.init(key: "ev", label: "Exposure", min: -3, max: 3, defaultValue: 0, unit: .ev)]
        case .contrast: [
            .init(key: "contrast", label: "Contrast", min: 0.5, max: 1.6, defaultValue: 1),
            .init(key: "brightness", label: "Brightness", min: -0.3, max: 0.3, defaultValue: 0),
        ]
        case .saturation: [
            .init(key: "saturation", label: "Saturation", min: 0, max: 2, defaultValue: 1),
            .init(key: "vibrance", label: "Vibrance", min: -1, max: 1, defaultValue: 0),
        ]
        case .temperature: [
            .init(key: "temperature", label: "Temperature", min: 2500, max: 11000, defaultValue: 6500, unit: .kelvin),
            .init(key: "tint", label: "Tint", min: -100, max: 100, defaultValue: 0),
        ]
        case .curves: [
            .init(key: "p0", label: "Blacks", min: 0, max: 0.5, defaultValue: 0),
            .init(key: "p1", label: "Shadows", min: 0, max: 0.6, defaultValue: 0.25),
            .init(key: "p2", label: "Midtones", min: 0.2, max: 0.8, defaultValue: 0.5),
            .init(key: "p3", label: "Lights", min: 0.4, max: 1, defaultValue: 0.75),
            .init(key: "p4", label: "Whites", min: 0.5, max: 1, defaultValue: 1),
        ]
        case .hue: [.init(key: "angle", label: "Hue", min: -180, max: 180, defaultValue: 0, unit: .degrees)]
        case .duotone: [
            .init(key: "r0", label: "Shadow Red", min: 0, max: 1, defaultValue: 0.05, unit: .color),
            .init(key: "g0", label: "Shadow Green", min: 0, max: 1, defaultValue: 0.08, unit: .color),
            .init(key: "b0", label: "Shadow Blue", min: 0, max: 1, defaultValue: 0.35, unit: .color),
            .init(key: "r1", label: "Highlight Red", min: 0, max: 1, defaultValue: 1, unit: .color),
            .init(key: "g1", label: "Highlight Green", min: 0, max: 1, defaultValue: 0.8, unit: .color),
            .init(key: "b1", label: "Highlight Blue", min: 0, max: 1, defaultValue: 0.55, unit: .color),
        ]
        case .blackWhite: [.init(key: "contrast", label: "Contrast", min: 0.6, max: 1.6, defaultValue: 1.1)]
        case .posterize: [.init(key: "levels", label: "Levels", min: 2, max: 16, defaultValue: 5)]
        case .invert: []
        case .glow: [
            .init(key: "radius", label: "Radius", min: 0, max: 0.1, defaultValue: 0.03),
            .init(key: "intensity", label: "Intensity", min: 0, max: 2, defaultValue: 0.8),
        ]
        case .lightLeak: [
            .init(key: "x", label: "Position X", min: 0, max: 1, defaultValue: 0.85, unit: .percent),
            .init(key: "y", label: "Position Y", min: 0, max: 1, defaultValue: 0.15, unit: .percent),
            .init(key: "radius", label: "Size", min: 0.1, max: 1.5, defaultValue: 0.7),
            .init(key: "hue", label: "Hue", min: 0, max: 360, defaultValue: 25, unit: .degrees),
            .init(key: "strength", label: "Strength", min: 0, max: 1, defaultValue: 0.6, unit: .percent),
        ]
        case .halation: [
            .init(key: "amount", label: "Amount", min: 0, max: 1, defaultValue: 0.5, unit: .percent),
            .init(key: "threshold", label: "Threshold", min: 0.5, max: 0.98, defaultValue: 0.82),
        ]
        case .vignette: [
            .init(key: "amount", label: "Amount", min: 0, max: 1, defaultValue: 0.6, unit: .percent),
            .init(key: "size", label: "Size", min: 0.2, max: 1, defaultValue: 0.6),
            .init(key: "feather", label: "Feather", min: 0, max: 1, defaultValue: 0.6, unit: .percent),
        ]
        case .gaussian: [.init(key: "radius", label: "Radius", min: 0, max: 0.05, defaultValue: 0.01)]
        case .motionBlur: [
            .init(key: "radius", label: "Distance", min: 0, max: 0.08, defaultValue: 0.02),
            .init(key: "angle", label: "Angle", min: 0, max: 360, defaultValue: 0, unit: .degrees),
        ]
        case .zoomBlur: [
            .init(key: "x", label: "Center X", min: 0, max: 1, defaultValue: 0.5, unit: .percent),
            .init(key: "y", label: "Center Y", min: 0, max: 1, defaultValue: 0.5, unit: .percent),
            .init(key: "amount", label: "Amount", min: 0, max: 0.15, defaultValue: 0.04),
        ]
        case .portraitBlur: [.init(key: "radius", label: "Blur", min: 0, max: 0.04, defaultValue: 0.015)]
        case .sharpen: [.init(key: "amount", label: "Amount", min: 0, max: 2, defaultValue: 0.6)]
        case .denoise: [.init(key: "level", label: "Level", min: 0, max: 0.1, defaultValue: 0.02)]
        case .grain: [
            .init(key: "amount", label: "Amount", min: 0, max: 1, defaultValue: 0.4, unit: .percent),
            .init(key: "size", label: "Size", min: 0.5, max: 3, defaultValue: 1.2),
        ]
        case .glitch: [
            .init(key: "amount", label: "Amount", min: 0, max: 1, defaultValue: 0.4, unit: .percent),
            .init(key: "speed", label: "Speed", min: 1, max: 30, defaultValue: 8),
        ]
        case .chromatic: [.init(key: "amount", label: "Amount", min: 0, max: 1, defaultValue: 0.35, unit: .percent)]
        case .halftone: [
            .init(key: "size", label: "Dot Size", min: 0.003, max: 0.03, defaultValue: 0.008),
            .init(key: "angle", label: "Angle", min: 0, max: 90, defaultValue: 45, unit: .degrees),
        ]
        case .pixelate: [.init(key: "size", label: "Block Size", min: 0.003, max: 0.1, defaultValue: 0.02)]
        case .comic: []
        case .edges: [.init(key: "radius", label: "Line Width", min: 1, max: 8, defaultValue: 3)]
        case .scanlines: [
            .init(key: "density", label: "Lines", min: 60, max: 900, defaultValue: 320),
            .init(key: "strength", label: "Strength", min: 0, max: 1, defaultValue: 0.35, unit: .percent),
        ]
        case .kaleidoscope: [
            .init(key: "count", label: "Segments", min: 2, max: 16, defaultValue: 6),
            .init(key: "angle", label: "Angle", min: 0, max: 360, defaultValue: 0, unit: .degrees),
        ]
        case .twirl: [
            .init(key: "x", label: "Center X", min: 0, max: 1, defaultValue: 0.5, unit: .percent),
            .init(key: "y", label: "Center Y", min: 0, max: 1, defaultValue: 0.5, unit: .percent),
            .init(key: "radius", label: "Radius", min: 0.05, max: 1, defaultValue: 0.4),
            .init(key: "angle", label: "Angle", min: -720, max: 720, defaultValue: 180, unit: .degrees),
        ]
        case .bulge: [
            .init(key: "x", label: "Center X", min: 0, max: 1, defaultValue: 0.5, unit: .percent),
            .init(key: "y", label: "Center Y", min: 0, max: 1, defaultValue: 0.5, unit: .percent),
            .init(key: "radius", label: "Radius", min: 0.05, max: 1, defaultValue: 0.35),
            .init(key: "scale", label: "Strength", min: -1, max: 1, defaultValue: 0.5),
        ]
        case .shake: [
            .init(key: "amount", label: "Amount", min: 0, max: 0.06, defaultValue: 0.012),
            .init(key: "frequency", label: "Frequency", min: 0.5, max: 20, defaultValue: 5),
            .init(key: "rotation", label: "Rotation", min: 0, max: 5, defaultValue: 0.6, unit: .degrees),
        ]
        }
    }

    /// Effects that change over time even without keyframes.
    var isTimeBased: Bool { [.grain, .glitch, .shake].contains(self) }
}
