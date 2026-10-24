import CoreImage
import Foundation
import Vision

/// Extracts Style DNA from an image, entirely on device.
enum StyleAnalyzer {
    /// Analysis resolution. Statistics converge long before full resolution.
    /// Color statistics converge at low resolution; texture needs detail
    /// (analysis never looks at more than 1024px on the long side).
    private static let colorSide = 256
    private static let textureSide = 1024

    struct Options {
        /// Skip text and UI chrome (useful for screenshots and posters).
        var ignoreText = true
    }

    static func analyze(_ image: CIImage, options: Options = Options()) -> StyleDNA {
        let exclusion = options.ignoreText ? textRegions(in: image) : []
        let color = sample(image, longSide: colorSide)
        let texture = sample(image, longSide: textureSide)
        return analyze(color: color, texture: texture, excluding: exclusion)
    }

    // MARK: - Sampling

    struct Bitmap {
        var width: Int
        var height: Int
        var pixels: [UInt8] // RGBA8, sRGB, top-left origin

        func rgb(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = (y * width + x) * 4
            return SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2])) / 255
        }
    }

    static func sample(_ image: CIImage, longSide: Int) -> Bitmap {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else {
            return Bitmap(width: 1, height: 1, pixels: [128, 128, 128, 255])
        }
        let scale = CGFloat(longSide) / max(extent.width, extent.height)
        let w = max(1, Int((extent.width * min(scale, 1)).rounded()))
        let h = max(1, Int((extent.height * min(scale, 1)).rounded()))
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / extent.width, y: CGFloat(h) / extent.height))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        RenderEngine.shared.context.render(
            scaled,
            toBitmap: &pixels,
            rowBytes: w * 4,
            bounds: CGRect(x: 0, y: 0, width: w, height: h),
            format: .RGBA8,
            colorSpace: RenderEngine.sRGB
        )
        return Bitmap(width: w, height: h, pixels: pixels)
    }

    /// Normalized (0...1, top-left origin) rectangles containing text.
    static func textRegions(in image: CIImage) -> [CGRect] {
        let request = VNDetectTextRectanglesRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try? handler.perform([request])
        return (request.results ?? []).map { obs in
            let b = obs.boundingBox.insetBy(dx: -0.01, dy: -0.01)
            return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
        }
    }

    // MARK: - Statistics

    static func analyze(color: Bitmap, texture: Bitmap, excluding: [CGRect] = []) -> StyleDNA {
        var labs: [SIMD3<Float>] = []
        labs.reserveCapacity(color.width * color.height)
        var centerSum: Float = 0, centerCount: Float = 0
        var edgeSum: Float = 0, edgeCount: Float = 0
        var ringSum: Float = 0, ringCount: Float = 0

        for y in 0..<color.height {
            for x in 0..<color.width {
                let u = (Float(x) + 0.5) / Float(color.width)
                let v = (Float(y) + 0.5) / Float(color.height)
                let lab = Oklab.fromSRGB(color.rgb(x, y))
                let dx = u - 0.5, dy = v - 0.5
                let r = (dx * dx + dy * dy).squareRoot() / 0.7071
                if r < 0.35 { centerSum += lab.x; centerCount += 1 }
                if r > 0.88 { edgeSum += lab.x; edgeCount += 1 }
                if r > 0.55, r < 0.75 { ringSum += lab.x; ringCount += 1 }
                if !excluding.isEmpty, excluding.contains(where: { $0.contains(CGPoint(x: CGFloat(u), y: CGFloat(v))) }) {
                    continue
                }
                labs.append(lab)
            }
        }
        if labs.count < 16 {
            labs = (0..<(color.width * color.height)).map { i in
                Oklab.fromSRGB(color.rgb(i % color.width, i / color.width))
            }
        }

        // Tone distribution.
        let sortedL = labs.map(\.x).sorted()
        func quantile(_ p: Float) -> Float {
            let idx = Int((p * Float(sortedL.count - 1)).rounded())
            return sortedL[min(max(idx, 0), sortedL.count - 1)]
        }
        var luminance = (0..<StyleDNA.quantileCount).map { i -> Float in
            let p = Float(i) / Float(StyleDNA.quantileCount - 1)
            return quantile(0.005 + p * 0.99)
        }
        for i in 1..<luminance.count where luminance[i] < luminance[i - 1] + 0.0005 {
            luminance[i] = luminance[i - 1] + 0.0005
        }

        // Zone tints: shadows (< 33rd pct), mids, highlights (> 66th pct).
        let t1 = quantile(0.33), t2 = quantile(0.66)
        var lumaSum = [Float](repeating: 0, count: 3)
        var zoneN = [Float](repeating: 0, count: 3)
        var wSum = [Float](repeating: 0, count: 3)
        var abSum = [SIMD2<Float>](repeating: .zero, count: 3)
        for lab in labs {
            let z = lab.x < t1 ? 0 : (lab.x < t2 ? 1 : 2)
            // Weight near-neutral pixels more: a tint is what greys turn into.
            let c = (lab.y * lab.y + lab.z * lab.z).squareRoot()
            let w: Float = 1 / (1 + c * 18)
            lumaSum[z] += lab.x
            zoneN[z] += 1
            wSum[z] += w
            abSum[z] += SIMD2(lab.y, lab.z) * w
        }
        var zoneLuma: [Float] = [], zoneA: [Float] = [], zoneB: [Float] = []
        let totalW = wSum.reduce(0, +)
        let overallTint = totalW > 0 ? (abSum[0] + abSum[1] + abSum[2]) / totalW : .zero
        for z in 0..<3 {
            zoneLuma.append(zoneN[z] > 0 ? lumaSum[z] / zoneN[z] : [0.25, 0.55, 0.85][z])
            // Empty zones (e.g. flat images) inherit the overall tint.
            let ab = wSum[z] > 0 ? abSum[z] / wSum[z] : overallTint
            zoneA.append(ab.x)
            zoneB.append(ab.y)
        }
        if zoneLuma[1] <= zoneLuma[0] { zoneLuma[1] = zoneLuma[0] + 0.01 }
        if zoneLuma[2] <= zoneLuma[1] { zoneLuma[2] = zoneLuma[1] + 0.01 }

        var dna = StyleDNA(
            luminance: luminance,
            zoneLuma: zoneLuma,
            zoneTintA: zoneA,
            zoneTintB: zoneB,
            chroma: 0,
            hueChroma: Array(repeating: 0, count: StyleDNA.hueSectors),
            huePopulation: Array(repeating: 0, count: StyleDNA.hueSectors),
            grain: 0, grainSize: 1, vignette: 0, halation: 0, aberration: 0
        )

        // Saturation, overall and per hue family, after removing zone tints.
        var chromaSum: Float = 0
        var sectorSum = [Float](repeating: 0, count: StyleDNA.hueSectors)
        var sectorN = [Float](repeating: 0, count: StyleDNA.hueSectors)
        var colorful: Float = 0
        for lab in labs {
            let t = dna.tint(at: lab.x)
            let a = lab.y - t.x, b = lab.z - t.y
            let c = (a * a + b * b).squareRoot()
            chromaSum += c
            if c > 0.02 {
                var h = atan2f(b, a)
                if h < 0 { h += 2 * .pi }
                let s = min(Int(h / (2 * .pi) * Float(StyleDNA.hueSectors)), StyleDNA.hueSectors - 1)
                sectorSum[s] += c
                sectorN[s] += 1
                colorful += 1
            }
        }
        dna.chroma = chromaSum / Float(labs.count)
        for s in 0..<StyleDNA.hueSectors {
            dna.hueChroma[s] = sectorN[s] > 0 ? sectorSum[s] / sectorN[s] : dna.chroma
            dna.huePopulation[s] = colorful > 0 ? sectorN[s] / colorful : 0
        }

        // Highlights that carry a warm tint read as halation / bloom.
        let brightShare = Float(sortedL.filter { $0 > 0.88 }.count) / Float(sortedL.count)
        let warmHighlights = max(0, zoneA[2] * 0.6 + zoneB[2]) * 18
        dna.halation = min(0.6, brightShare * 2.5 * min(1, warmHighlights + 0.2))
        dna.halationThreshold = min(0.95, max(0.7, quantile(0.97) - 0.04))

        // Vignette: how much darker the frame edges are than the center.
        if centerCount > 0, edgeCount > 0 {
            let ratio = (edgeSum / edgeCount) / max(centerSum / centerCount, 0.05)
            dna.vignette = min(0.85, max(0, (1 - ratio) - 0.12) * 1.4)
            // How much of the darkening already happens mid-frame: soft vs. tight.
            let center = centerSum / centerCount, edge = edgeSum / edgeCount
            if ringCount > 0, center - edge > 0.02 {
                let ring = ringSum / ringCount
                dna.vignetteFalloff = min(0.95, max(0.25, 0.25 + 0.7 * (center - ring) / (center - edge)))
            }
        }

        let light = estimateLight(color)
        dna.lightX = light.x
        dna.lightY = light.y
        dna.lightStrength = light.z

        let (grain, size) = estimateGrain(texture)
        dna.grain = grain
        dna.grainSize = size
        return dna
    }

    /// Estimates where the key light comes from by averaging shading
    /// gradients (bright side of every soft edge points toward the light).
    /// Returns (x, y, strength) with y up; strength 0 means flat light.
    static func estimateLight(_ bmp: Bitmap) -> SIMD3<Float> {
        let w = bmp.width, h = bmp.height
        guard w > 4, h > 4 else { return SIMD3(0, 1, 0) }
        var lum = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let c = bmp.rgb(x, y)
                lum[y * w + x] = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
            }
        }
        var sum = SIMD2<Float>.zero
        var magnitude: Float = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let gx = lum[y * w + x + 1] - lum[y * w + x - 1]
                let gy = lum[(y - 1) * w + x] - lum[(y + 1) * w + x] // y up
                let m = (gx * gx + gy * gy).squareRoot()
                // Ignore hard edges (object outlines); keep gentle shading.
                guard m > 0.004, m < 0.12 else { continue }
                sum += SIMD2(gx, gy)
                magnitude += m
            }
        }
        guard magnitude > 0 else { return SIMD3(0, 1, 0) }
        let len = (sum.x * sum.x + sum.y * sum.y).squareRoot()
        guard len > 1e-5 else { return SIMD3(0, 1, 0) }
        let dir = sum / len
        let strength = min(1, len / magnitude * 3)
        return SIMD3(dir.x, dir.y, strength)
    }

    /// Estimates film grain / sensor noise from the high-frequency residual of
    /// smooth areas. The median rejects real edges and detail.
    static func estimateGrain(_ bmp: Bitmap) -> (Float, Float) {
        let w = bmp.width, h = bmp.height
        guard w > 8, h > 8 else { return (0, 1) }
        var lum = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let c = bmp.rgb(x, y)
                lum[y * w + x] = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
            }
        }
        var fine: [Float] = []
        var coarse: [Float] = []
        fine.reserveCapacity(w * h / 4)
        var y = 2
        while y < h - 2 {
            var x = 2
            while x < w - 2 {
                let c = lum[y * w + x]
                let n1 = (lum[y * w + x - 1] + lum[y * w + x + 1] + lum[(y - 1) * w + x] + lum[(y + 1) * w + x]) / 4
                let n2 = (lum[y * w + x - 2] + lum[y * w + x + 2] + lum[(y - 2) * w + x] + lum[(y + 2) * w + x]) / 4
                fine.append(abs(c - n1))
                coarse.append(abs(c - n2))
                x += 2
            }
            y += 2
        }
        fine.sort()
        coarse.sort()
        let mf = fine[fine.count / 2]
        let mc = coarse[coarse.count / 2]
        let amount = min(1, max(0, (mf - 0.004) / 0.018))
        // Coarser grain keeps more energy at the wider sampling distance.
        let size: Float = mf > 0.0005 ? min(2.2, max(0.8, mc / mf * 0.9)) : 1
        return (amount, size)
    }
}
