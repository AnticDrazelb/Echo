import Foundation

// MARK: - Animation

enum Easing: String, Codable, CaseIterable, Identifiable {
    case linear, easeIn, easeOut, easeInOut, hold

    var id: String { rawValue }

    var title: String {
        switch self {
        case .linear: "Linear"
        case .easeIn: "Ease In"
        case .easeOut: "Ease Out"
        case .easeInOut: "Ease In & Out"
        case .hold: "Hold"
        }
    }

    func apply(_ t: Double) -> Double {
        switch self {
        case .linear: t
        case .easeIn: t * t * t
        case .easeOut: 1 - pow(1 - t, 3)
        case .easeInOut: t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .hold: 0
        }
    }
}

struct Keyframe: Codable, Hashable, Identifiable {
    var id = UUID()
    var time: Double
    var value: Double
    /// Easing used from this keyframe to the next.
    var easing: Easing = .easeInOut
}

/// A number that can be animated with keyframes (After Effects "stopwatch").
struct AnimatableValue: Codable, Hashable {
    var value: Double
    var keyframes: [Keyframe] = []

    init(_ value: Double) { self.value = value }

    var isAnimated: Bool { !keyframes.isEmpty }

    func at(_ t: Double) -> Double {
        guard let first = keyframes.first else { return value }
        if t <= first.time { return first.value }
        guard let last = keyframes.last, t < last.time else { return keyframes.last?.value ?? value }
        for i in 0..<(keyframes.count - 1) {
            let a = keyframes[i], b = keyframes[i + 1]
            if t >= a.time, t <= b.time {
                let span = max(b.time - a.time, 1e-6)
                let p = a.easing.apply((t - a.time) / span)
                return a.value + (b.value - a.value) * p
            }
        }
        return last.value
    }

    func keyframe(near t: Double, tolerance: Double = 1.0 / 30) -> Keyframe? {
        keyframes.first { abs($0.time - t) <= tolerance }
    }

    /// Sets the value at time t: with the stopwatch on this adds or moves a
    /// keyframe, otherwise it changes the static value.
    mutating func set(_ newValue: Double, at t: Double) {
        guard isAnimated else { value = newValue; return }
        if let i = keyframes.firstIndex(where: { abs($0.time - t) <= 1.0 / 30 }) {
            keyframes[i].value = newValue
        } else {
            keyframes.append(Keyframe(time: t, value: newValue))
            keyframes.sort { $0.time < $1.time }
        }
    }

    /// Stopwatch: start animating from the current value, or stop animating.
    mutating func toggleAnimation(at t: Double) {
        if isAnimated {
            value = at(t)
            keyframes = []
        } else {
            keyframes = [Keyframe(time: t, value: value)]
        }
    }

    mutating func toggleKeyframe(at t: Double) {
        if let k = keyframe(near: t) {
            let current = at(t)
            keyframes.removeAll { $0.id == k.id }
            if keyframes.isEmpty { value = current }
        } else {
            keyframes.append(Keyframe(time: t, value: at(t)))
            keyframes.sort { $0.time < $1.time }
        }
    }
}

// MARK: - Layers

enum BlendMode: String, Codable, CaseIterable, Identifiable {
    case normal, multiply, screen, overlay, softLight, hardLight, colorDodge, colorBurn
    case darken, lighten, difference, exclusion, add, hue, saturation, color, luminosity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: "Normal"
        case .multiply: "Multiply"
        case .screen: "Screen"
        case .overlay: "Overlay"
        case .softLight: "Soft Light"
        case .hardLight: "Hard Light"
        case .colorDodge: "Color Dodge"
        case .colorBurn: "Color Burn"
        case .darken: "Darken"
        case .lighten: "Lighten"
        case .difference: "Difference"
        case .exclusion: "Exclusion"
        case .add: "Add"
        case .hue: "Hue"
        case .saturation: "Saturation"
        case .color: "Color"
        case .luminosity: "Luminosity"
        }
    }

    var filterName: String {
        switch self {
        case .normal: "CISourceOverCompositing"
        case .multiply: "CIMultiplyBlendMode"
        case .screen: "CIScreenBlendMode"
        case .overlay: "CIOverlayBlendMode"
        case .softLight: "CISoftLightBlendMode"
        case .hardLight: "CIHardLightBlendMode"
        case .colorDodge: "CIColorDodgeBlendMode"
        case .colorBurn: "CIColorBurnBlendMode"
        case .darken: "CIDarkenBlendMode"
        case .lighten: "CILightenBlendMode"
        case .difference: "CIDifferenceBlendMode"
        case .exclusion: "CIExclusionBlendMode"
        case .add: "CIAdditionCompositing"
        case .hue: "CIHueBlendMode"
        case .saturation: "CISaturationBlendMode"
        case .color: "CIColorBlendMode"
        case .luminosity: "CILuminosityBlendMode"
        }
    }
}

/// RGB in 0...1, each channel animatable.
struct AnimatableColor: Codable, Hashable {
    var r: AnimatableValue
    var g: AnimatableValue
    var b: AnimatableValue

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = AnimatableValue(r)
        self.g = AnimatableValue(g)
        self.b = AnimatableValue(b)
    }

    func at(_ t: Double) -> (Double, Double, Double) { (r.at(t), g.at(t), b.at(t)) }
}

