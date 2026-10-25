import Foundation
import simd

/// Maps colors from a source image's statistics onto a reference look.
///
/// The transfer is content-adaptive: the same reference produces a different
/// mapping for a bright beach photo than for a dim interior, because tones are
/// matched by *distribution* rather than pushed by a fixed curve.
struct StyleTransfer {
    let reference: StyleDNA
    let source: StyleDNA
    var light = true
    var color = true

    private let curve: [Float]
    private let chromaScale: Float
    private let sectorScale: [Float]

    private static let curveSamples = 1024

    init(reference: StyleDNA, source: StyleDNA, light: Bool = true, color: Bool = true) {
        self.reference = reference
        self.source = source
        self.light = light
        self.color = color
        curve = Self.buildCurve(from: source.luminance, to: reference.luminance)

        if reference.isMonochrome {
            chromaScale = 0
            sectorScale = Array(repeating: 1, count: StyleDNA.hueSectors)
        } else {
            chromaScale = source.chroma < 0.008 ? 1 : min(2.2, max(0.05, reference.chroma / source.chroma))
            sectorScale = (0..<StyleDNA.hueSectors).map { s in
                let refRel = reference.hueChroma[s] / max(reference.chroma, 0.005)
                let srcRel = source.hueChroma[s] / max(source.chroma, 0.005)
                let ratio = min(1.6, max(0.55, refRel / max(srcRel, 0.05)))
                let confidence = min(1, min(reference.huePopulation[s], source.huePopulation[s]) * 10)
                return 1 + (ratio - 1) * confidence
            }
        }
    }

    // MARK: Tone curve

    /// Histogram-matching curve with slope limits and smoothing so the result
    /// never posterizes, even between wildly different images.
    static func buildCurve(from src: [Float], to ref: [Float]) -> [Float] {
        let n = curveSamples
        var out = [Float](repeating: 0, count: n)
        let last = src.count - 1
        for i in 0..<n {
            let l = Float(i) / Float(n - 1)
            let v: Float
            if l <= src[0] {
                v = src[0] > 0.001 ? ref[0] * l / src[0] : ref[0]
            } else if l >= src[last] {
                let span = 1 - src[last]
                v = span > 0.001 ? ref[last] + (l - src[last]) * (1 - ref[last]) / span : ref[last]
            } else {
                var k = 0
                while k < last - 1, l > src[k + 1] { k += 1 }
                let t = (l - src[k]) / max(src[k + 1] - src[k], 1e-5)
                v = ref[k] + (ref[k + 1] - ref[k]) * t
            }
            out[i] = v
        }

        // Limit slope (max 1.5x) so gradients never posterize.
        let dx = 1 / Float(n - 1)
        var limited = out
        for i in 1..<n {
            let slope = (out[i] - out[i - 1]) / dx
            // Shadows keep at least 0.6x slope so dark detail never crushes.
            let floor: Float = Float(i) < Float(n) * 0.3 ? 0.6 : 0.35
            limited[i] = limited[i - 1] + min(1.5, max(floor, slope)) * dx
        }
        // Re-anchor around the midtones so the overall brightness target holds.
        let mid = n / 2
        let shift = out[mid] - limited[mid]
        for i in 0..<n { limited[i] += shift }

        // Two passes of a small box filter remove kinks at quantile joints.
        for _ in 0..<2 {
            var smooth = limited
            let r = 12
            for i in 0..<n {
                let a = max(0, i - r), b = min(n - 1, i + r)
                var sum: Float = 0
                for j in a...b { sum += limited[j] }
                smooth[i] = sum / Float(b - a + 1)
            }
            limited = smooth
        }
        return limited.map { min(1, max(0, $0)) }
    }

    @inline(__always)
    func tone(_ l: Float) -> Float {
        let x = min(max(l, 0), 1) * Float(Self.curveSamples - 1)
        let i = Int(x)
        if i >= Self.curveSamples - 1 { return curve[Self.curveSamples - 1] }
        let t = x - Float(i)
        return curve[i] + (curve[i + 1] - curve[i]) * t
    }

    // MARK: Color mapping

    @inline(__always)
    private func sectorFactor(a: Float, b: Float) -> Float {
        var h = atan2f(b, a)
        if h < 0 { h += 2 * .pi }
        let pos = h / (2 * .pi) * Float(StyleDNA.hueSectors) - 0.5
        let base = Int(floorf(pos))
        let t = pos - Float(base)
        let n = StyleDNA.hueSectors
        let s0 = ((base % n) + n) % n
        let s1 = (s0 + 1) % n
        return sectorScale[s0] * (1 - t) + sectorScale[s1] * t
    }

    func map(lab: SIMD3<Float>) -> SIMD3<Float> {
        var out = lab
        if light { out.x = tone(lab.x) }
        if color {
            let srcTint = source.tint(at: lab.x)
            let refTint = reference.tint(at: out.x)
            let a0 = lab.y - srcTint.x * 0.85
            let b0 = lab.z - srcTint.y * 0.85
            let c = (a0 * a0 + b0 * b0).squareRoot()
            var scale = chromaScale
            if c > 0.004, chromaScale > 0 { scale *= sectorFactor(a: a0, b: b0) }
            // Ease saturation boosts on already vivid colors (soft roll-off).
            if scale > 1 { scale = 1 + (scale - 1) * max(0, 1 - c * 4) }
            out.y = a0 * scale + refTint.x
            out.z = b0 * scale + refTint.y
            if !reference.isMonochrome { protectSkin(source: lab, output: &out) }
        }
        return out
    }

    /// Skin-tone protection: colors on the skin-tone band keep their hue and
    /// change saturation by at most ±25%, so faces stay alive under strong
    /// looks. (Monochrome looks are exempt.)
    static let skinProtection: Float = 0.7

    private func protectSkin(source lab: SIMD3<Float>, output out: inout SIMD3<Float>) {
        let srcC = (lab.y * lab.y + lab.z * lab.z).squareRoot()
        guard srcC > 0.015 else { return }
        var hue = atan2f(lab.z, lab.y) * 180 / .pi
        if hue < 0 { hue += 360 }
        func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
            let t = min(max((x - e0) / (e1 - e0), 0), 1)
            return t * t * (3 - 2 * t)
        }
        let weight = smooth(12, 30, hue) * (1 - smooth(72, 95, hue))
            * smooth(0.02, 0.04, srcC) * (1 - smooth(0.17, 0.23, srcC))
            * smooth(0.22, 0.38, lab.x) * (1 - smooth(0.9, 0.97, lab.x))
            * Self.skinProtection
        guard weight > 0.001 else { return }
        let outC = (out.y * out.y + out.z * out.z).squareRoot()
        let targetC = min(max(outC, srcC * 0.75), srcC * 1.25)
        let protectedA = lab.y / srcC * targetC
        let protectedB = lab.z / srcC * targetC
        out.y += (protectedA - out.y) * weight
        out.z += (protectedB - out.z) * weight
    }

    func map(srgb: SIMD3<Float>) -> SIMD3<Float> {
        Oklab.toSRGBClamped(map(lab: Oklab.fromSRGB(srgb)))
    }

    /// RGBA float cube for `CIColorCubeWithColorSpace` (red varies fastest).
    func cubeData(size: Int = 32) -> Data {
        var values = [Float](repeating: 0, count: size * size * size * 4)
        let d = Float(size - 1)
        var i = 0
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let c = map(srgb: SIMD3(Float(r) / d, Float(g) / d, Float(b) / d))
                    values[i] = c.x
                    values[i + 1] = c.y
                    values[i + 2] = c.z
                    values[i + 3] = 1
                    i += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
