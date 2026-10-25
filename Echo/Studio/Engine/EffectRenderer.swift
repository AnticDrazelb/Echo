import CoreImage
import Foundation

/// Inputs an effect may need besides its own parameters.
struct EffectContext {
    /// The full canvas rect.
    let canvas: CGRect
    let time: Double
    /// Statistics of the base media (for Echo Look's adaptive transfer).
    let baseStats: StyleDNA
    /// Vision subject mask for the base (photos), canvas-sized.
    let subjectMask: CIImage?
    /// Shared cache so Echo Look cubes aren't rebuilt every frame.
    let renderers: RendererCache
}

/// Caches Echo Look renderers by effect + look.
final class RendererCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: StyleRenderer] = [:]

    func renderer(for dna: StyleDNA, source: StyleDNA, key: UUID) -> StyleRenderer {
        let k = "\(key)-\(dna.hashValue)-\(source.hashValue)"
        lock.lock(); defer { lock.unlock() }
        if let r = cache[k] { return r }
        if cache.count > 24 { cache.removeAll() }
        let r = StyleRenderer(reference: dna, source: source)
        cache[k] = r
        return r
    }
}

enum EffectRenderer {
    static func apply(_ effect: Effect, to input: CIImage, ctx: EffectContext) -> CIImage {
        guard effect.isEnabled else { return input }
        let t = ctx.time
        let p: (String) -> Double = { effect.value($0, at: t) }
        let ext = ctx.canvas
        let w = ext.width

        var out: CIImage
        switch effect.type {
        case .look:
            guard let dna = effect.dna else { return input }
            let renderer = ctx.renderers.renderer(for: dna, source: ctx.baseStats, key: effect.id)
            out = renderer.apply(input, settings: RenderSettings(intensity: Float(p("intensity"))), seed: Int(t * 24))

        case .exposure:
            out = input.applyingFilter("CIExposureAdjust", parameters: ["inputEV": p("ev")])

        case .contrast:
            out = input.applyingFilter("CIColorControls", parameters: [
                "inputContrast": p("contrast"), "inputBrightness": p("brightness"), "inputSaturation": 1,
            ])

        case .saturation:
            out = input
                .applyingFilter("CIColorControls", parameters: ["inputSaturation": p("saturation"), "inputContrast": 1, "inputBrightness": 0])
                .applyingFilter("CIVibrance", parameters: ["inputAmount": p("vibrance")])

        case .temperature:
            out = input.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: CGFloat(p("temperature")), y: CGFloat(p("tint"))),
            ])

        case .curves:
            var params: [String: Any] = [:]
            var last: CGFloat = -1
            for i in 0..<5 {
                // Keep the curve monotonic so it can't invert tones.
                let y = max(CGFloat(p("p\(i)")), last + 0.001)
                last = y
                params["inputPoint\(i)"] = CIVector(x: CGFloat(i) / 4, y: min(y, 1))
            }
            out = input.applyingFilter("CIToneCurve", parameters: params)

        case .hue:
            out = input.applyingFilter("CIHueAdjust", parameters: ["inputAngle": p("angle") * .pi / 180])

        case .duotone:
            out = input.applyingFilter("CIFalseColor", parameters: [
                "inputColor0": CIColor(red: p("r0"), green: p("g0"), blue: p("b0")),
                "inputColor1": CIColor(red: p("r1"), green: p("g1"), blue: p("b1")),
            ])

        case .blackWhite:
            out = input
                .applyingFilter("CIPhotoEffectMono")
                .applyingFilter("CIColorControls", parameters: ["inputContrast": p("contrast"), "inputSaturation": 0, "inputBrightness": 0])

        case .posterize:
            out = input.applyingFilter("CIColorPosterize", parameters: ["inputLevels": p("levels").rounded()])

        case .invert:
            out = input.applyingFilter("CIColorInvert")

        case .glow:
            out = input.clampedToExtent()
                .applyingFilter("CIBloom", parameters: ["inputRadius": p("radius") * w, "inputIntensity": p("intensity")])
                .cropped(to: ext)

        case .lightLeak:
            let center = CIVector(x: ext.minX + CGFloat(p("x")) * w, y: ext.maxY - CGFloat(p("y")) * ext.height)
            let (r, g, b) = hueColor(p("hue"))
            let s = p("strength")
            let leak = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": center,
                "inputRadius0": 0,
                "inputRadius1": p("radius") * w,
                "inputColor0": CIColor(red: r * s, green: g * s, blue: b * s),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0),
            ])?.outputImage?.cropped(to: ext)
            out = leak.map { $0.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: input]) } ?? input

        case .halation:
            var dna = StyleDNA.neutral
            dna.halation = Float(p("amount"))
            dna.halationThreshold = Float(p("threshold"))
            let renderer = ctx.renderers.renderer(for: dna, source: .neutral, key: effect.id)
            out = renderer.styled(input, settings: RenderSettings(intensity: 1, color: false, light: false, grain: false, optics: true))

        case .vignette:
            out = input.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: ext.midX, y: ext.midY),
                kCIInputRadiusKey: hypot(ext.width, ext.height) * 0.5 * CGFloat(p("size")),
                kCIInputIntensityKey: p("amount"),
                "inputFalloff": max(0.01, p("feather")),
            ])

        case .gaussian:
            out = input.clampedToExtent().applyingGaussianBlur(sigma: p("radius") * w).cropped(to: ext)

        case .motionBlur:
            out = input.clampedToExtent()
                .applyingFilter("CIMotionBlur", parameters: ["inputRadius": p("radius") * w, "inputAngle": p("angle") * .pi / 180])
                .cropped(to: ext)

        case .zoomBlur:
            out = input.clampedToExtent()
                .applyingFilter("CIZoomBlur", parameters: [
                    "inputCenter": CIVector(x: ext.minX + CGFloat(p("x")) * w, y: ext.maxY - CGFloat(p("y")) * ext.height),
                    "inputAmount": p("amount") * w,
                ])
                .cropped(to: ext)

        case .portraitBlur:
            let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: p("radius") * w).cropped(to: ext)
            if let mask = ctx.subjectMask {
                out = input.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: blurred, kCIInputMaskImageKey: mask,
                ])
            } else {
                out = blurred
            }

        case .sharpen:
            out = input.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": p("amount"), "inputRadius": max(1, w / 800)])

        case .denoise:
            out = input.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": p("level"), "inputSharpness": 0.4])

        case .grain:
            var dna = StyleDNA.neutral
            dna.grain = Float(p("amount"))
            dna.grainSize = Float(p("size"))
            let renderer = ctx.renderers.renderer(for: dna, source: .neutral, key: effect.id)
            out = renderer.styled(input, settings: RenderSettings(intensity: 1, color: false, light: false, grain: true, optics: false), seed: Int(t * 24))

        case .chromatic:
            var dna = StyleDNA.neutral
            dna.aberration = Float(p("amount")) * 4
            let renderer = ctx.renderers.renderer(for: dna, source: .neutral, key: effect.id)
            out = renderer.styled(input, settings: RenderSettings(intensity: 1, color: false, light: false, grain: false, optics: true))

        case .glitch:
            out = glitch(input, amount: p("amount"), speed: p("speed"), t: t, ext: ext)

        case .halftone:
            out = input.applyingFilter("CIDotScreen", parameters: [
                kCIInputCenterKey: CIVector(x: ext.midX, y: ext.midY),
                kCIInputAngleKey: p("angle") * .pi / 180,
                kCIInputWidthKey: max(2, p("size") * w),
                kCIInputSharpnessKey: 0.7,
            ]).cropped(to: ext)

        case .pixelate:
            out = input.clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [kCIInputCenterKey: CIVector(x: ext.minX, y: ext.minY), kCIInputScaleKey: max(2, p("size") * w)])
                .cropped(to: ext)

        case .comic:
            out = input.applyingFilter("CIComicEffect").cropped(to: ext)

        case .edges:
            let lines = input.applyingFilter("CIEdgeWork", parameters: [kCIInputRadiusKey: p("radius")]).cropped(to: ext)
            // Edge work is white ink on transparent: draw dark ink on paper.
            let paper = CIImage(color: CIColor(red: 0.96, green: 0.95, blue: 0.92)).cropped(to: ext)
            out = lines.applyingFilter("CIColorInvert").composited(over: paper)
                .applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: paper])

        case .scanlines:
            let stripe = max(1, ext.height / CGFloat(p("density")))
            let s = p("strength")
            let lines = CIFilter(name: "CIStripesGenerator", parameters: [
                kCIInputCenterKey: CIVector(x: 0, y: 0),
                "inputColor0": CIColor(red: 1, green: 1, blue: 1),
                "inputColor1": CIColor(red: 1 - s, green: 1 - s, blue: 1 - s),
                kCIInputWidthKey: stripe,
                kCIInputSharpnessKey: 0.6,
            ])?.outputImage?
                .transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
                .cropped(to: ext)
            out = lines.map { $0.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: input]) } ?? input

        case .kaleidoscope:
            out = input.clampedToExtent()
                .applyingFilter("CIKaleidoscope", parameters: [
                    "inputCount": max(2, p("count").rounded()),
                    kCIInputCenterKey: CIVector(x: ext.midX, y: ext.midY),
                    kCIInputAngleKey: p("angle") * .pi / 180,
                ])
                .cropped(to: ext)

        case .twirl:
            out = input.clampedToExtent()
                .applyingFilter("CITwirlDistortion", parameters: [
                    kCIInputCenterKey: CIVector(x: ext.minX + CGFloat(p("x")) * w, y: ext.maxY - CGFloat(p("y")) * ext.height),
                    kCIInputRadiusKey: p("radius") * w,
                    kCIInputAngleKey: p("angle") * .pi / 180,
                ])
                .cropped(to: ext)

        case .bulge:
            out = input.clampedToExtent()
                .applyingFilter("CIBumpDistortion", parameters: [
                    kCIInputCenterKey: CIVector(x: ext.minX + CGFloat(p("x")) * w, y: ext.maxY - CGFloat(p("y")) * ext.height),
                    kCIInputRadiusKey: p("radius") * w,
                    kCIInputScaleKey: p("scale"),
                ])
                .cropped(to: ext)

        case .shake:
            out = shake(input, amount: p("amount"), frequency: p("frequency"), rotation: p("rotation"), t: t, ext: ext)
        }

        out = out.cropped(to: ext)
        let mix = p("mix")
        if mix >= 0.999 { return out }
        if mix <= 0.001 { return input }
        let dissolve = CIFilter(name: "CIDissolveTransition", parameters: [
            kCIInputImageKey: input, kCIInputTargetImageKey: out, kCIInputTimeKey: mix,
        ])
        return (dissolve?.outputImage ?? out).cropped(to: ext)
    }

    // MARK: Helpers

    static func hueColor(_ degrees: Double) -> (Double, Double, Double) {
        let h = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        switch Int(h) {
        case 0: return (1, x, 0)
        case 1: return (x, 1, 0)
        case 2: return (0, 1, x)
        case 3: return (0, x, 1)
        case 4: return (x, 0, 1)
        default: return (1, 0, x)
        }
    }

    /// Deterministic pseudo-random in 0...1.
    static func hash(_ n: Int) -> Double {
        var x = UInt64(bitPattern: Int64(n)) &* 0x9E3779B97F4A7C15
        x ^= x >> 31
        x = x &* 0xBF58476D1CE4E5B9
        x ^= x >> 29
        return Double(x % 10_000) / 10_000
    }

    /// Smooth noise in -1...1 for camera shake.
    static func wobble(_ t: Double, seed: Double) -> Double {
        0.55 * sin(t * 2 * .pi * 1.0 + seed) + 0.3 * sin(t * 2 * .pi * 1.73 + seed * 2.1) + 0.15 * sin(t * 2 * .pi * 3.11 + seed * 3.7)
    }

    private static func shake(_ input: CIImage, amount: Double, frequency: Double, rotation: Double, t: Double, ext: CGRect) -> CIImage {
        let ft = t * frequency / 2
        let dx = wobble(ft, seed: 0.3) * amount * ext.width
        let dy = wobble(ft, seed: 1.9) * amount * ext.width
        let rot = wobble(ft, seed: 4.2) * rotation * .pi / 180
        // Scale up slightly so the moving frame never reveals its edges.
        let cover = 1 + amount * 2.5 + abs(rotation) * 0.012
        let transform = CGAffineTransform(translationX: -ext.midX, y: -ext.midY)
            .concatenating(CGAffineTransform(scaleX: cover, y: cover))
            .concatenating(CGAffineTransform(rotationAngle: rot))
            .concatenating(CGAffineTransform(translationX: ext.midX + dx, y: ext.midY + dy))
        return input.clampedToExtent().transformed(by: transform).cropped(to: ext)
    }

    private static func glitch(_ input: CIImage, amount: Double, speed: Double, t: Double, ext: CGRect) -> CIImage {
        guard amount > 0.001 else { return input }
        let step = Int(t * speed)
        // RGB split jitter.
        let split = (hash(step) - 0.5) * amount * ext.width * 0.03
        func channel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, dx: CGFloat) -> CIImage {
            input.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ]).clampedToExtent().transformed(by: CGAffineTransform(translationX: dx, y: 0))
        }
        var out = channel(1, 0, 0, dx: split)
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: channel(0, 1, 0, dx: 0)])
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: channel(0, 0, 1, dx: -split)])
            .cropped(to: ext)
        // Displaced horizontal slices.
        let slices = 3 + Int(hash(step * 7 + 1) * 5 * amount)
        for i in 0..<slices {
            let y = ext.minY + CGFloat(hash(step * 31 + i)) * ext.height
            let h = CGFloat(0.01 + hash(step * 17 + i) * 0.07 * amount) * ext.height
            let dx = (hash(step * 13 + i) - 0.5) * amount * ext.width * 0.15
            let band = CGRect(x: ext.minX, y: y, width: ext.width, height: h)
            let slice = out.clampedToExtent().transformed(by: CGAffineTransform(translationX: dx, y: 0)).cropped(to: band)
            out = slice.composited(over: out)
        }
        return out.cropped(to: ext)
    }
}