enum TextFont: String, Codable, CaseIterable, Identifiable {
    case rounded, sans, serif, mono, condensed
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct TextContent: Codable, Hashable {
    var text: String = "Echo"
    var font: TextFont = .rounded
    var weight: Double = 0.4  // UIFont.Weight raw value range -1...1
    var size = AnimatableValue(0.09)  // fraction of canvas width
    var tracking = AnimatableValue(0)
    var color = AnimatableColor(1, 1, 1)
    var shadow = AnimatableValue(0.3)
}

enum ShapeKind: String, Codable, CaseIterable, Identifiable {
    case rectangle, ellipse
    var id: String { rawValue }
}

struct ShapeContent: Codable, Hashable {
    var kind: ShapeKind = .rectangle
    var width = AnimatableValue(0.5)   // fraction of canvas width
    var height = AnimatableValue(0.3)  // fraction of canvas width
    var cornerRadius = AnimatableValue(0.04)
    var color = AnimatableColor(0, 0.478, 1)
}

struct GradientContent: Codable, Hashable {
    var from = AnimatableColor(0, 0.478, 1)
    var to = AnimatableColor(0.686, 0.322, 0.871)
    var angle = AnimatableValue(90)  // degrees
}

enum LayerContent: Codable, Hashable {
    /// The project's photo or video.
    case base
    /// Applies its effects to everything below.
    case adjustment
    case text(TextContent)
    case shape(ShapeContent)
    case solid(AnimatableColor)
    case gradient(GradientContent)
    /// An overlay image stored in the project folder.
    case image(String)
}

struct LayerTransform: Codable, Hashable {
    /// Center, 0...1 from the top-left of the canvas.
    var x = AnimatableValue(0.5)
    var y = AnimatableValue(0.5)
    var scale = AnimatableValue(1)
    var rotation = AnimatableValue(0) // degrees
}

enum MaskKind: String, Codable, CaseIterable, Identifiable {
    case none, ellipse, rectangle, linear, luminance, sky, skin, subject
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .ellipse: "Ellipse"
        case .rectangle: "Rectangle"
        case .linear: "Gradient"
        case .luminance: "Luma Key"
        case .sky: "Sky"
        case .skin: "Skin"
        case .subject: "Subject"
        }
    }
}

struct LayerMask: Codable, Hashable {
    var kind: MaskKind = .none
    var inverted = false
    var x = AnimatableValue(0.5)
    var y = AnimatableValue(0.5)
    var width = AnimatableValue(0.6)
    var height = AnimatableValue(0.6)
    var feather = AnimatableValue(0.15)
    /// Gradient angle (degrees) or luma-key low threshold.
    var angle = AnimatableValue(90)
    var low = AnimatableValue(0.6)
    var high = AnimatableValue(1)
}

struct Layer: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var content: LayerContent
    var isVisible = true
    var blend: BlendMode = .normal
    var opacity = AnimatableValue(1)
    var transform = LayerTransform()
    var mask = LayerMask()
    var effects: [Effect] = []
    /// Seconds; nil = whole composition.
    var inPoint: Double?
    var outPoint: Double?

    var isBase: Bool { if case .base = content { return true }; return false }
    var isAdjustment: Bool { if case .adjustment = content { return true }; return false }

    var icon: String {
        switch content {
        case .base: "photo"
        case .adjustment: "slider.horizontal.3"
        case .text: "textformat"
        case .shape(let s): s.kind == .ellipse ? "circle" : "square"
        case .solid: "square.fill"
        case .gradient: "square.lefthalf.filled"
        case .image: "photo.on.rectangle"
        }
    }

    func isActive(at t: Double) -> Bool {
        isVisible && (inPoint.map { t >= $0 } ?? true) && (outPoint.map { t <= $0 } ?? true)
    }
}

// MARK: - Composition

struct Composition: Codable, Hashable, Identifiable {
    enum BaseKind: String, Codable { case photo, video }

    var id = UUID()
    var name: String
    var createdAt = Date()
    var modifiedAt = Date()
    var baseKind: BaseKind
    /// File name of the base media inside the project folder.
    var baseFile: String
    /// Canvas aspect (width / height) from the base media.
    var aspect: Double
    var duration: Double
    var fps: Double = 30
    /// Bottom to top. The base layer is always first.
    var layers: [Layer]

    static func new(name: String, kind: BaseKind, file: String, aspect: Double, duration: Double) -> Composition {
        Composition(
            name: name, baseKind: kind, baseFile: file, aspect: aspect,
            duration: duration, layers: [Layer(name: kind == .photo ? "Photo" : "Video", content: .base)]
        )
    }

    /// Every keyframe time in the project (for the timeline overview).
    var allKeyframeTimes: [Double] {
        var times: [Double] = []
        for layer in layers {
            layer.visitValues { times += $0.keyframes.map(\.time) }
        }
        return Array(Set(times)).sorted()
    }
}

extension Layer {
    /// Calls `body` for every animatable value in the layer.
    func visitValues(_ body: (AnimatableValue) -> Void) {
        [opacity, transform.x, transform.y, transform.scale, transform.rotation,
         mask.x, mask.y, mask.width, mask.height, mask.feather, mask.angle, mask.low, mask.high].forEach(body)
        for effect in effects { effect.params.values.forEach(body) }
        switch content {
        case .text(let t): [t.size, t.tracking, t.shadow, t.color.r, t.color.g, t.color.b].forEach(body)
        case .shape(let s): [s.width, s.height, s.cornerRadius, s.color.r, s.color.g, s.color.b].forEach(body)
        case .solid(let c): [c.r, c.g, c.b].forEach(body)
        case .gradient(let g): [g.from.r, g.from.g, g.from.b, g.to.r, g.to.g, g.to.b, g.angle].forEach(body)
        default: break
        }
    }
}
