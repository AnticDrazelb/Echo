import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// Where a look is applied.
enum StyleRegion: String, CaseIterable, Identifiable, Codable {
    case auto, sky, skin, subject

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .sky: "Sky"
        case .skin: "Skin"
        case .subject: "Subject"
        }
    }
}

/// Builds soft, on-device masks for smart regions. All masks share the
/// extent of the analysed image (which must start at the origin).
enum RegionMasker {
    struct Masks {
        var sky: CIImage?
        var skin: CIImage?
        var subject: CIImage?

        func mask(for region: StyleRegion) -> CIImage? {
            switch region {
            case .auto: nil
            case .sky: sky
            case .skin: skin
            case .subject: subject
            }
        }
    }

    static func masks(for image: CIImage) -> Masks {
        let extent = image.extent
        let subject = subjectMask(image)
        let person = personMask(image) ?? subject

        // Sky: blue / bright-neutral colors, weighted to the top of the frame,
        // never on the subject.
        var sky = colorMask(image) { lab in
            let c = (lab.y * lab.y + lab.z * lab.z).squareRoot()
            var h = atan2f(lab.z, lab.y) * 180 / .pi
            if h < 0 { h += 360 }
            let blue = smooth(195, 225, h) * (1 - smooth(275, 300, h)) * smooth(0.015, 0.04, c) * smooth(0.42, 0.6, lab.x)
            let overcast = smooth(0.80, 0.92, lab.x) * (1 - smooth(0.03, 0.06, c))
            return max(blue, overcast * 0.85)
        }
        let topWeight = CIFilter.linearGradient()
        topWeight.point0 = CGPoint(x: extent.midX, y: extent.maxY)
        topWeight.point1 = CGPoint(x: extent.midX, y: extent.minY + extent.height * 0.25)
        topWeight.color0 = CIColor(red: 1, green: 1, blue: 1)
        topWeight.color1 = CIColor(red: 0, green: 0, blue: 0)
        if let gradient = topWeight.outputImage?.cropped(to: extent) {
            sky = multiply(sky, gradient)
        }
        if let subject { sky = multiply(sky, subject.applyingFilter("CIColorInvert")) }
        sky = soften(sky, extent: extent, amount: 0.012)

        // Skin: warm, moderately saturated tones, restricted to people when found.
        var skin = colorMask(image) { lab in
            let c = (lab.y * lab.y + lab.z * lab.z).squareRoot()
            var h = atan2f(lab.z, lab.y) * 180 / .pi
            if h < 0 { h += 360 }
            return smooth(15, 32, h) * (1 - smooth(78, 95, h)) * smooth(0.02, 0.035, c) *
                (1 - smooth(0.16, 0.2, c)) * smooth(0.3, 0.4, lab.x) * (1 - smooth(0.92, 0.97, lab.x))
        }
        if let person {
            let grown = person.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: extent.shortSide * 0.01]).cropped(to: extent)
            skin = multiply(skin, grown)
        }
        skin = soften(skin, extent: extent, amount: 0.006)

        return Masks(sky: sky, skin: skin, subject: subject.map { soften($0, extent: extent, amount: 0.003) })
    }

    // MARK: - Vision

    static func subjectMask(_ image: CIImage) -> CIImage? {
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
            guard let result = request.results?.first else { return nil }
            let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
            return fit(CIImage(cvPixelBuffer: buffer), to: image.extent)
        } catch {
            return nil
        }
    }

    static func personMask(_ image: CIImage) -> CIImage? {
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        guard (try? handler.perform([request])) != nil, let buffer = request.results?.first?.pixelBuffer else { return nil }
        let mask = fit(CIImage(cvPixelBuffer: buffer), to: image.extent)
        // Ignore empty results (no people in frame).
        let bmp = StyleAnalyzer.sample(mask, longSide: 32)
        let coverage = stride(from: 0, to: bmp.pixels.count, by: 4).reduce(0) { $0 + Int(bmp.pixels[$1]) }
        return coverage > 255 * 4 ? mask : nil
    }

    // MARK: - Helpers

    private static func fit(_ mask: CIImage, to extent: CGRect) -> CIImage {
        let sx = extent.width / mask.extent.width
        let sy = extent.height / mask.extent.height
        return mask
            .normalizedToOrigin()
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            .cropped(to: extent)
    }

    @inline(__always)
    static func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Evaluates a per-color mask function through a small color cube.
    private static func colorMask(_ image: CIImage, _ f: (SIMD3<Float>) -> Float) -> CIImage {
        let size = 24
        var values = [Float](repeating: 0, count: size * size * size * 4)
        let d = Float(size - 1)
        var i = 0
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let v = f(Oklab.fromSRGB(SIMD3(Float(r) / d, Float(g) / d, Float(b) / d)))
                    values[i] = v; values[i + 1] = v; values[i + 2] = v; values[i + 3] = 1
                    i += 4
                }
            }
        }
        let cube = CIFilter.colorCubeWithColorSpace()
        cube.inputImage = image
        cube.cubeDimension = Float(size)
        cube.cubeData = values.withUnsafeBufferPointer { Data(buffer: $0) }
        cube.colorSpace = RenderEngine.sRGB
        return (cube.outputImage ?? image).cropped(to: image.extent)
    }

    private static func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
        let f = CIFilter.multiplyCompositing()
        f.inputImage = a
        f.backgroundImage = b
        return (f.outputImage ?? a).cropped(to: a.extent)
    }

    private static func soften(_ mask: CIImage, extent: CGRect, amount: CGFloat) -> CIImage {
        mask.clampedToExtent().applyingGaussianBlur(sigma: extent.shortSide * amount).cropped(to: extent)
    }
}
