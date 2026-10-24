import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Which parts of a look are applied, and how strongly.
struct RenderSettings: Equatable, Codable {
    var intensity: Float = 0.75
    var color = true
    var light = true
    var grain = true
    var optics = true
}

/// Builds the Core Image graph that applies a reference look to an image.
/// Thread-safe: the same renderer serves the preview, video frames and export.
final class StyleRenderer: @unchecked Sendable {
    let reference: StyleDNA
    private let lock = NSLock()
    private var source: StyleDNA
    private var cubes: [Int: Data] = [:]
    static let cubeSize = 32

    init(reference: StyleDNA, source: StyleDNA) {
        self.reference = reference
        self.source = source
    }

    /// Updates the destination statistics (e.g. as a live camera scene changes).
    /// The default cube is rebuilt before swapping so concurrent renders
    /// never stall on it.
    func updateSource(_ dna: StyleDNA) {
        let data = StyleTransfer(reference: reference, source: dna).cubeData(size: Self.cubeSize)
        lock.lock()
        source = dna
        cubes = [Self.key(light: true, color: true): data]
        lock.unlock()
    }

    private static func key(light: Bool, color: Bool) -> Int {
        (light ? 1 : 0) | (color ? 2 : 0)
    }

    var currentSource: StyleDNA {
        lock.lock(); defer { lock.unlock() }
        return source
    }

    func cube(light: Bool, color: Bool) -> Data {
        let key = Self.key(light: light, color: color)
        lock.lock()
        if let cached = cubes[key] { lock.unlock(); return cached }
        let src = source
        lock.unlock()
        let data = StyleTransfer(reference: reference, source: src, light: light, color: color)
            .cubeData(size: Self.cubeSize)
        lock.lock()
        cubes[key] = data
        lock.unlock()
        return data
    }

    /// Precomputes the default cube off the main thread.
    func warmUp() {
        _ = cube(light: true, color: true)
    }

    // MARK: - Graph

    /// The fully styled image, before intensity and region masks.
    func styled(_ image: CIImage, settings: RenderSettings, seed: Int = 0) -> CIImage {
        let extent = image.extent
        var out = image

        if settings.light || settings.color {
            let f = CIFilter.colorCubeWithColorSpace()
            f.inputImage = out
            f.cubeDimension = Float(Self.cubeSize)
            f.cubeData = cube(light: settings.light, color: settings.color)
            f.colorSpace = RenderEngine.sRGB
            out = f.outputImage ?? out
        }

        if settings.optics {
            if reference.halation > 0.02 {
                out = halation(out, amount: reference.halation, threshold: reference.halationThreshold ?? 0.85, extent: extent)
            }
            if reference.aberration > 0.02 { out = aberration(out, amount: reference.aberration, extent: extent) }
            if reference.vignette > 0.02 { out = vignette(out, amount: reference.vignette, extent: extent) }
        }

        if settings.grain, reference.grain > 0.02 {
            out = grain(out, amount: reference.grain, size: reference.grainSize, extent: extent, seed: seed)
        }
        return out.cropped(to: extent)
    }

    /// Styled image blended with the original by intensity and an optional
    /// region mask (white = apply).
    func apply(_ image: CIImage, settings: RenderSettings, mask: CIImage? = nil, seed: Int = 0) -> CIImage {
        let extent = image.extent
        let intensity = CGFloat(min(max(settings.intensity, 0), 1))
        guard intensity > 0.001 else { return image }
        let full = styled(image, settings: settings, seed: seed)

        if let mask {
            let scaledMask = mask
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: intensity, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: intensity, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: intensity, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                ])
            let blend = CIFilter.blendWithMask()
            blend.inputImage = full
            blend.backgroundImage = image
            blend.maskImage = scaledMask
            return (blend.outputImage ?? full).cropped(to: extent)
        }
        if intensity >= 0.999 { return full }
        let dissolve = CIFilter.dissolveTransition()
        dissolve.inputImage = image
        dissolve.targetImage = full
        dissolve.time = Float(intensity)
        return (dissolve.outputImage ?? full).cropped(to: extent)
    }

    // MARK: - Effects

    private func grain(_ image: CIImage, amount: Float, size: Float, extent: CGRect, seed: Int) -> CIImage {
        guard let noise = CIFilter.randomGenerator().outputImage else { return image }
        let scale = max(1, extent.shortSide / 1100) * CGFloat(max(0.6, size))
        let offset = CGFloat((seed &* 7919) % 997)
        let amp = CGFloat(amount) * 0.42
        let mono = noise
            .transformed(by: CGAffineTransform(translationX: offset * 13, y: offset * 7))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: amp, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: amp, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: amp, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0.5 - amp / 2, y: 0.5 - amp / 2, z: 0.5 - amp / 2, w: 1),
            ])
            .cropped(to: extent)
        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = mono
        blend.backgroundImage = image
        return blend.outputImage ?? image
    }

    private func vignette(_ image: CIImage, amount: Float, extent: CGRect) -> CIImage {
        let f = CIFilter.vignetteEffect()
        f.inputImage = image
        f.center = CGPoint(x: extent.midX, y: extent.midY)
        f.radius = Float(hypot(extent.width, extent.height) * 0.36)
        f.intensity = min(1, amount * 0.95)
        f.falloff = reference.vignetteFalloff ?? 0.65
        return f.outputImage ?? image
    }

    private func halation(_ image: CIImage, amount: Float, threshold: Float, extent: CGRect) -> CIImage {
        let k: CGFloat = 3.2
        // Oklab L is roughly the cube root of linear luminance.
        let t = CGFloat(powf(min(max(threshold, 0.5), 0.98), 3))
        let lum = CIVector(x: 0.2126 * k, y: 0.7152 * k, z: 0.0722 * k, w: 0)
        let highlights = image
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": lum, "inputGVector": lum, "inputBVector": lum,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -t * k, y: -t * k, z: -t * k, w: 1),
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
        let radius = extent.shortSide * 0.014
        let a = CGFloat(amount)
        let glow = highlights
            .clampedToExtent()
            .applyingGaussianBlur(sigma: radius)
            .cropped(to: extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.95 * a, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.38 * a, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.16 * a, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
        let add = CIFilter.additionCompositing()
        add.inputImage = glow
        add.backgroundImage = image
        return add.outputImage ?? image
    }

    private func aberration(_ image: CIImage, amount: Float, extent: CGRect) -> CIImage {
        let delta = extent.shortSide * 0.0025 * CGFloat(amount)
        func channel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, alpha: CGFloat) -> CIImage {
            image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            ])
        }
        func scaled(_ img: CIImage, by d: CGFloat) -> CIImage {
            let s = (extent.width + 2 * d) / extent.width
            return img
                .transformed(by: CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
                    .concatenating(CGAffineTransform(scaleX: s, y: s))
                    .concatenating(CGAffineTransform(translationX: extent.midX, y: extent.midY)))
        }
        let red = scaled(channel(1, 0, 0, alpha: 0).clampedToExtent(), by: delta)
        let green = channel(0, 1, 0, alpha: 1)
        let blue = scaled(channel(0, 0, 1, alpha: 0).clampedToExtent(), by: -delta)
        let rg = CIFilter.additionCompositing()
        rg.inputImage = red
        rg.backgroundImage = green
        let rgb = CIFilter.additionCompositing()
        rgb.inputImage = blue
        rgb.backgroundImage = rg.outputImage
        return (rgb.outputImage ?? image).cropped(to: extent)
    }
}

extension CGRect {
    var shortSide: CGFloat { min(width, height) }
}
