import CoreImage
import XCTest
@testable import Echo

/// Image-quality benchmark on real photographs, run by the `Benchmark`
/// workflow (skipped otherwise). For every photo in `$ECHO_BENCH_DIR/input`
/// it renders each built-in look through the real engine, writes a contact
/// sheet to `out/`, and records metrics in `out/metrics.csv`:
///
/// - clip: extra share of pixels clipped to black/white vs. the original
/// - shadows: detail kept in the darkest 15% (std ratio; < 0.5 = crushed)
/// - skin_hue / skin_chroma: hue drift (°) and saturation ratio on skin
/// - levels: distinct tone levels kept (monochrome separation)
final class QualityBenchmarkTests: XCTestCase {
    func testBenchmarkRealPhotos() throws {
        guard let root = ProcessInfo.processInfo.environment["ECHO_BENCH_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_ECHO_BENCH_DIR to run the image-quality benchmark.")
        }
        let input = URL(fileURLWithPath: root).appendingPathComponent("input")
        let out = URL(fileURLWithPath: root).appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let photos = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
            .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(photos.isEmpty, "no benchmark photos in \(input.path)")

        var csv = "photo,style,clip,shadows,skin_hue,skin_chroma,levels,ms\n"
        for url in photos {
            guard let loaded = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { continue }
            let photo = loaded.normalizedToOrigin().fitting(longSide: 1400).normalizedToOrigin()
            let name = url.deletingPathExtension().lastPathComponent
            let stats = StyleAnalyzer.analyze(photo, options: .init(ignoreText: false))
            let skin = RegionMasker.masks(for: photo).skin
            let skinCoverage = skin.map { RegionMasker.coverage(of: $0) } ?? 0

            var tiles: [(String, CIImage)] = [("Original", photo)]
            for style in BuiltInStyles.all {
                let start = Date()
                let renderer = StyleRenderer(reference: style.dna, source: stats)
                let result = renderer.apply(photo, settings: RenderSettings(intensity: 1))
                // Force the render so the timing is real.
                let baked = RenderEngine.shared.cgImage(result).map { CIImage(cgImage: $0) } ?? result
                let ms = Date().timeIntervalSince(start) * 1000
                tiles.append((style.name, baked))

                let m = Metrics(original: photo, styled: baked, skin: skinCoverage > 0.02 ? skin : nil)
                let hue = m.skinHue.map { f($0) } ?? ""
                let chroma = m.skinChroma.map { f($0) } ?? ""
                let row: [String] = [name, style.name, f(m.clip), f(m.shadows), hue, chroma, f(m.levels), String(Int(ms))]
                csv += row.joined(separator: ",") + "\n"
            }
            try writeSheet(tiles, to: out.appendingPathComponent("\(name).jpg"))
        }
        try csv.write(to: out.appendingPathComponent("metrics.csv"), atomically: true, encoding: .utf8)
        print(csv)
    }

    private func f(_ v: Float) -> String { String(format: "%.3f", v) }

    private func writeSheet(_ tiles: [(String, CIImage)], to url: URL) throws {
        let height: CGFloat = 520
        var x: CGFloat = 0
        var sheet = CIImage.empty()
        for (label, image) in tiles {
            let s = height / image.extent.height
            var tile = image.transformed(by: CGAffineTransform(scaleX: s, y: s)).normalizedToOrigin()
            tile = Watermark.apply(label, to: tile)
            sheet = tile.transformed(by: CGAffineTransform(translationX: x, y: 0)).composited(over: sheet)
            x += tile.extent.width + 8
        }
        let canvas = CGRect(x: 0, y: 0, width: x - 8, height: height)
        let final = sheet.composited(over: CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1)).cropped(to: canvas))
        let data = RenderEngine.shared.context.jpegRepresentation(of: final, colorSpace: RenderEngine.sRGB, options: [:])
        try XCTUnwrap(data).write(to: url)
    }
}

private struct Metrics {
    var clip: Float = 0
    var shadows: Float = 1
    var skinHue: Float?
    var skinChroma: Float?
    var levels: Float = 1

    init(original: CIImage, styled: CIImage, skin: CIImage?) {
        let a = StyleAnalyzer.sample(original, longSide: 256)
        let b = StyleAnalyzer.sample(styled, longSide: 256)
        let n = a.width * a.height
        let labA = (0..<n).map { Oklab.fromSRGB(a.rgb($0 % a.width, $0 / a.width)) }
        let labB = (0..<n).map { Oklab.fromSRGB(b.rgb($0 % b.width, $0 / b.width)) }

        func clipped(_ bmp: StyleAnalyzer.Bitmap) -> Float {
            var count = 0
            for i in 0..<n {
                let c = bmp.rgb(i % bmp.width, i / bmp.width)
                if c.max() >= 0.996 || c.max() <= 0.004 { count += 1 }
            }
            return Float(count) / Float(n)
        }
        clip = clipped(b) - clipped(a)

        // Detail in the original's darkest 15%: does the look keep it?
        let threshold = labA.map(\.x).sorted()[n * 15 / 100]
        let dark = (0..<n).filter { labA[$0].x <= threshold }
        func std(_ v: [Float]) -> Float {
            let count = Float(max(v.count, 1))
            let mean: Float = v.reduce(0, +) / count
            var sq: Float = 0
            for x in v { sq += (x - mean) * (x - mean) }
            return (sq / count).squareRoot()
        }
        let sa = std(dark.map { labA[$0].x }), sb = std(dark.map { labB[$0].x })
        shadows = sa > 0.002 ? sb / sa : 1

        // Tone levels in use (out of 64) relative to the original.
        func usedLevels(_ v: [SIMD3<Float>]) -> Int { Set(v.map { Int(min(max($0.x, 0), 0.999) * 64) }).count }
        levels = Float(usedLevels(labB)) / Float(max(usedLevels(labA), 1))

        if let skin {
            let m = StyleAnalyzer.sample(skin, longSide: 256)
            var w: Float = 0, hueDiff: Float = 0, chromaA: Float = 0, chromaB: Float = 0
            for i in 0..<n {
                let weight = Float(m.pixels[i * 4]) / 255
                guard weight > 0.5 else { continue }
                let ha = atan2f(labA[i].z, labA[i].y), hb = atan2f(labB[i].z, labB[i].y)
                var d = (hb - ha) * 180 / .pi
                if d > 180 { d -= 360 }
                if d < -180 { d += 360 }
                let ca: Float = hypotf(labA[i].y, labA[i].z)
                let cb: Float = hypotf(labB[i].y, labB[i].z)
                hueDiff += d * weight
                chromaA += ca * weight
                chromaB += cb * weight
                w += weight
            }
            if w > 20 {
                skinHue = hueDiff / w
                skinChroma = chromaA > 0 ? chromaB / chromaA : nil
            }
        }
    }
}
