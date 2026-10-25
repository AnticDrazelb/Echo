import Foundation

/// Hand-tuned starter looks, expressed directly as Style DNA.
enum BuiltInStyles {
    static var all: [Style] {
        [
            make("Blade Orange", black: 0.07, white: 0.90, gamma: 1.25, contrast: 0.6,
                 tints: [(-0.026, -0.032), (0.018, 0.034), (0.034, 0.074)], chroma: 0.075,
                 grain: 0.22, grainSize: 1.2, vignette: 0.45, halation: 0.42, aberration: 0.25),
            make("Wes Red", black: 0.06, white: 0.84, gamma: 1.3, contrast: 0.7,
                 tints: [(0.055, 0.018), (0.095, 0.04), (0.07, 0.05)], chroma: 0.03,
                 grain: 0.12, grainSize: 1, vignette: 0.5, halation: 0.22, aberration: 0),
            make("Dust Film", black: 0.17, white: 0.90, gamma: 1.0, contrast: 0.5,
                 tints: [(0, 0), (0, 0), (0, 0)], chroma: 0,
                 grain: 0.6, grainSize: 1.4, vignette: 0.42, halation: 0, aberration: 0),
            make("Cold Slate", black: 0.07, white: 0.82, gamma: 1.3, contrast: 0.5,
                 tints: [(-0.016, -0.05), (-0.018, -0.044), (-0.01, -0.03)], chroma: 0.03,
                 grain: 0.16, grainSize: 1, vignette: 0.4, halation: 0, aberration: 0.1),
            make("Golden Hour", black: 0.12, white: 0.96, gamma: 0.9, contrast: 0.35,
                 tints: [(0.012, 0.022), (0.022, 0.052), (0.026, 0.072)], chroma: 0.085,
                 grain: 0.08, grainSize: 1, vignette: 0.22, halation: 0.36, aberration: 0),
            make("Matcha Fade", black: 0.21, white: 0.90, gamma: 0.95, contrast: 0.2,
                 tints: [(-0.022, 0.008), (-0.012, 0.02), (0.0, 0.026)], chroma: 0.045,
                 grain: 0.32, grainSize: 1.2, vignette: 0.16, halation: 0, aberration: 0),
        ]
    }

    static func make(
        _ name: String,
        black: Float, white: Float, gamma: Float, contrast: Float,
        tints: [(Float, Float)], chroma: Float,
        grain: Float, grainSize: Float, vignette: Float, halation: Float, aberration: Float
    ) -> Style {
        let n = StyleDNA.quantileCount
        let q = (0..<n).map { i -> Float in
            let p = Float(i) / Float(n - 1)
            let s = p * p * (3 - 2 * p)
            let shaped = powf(p, gamma) * (1 - contrast) + s * contrast
            return black + (white - black) * shaped
        }
        let dna = StyleDNA(
            luminance: q,
            zoneLuma: [q[3], q[8], q[13]],
            zoneTintA: tints.map { $0.0 },
            zoneTintB: tints.map { $0.1 },
            chroma: chroma,
            hueChroma: Array(repeating: chroma, count: StyleDNA.hueSectors),
            huePopulation: Array(repeating: 0, count: StyleDNA.hueSectors),
            grain: grain, grainSize: grainSize, vignette: vignette, halation: halation, aberration: aberration
        )
        // Stable IDs so built-ins survive relaunches without duplication.
        let id = UUID(uuidString: String(format: "EC400000-0000-4000-8000-%012llX", UInt64(name.hashValueStable))) ?? UUID()
        return Style(id: id, name: name, dna: dna, creator: nil, createdAt: .distantPast, isBuiltIn: true)
    }
}

private extension String {
    /// FNV-1a, stable across launches (unlike `hashValue`).
    var hashValueStable: Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(h & 0xFFFF_FFFF_FFFF)
    }
}
