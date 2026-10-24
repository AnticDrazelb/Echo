import CoreImage
import Foundation

/// Depth-based relighting: turns a photo's depth (Portrait mode / LiDAR) into
/// surface normals and shades them with the reference's key-light direction.
/// The result is a neutral-grey-centred shading map that the renderer
/// soft-light blends over the image.
enum Relighter {
    /// Light used when a look has no measured direction (soft, upper left).
    static let defaultLight = SIMD3<Float>(-0.45, 0.8, 0.45)

    static func light(for dna: StyleDNA) -> SIMD3<Float> {
        guard let x = dna.lightX, let y = dna.lightY else { return defaultLight }
        return SIMD3(x, y, dna.lightStrength ?? 0.45)
    }

    /// Builds the shading map at `extent` from a depth or disparity image.
    static func shadingMap(depth: CIImage, extent: CGRect, light: SIMD3<Float>) -> CIImage? {
        let side = 256
        let src = depth.normalizedToOrigin()
        let ext = src.extent
        guard ext.width > 1, ext.height > 1 else { return nil }
        let scale = CGFloat(side) / max(ext.width, ext.height)
        let w = max(8, Int(ext.width * scale)), h = max(8, Int(ext.height * scale))
        let small = src.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / ext.width, y: CGFloat(h) / ext.height))

        var rgba = [Float](repeating: 0, count: w * h * 4)
        RenderEngine.shared.context.render(
            small, toBitmap: &rgba, rowBytes: w * 16,
            bounds: CGRect(x: 0, y: 0, width: w, height: h),
            format: .RGBAf, colorSpace: nil
        )
        var d = (0..<(w * h)).map { rgba[$0 * 4] }

        // Normalize robustly (ignore outliers) so any depth unit works.
        let finite = d.filter { $0.isFinite }.sorted()
        guard finite.count > 16 else { return nil }
        let lo = finite[finite.count / 50], hi = finite[finite.count * 49 / 50]
        guard hi - lo > 1e-4 else { return nil }
        d = d.map { $0.isFinite ? min(max(($0 - lo) / (hi - lo), 0), 1) : 0 }
        d = boxBlur(d, w: w, h: h, radius: 2)
        d = boxBlur(d, w: w, h: h, radius: 2)

        var l = SIMD3<Float>(light.x, light.y, 0.6)
        l /= max((l * l).sum().squareRoot(), 1e-5)
        let strength = min(1, max(0.3, light.z))
        // Per-pixel gradients → slope in image-width units, softened.
        let k: Float = 0.35 * Float(max(w, h))
        var map = [UInt8](repeating: 128, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let xm = max(x - 1, 0), xp = min(x + 1, w - 1)
                let ym = max(y - 1, 0), yp = min(y + 1, h - 1)
                // Rows run top-down; flip so +y is up like the light vector.
                let gx = (d[y * w + xp] - d[y * w + xm]) / Float(xp - xm)
                let gy = (d[ym * w + x] - d[yp * w + x]) / Float(yp - ym)
                // Disparity grows toward the camera, so the surface faces -gradient.
                var n = SIMD3<Float>(-gx * k, -gy * k, 1)
                n /= (n * n).sum().squareRoot()
                let relative = (n * l).sum() - l.z
                let v = 0.5 + 0.5 * min(1, max(-1, relative * strength * 1.6))
                let byte = UInt8(min(255, max(0, v * 255)))
                let i = (y * w + x) * 4
                map[i] = byte; map[i + 1] = byte; map[i + 2] = byte; map[i + 3] = 255
            }
        }
        // Via CGImage, whose first row is unambiguously the top.
        guard let provider = CGDataProvider(data: Data(map) as CFData),
              let cg = CGImage(
                  width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              )
        else { return nil }
        return CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(w), y: extent.height / CGFloat(h)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(extent.shortSide) * 0.004)
            .cropped(to: extent)
    }

    private static func boxBlur(_ v: [Float], w: Int, h: Int, radius r: Int) -> [Float] {
        var tmp = v, out = v
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0, n: Float = 0
                for dx in -r...r { let xx = x + dx; if xx >= 0, xx < w { s += v[y * w + xx]; n += 1 } }
                tmp[y * w + x] = s / n
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0, n: Float = 0
                for dy in -r...r { let yy = y + dy; if yy >= 0, yy < h { s += tmp[yy * w + x]; n += 1 } }
                out[y * w + x] = s / n
            }
        }
        return out
    }
}
