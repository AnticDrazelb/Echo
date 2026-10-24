import Foundation

/// A compact, non-reversible description of an image's look.
///
/// Style DNA captures the *statistics* of a picture (how its tones are
/// distributed, how each tonal zone is tinted, how saturated each hue family
/// is, and its texture/optical character) and never any pixels. The same
/// structure describes both a reference ("the look I want") and a target
/// ("the photo I'm editing"); the renderer maps one onto the other.
struct StyleDNA: Codable, Hashable {
    static let quantileCount = 17
    static let hueSectors = 12

    var version: Int = 1

    // MARK: Light
    /// Oklab lightness at evenly spaced percentiles (0.5% ... 99.5%).
    var luminance: [Float]

    // MARK: Color
    /// Mean lightness of the shadow, midtone and highlight zones.
    var zoneLuma: [Float]
    /// Average Oklab a/b offset (the tint) of each zone.
    var zoneTintA: [Float]
    var zoneTintB: [Float]
    /// Mean chroma once zone tints are removed.
    var chroma: Float
    /// Mean chroma per 30° hue family (relative saturation roll-off).
    var hueChroma: [Float]
    /// Share of colorful pixels that fall into each hue family.
    var huePopulation: [Float]

    // MARK: Texture
    var grain: Float
    var grainSize: Float

    // MARK: Optics
    var vignette: Float
    var halation: Float
    var aberration: Float
    /// Oklab lightness where halation starts to glow.
    var halationThreshold: Float? = nil
    /// 0 = vignette only in the corners, 1 = long, soft falloff.
    var vignetteFalloff: Float? = nil

    // MARK: Lighting (for depth relighting)
    /// Direction light comes from, in image space (x right, y up), and how
    /// directional it is (0 = flat/diffuse, 1 = hard single source).
    var lightX: Float? = nil
    var lightY: Float? = nil
    var lightStrength: Float? = nil

    var contrast: Float {
        luminance[13] - luminance[3]
    }

    var isMonochrome: Bool {
        chroma < 0.006 && zoneTintA.allSatisfy { abs($0) < 0.006 } && zoneTintB.allSatisfy { abs($0) < 0.006 }
    }

    /// Tint (a, b) at a given lightness, interpolated between zone anchors.
    func tint(at l: Float) -> SIMD2<Float> {
        let anchors = zoneLuma
        if l <= anchors[0] { return SIMD2(zoneTintA[0], zoneTintB[0]) }
        if l >= anchors[2] { return SIMD2(zoneTintA[2], zoneTintB[2]) }
        let i = l < anchors[1] ? 0 : 1
        let span = max(anchors[i + 1] - anchors[i], 1e-4)
        var t = (l - anchors[i]) / span
        t = t * t * (3 - 2 * t)
        return SIMD2(
            zoneTintA[i] + (zoneTintA[i + 1] - zoneTintA[i]) * t,
            zoneTintB[i] + (zoneTintB[i + 1] - zoneTintB[i]) * t
        )
    }

    /// A typical, neutral daylight photograph. Used when a style must be baked
    /// without knowing the destination image (e.g. .cube LUT export).
    static let neutral: StyleDNA = {
        let q = (0..<quantileCount).map { i -> Float in
            let p = Float(i) / Float(quantileCount - 1)
            // Gentle S-shaped distribution between deep shadow and highlight.
            let s = p * p * (3 - 2 * p)
            return 0.14 + (0.94 - 0.14) * (0.55 * p + 0.45 * s)
        }
        return StyleDNA(
            luminance: q,
            zoneLuma: [q[3], q[8], q[13]],
            zoneTintA: [0, 0, 0],
            zoneTintB: [0, 0, 0],
            chroma: 0.06,
            hueChroma: Array(repeating: 0.06, count: hueSectors),
            huePopulation: Array(repeating: 1 / Float(hueSectors), count: hueSectors),
            grain: 0, grainSize: 1, vignette: 0, halation: 0, aberration: 0
        )
    }()

    /// Weighted average of several looks ("50/30/20" blends).
    static func blend(_ parts: [(StyleDNA, Float)]) -> StyleDNA {
        let total = parts.reduce(0) { $0 + max($1.1, 0) }
        guard total > 0, let first = parts.first?.0 else { return .neutral }
        func mix(_ pick: (StyleDNA) -> Float) -> Float {
            parts.reduce(0) { $0 + pick($1.0) * max($1.1, 0) } / total
        }
        func mixOptional(_ pick: (StyleDNA) -> Float?) -> Float? {
            let present = parts.compactMap { part in pick(part.0).map { ($0, max(part.1, 0)) } }
            let w = present.reduce(0) { $0 + $1.1 }
            guard w > 0 else { return nil }
            return present.reduce(0) { $0 + $1.0 * $1.1 } / w
        }
        func mixArray(_ pick: (StyleDNA) -> [Float]) -> [Float] {
            let n = pick(first).count
            return (0..<n).map { i in parts.reduce(0) { $0 + pick($1.0)[i] * max($1.1, 0) } / total }
        }
        return StyleDNA(
            luminance: mixArray(\.luminance),
            zoneLuma: mixArray(\.zoneLuma),
            zoneTintA: mixArray(\.zoneTintA),
            zoneTintB: mixArray(\.zoneTintB),
            chroma: mix(\.chroma),
            hueChroma: mixArray(\.hueChroma),
            huePopulation: mixArray(\.huePopulation),
            grain: mix(\.grain),
            grainSize: mix(\.grainSize),
            vignette: mix(\.vignette),
            halation: mix(\.halation),
            aberration: mix(\.aberration),
            halationThreshold: mixOptional(\.halationThreshold),
            vignetteFalloff: mixOptional(\.vignetteFalloff),
            lightX: mixOptional(\.lightX),
            lightY: mixOptional(\.lightY),
            lightStrength: mixOptional(\.lightStrength)
        )
    }

    /// Ensures arrays have the expected shape (guards imported data).
    var isValid: Bool {
        let shapes: [Bool] = [
            luminance.count == Self.quantileCount,
            zoneLuma.count == 3,
            zoneTintA.count == 3,
            zoneTintB.count == 3,
            hueChroma.count == Self.hueSectors,
            huePopulation.count == Self.hueSectors,
        ]
        guard !shapes.contains(false) else { return false }
        let optionals: [Float] = [halationThreshold, vignetteFalloff, lightX, lightY, lightStrength].compactMap { $0 }
        let scalars: [Float] = [chroma, grain, grainSize, vignette, halation, aberration] + optionals
        let arrays: [[Float]] = [scalars, luminance, zoneLuma, zoneTintA, zoneTintB, hueChroma, huePopulation]
        return arrays.allSatisfy { $0.allSatisfy { $0.isFinite } }
    }
}
