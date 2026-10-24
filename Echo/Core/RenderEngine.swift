import CoreImage
import ImageIO
import Metal
import UIKit

/// Shared GPU resources. One Core Image context for the whole app keeps
/// Metal caches warm and memory predictable.
final class RenderEngine {
    static let shared = RenderEngine()
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    let device: MTLDevice?
    let commandQueue: MTLCommandQueue?
    let context: CIContext

    private init() {
        device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        let options: [CIContextOption: Any] = [
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
            .name: "Echo",
        ]
        if let queue = commandQueue {
            context = CIContext(mtlCommandQueue: queue, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    func cgImage(_ image: CIImage, colorSpace: CGColorSpace = RenderEngine.sRGB) -> CGImage? {
        context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: colorSpace)
    }

    func uiImage(_ image: CIImage) -> UIImage? {
        cgImage(image).map { UIImage(cgImage: $0) }
    }

    /// High quality HEIF (falls back to JPEG) for saving to Photos.
    func photoData(_ image: CIImage) -> (Data, String)? {
        let cs = RenderEngine.displayP3
        let opts: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92,
        ]
        if let heif = context.heifRepresentation(of: image, format: .RGBA8, colorSpace: cs, options: opts) {
            return (heif, "heic")
        }
        if let jpeg = context.jpegRepresentation(of: image, colorSpace: cs, options: opts) {
            return (jpeg, "jpg")
        }
        return nil
    }
}

extension CIImage {
    /// Moves the image so its extent starts at the origin.
    func normalizedToOrigin() -> CIImage {
        transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }

    /// Downscales (never upscales) so the long side is at most `side` pixels.
    func fitting(longSide side: CGFloat) -> CIImage {
        let longest = max(extent.width, extent.height)
        guard longest > side, longest > 0 else { return self }
        let s = side / longest
        return applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
            .normalizedToOrigin()
    }

    var shortSide: CGFloat { min(extent.width, extent.height) }
}
