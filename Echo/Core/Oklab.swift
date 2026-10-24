import Foundation
import simd

/// Perceptual color math used by the style engine.
///
/// Echo works in Oklab: lightness (L) is perceptually uniform and the a/b
/// plane is an opponent color space, so "tone", "tint" and "saturation" can be
/// measured and transferred independently.
enum Oklab {
    @inline(__always)
    static func srgbToLinear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    @inline(__always)
    static func linearToSRGB(_ c: Float) -> Float {
        let v = max(c, 0)
        return v <= 0.0031308 ? v * 12.92 : 1.055 * powf(v, 1 / 2.4) - 0.055
    }

    /// Linear sRGB -> Oklab (L, a, b).
    @inline(__always)
    static func fromLinear(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let l = 0.4122214708 * rgb.x + 0.5363325363 * rgb.y + 0.0514459929 * rgb.z
        let m = 0.2119034982 * rgb.x + 0.6806995451 * rgb.y + 0.1073969566 * rgb.z
        let s = 0.0883024619 * rgb.x + 0.2817188376 * rgb.y + 0.6299787005 * rgb.z
        let l_ = cbrtf(l), m_ = cbrtf(m), s_ = cbrtf(s)
        return SIMD3(
            0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        )
    }

    /// Oklab -> linear sRGB (may fall outside 0...1).
    @inline(__always)
    static func toLinear(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        let m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        let s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return SIMD3(
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    @inline(__always)
    static func fromSRGB(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        fromLinear(SIMD3(srgbToLinear(rgb.x), srgbToLinear(rgb.y), srgbToLinear(rgb.z)))
    }

    /// Oklab -> gamma-encoded sRGB, pulling chroma in (rather than clipping
    /// channels) when the color is out of gamut so hues stay true.
    static func toSRGBClamped(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        var c = lab
        c.x = min(max(c.x, 0), 1)
        var lin = toLinear(c)
        if !inGamut(lin) {
            var lo: Float = 0, hi: Float = 1
            for _ in 0..<8 {
                let mid = (lo + hi) / 2
                let test = toLinear(SIMD3(c.x, c.y * mid, c.z * mid))
                if inGamut(test) { lo = mid } else { hi = mid }
            }
            lin = toLinear(SIMD3(c.x, c.y * lo, c.z * lo))
        }
        lin = simd_clamp(lin, SIMD3(repeating: 0), SIMD3(repeating: 1))
        return SIMD3(linearToSRGB(lin.x), linearToSRGB(lin.y), linearToSRGB(lin.z))
    }

    @inline(__always)
    private static func inGamut(_ lin: SIMD3<Float>) -> Bool {
        let e: Float = 0.0005
        return lin.x >= -e && lin.y >= -e && lin.z >= -e && lin.x <= 1 + e && lin.y <= 1 + e && lin.z <= 1 + e
    }
}
