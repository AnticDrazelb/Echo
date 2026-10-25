import CoreImage
import XCTest
@testable import Echo

/// End-to-end checks of the render pipeline: intensity extremes, preview vs
/// export parity, LUT files, missing depth, and region-mask behaviour.
final class PipelineTests: XCTestCase {
    private let blade = BuiltInStyles.all.first { $0.name == "Blade Orange" }!

    /// A photo-like test card: smooth gradients plus mid-frequency detail.
    private func testCard(side: CGFloat) -> CIImage {
        let rect = CGRect(x: 0, y: 0, width: side, height: side * 0.75)
        let sky = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: rect.height), "inputColor0": CIColor(red: 0.35, green: 0.55, blue: 0.85),
            "inputPoint1": CIVector(x: 0, y: 0), "inputColor1": CIColor(red: 0.85, green: 0.7, blue: 0.5),
        ])!.outputImage!
        let checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputWidth": side / 40, "inputColor0": CIColor(red: 0.2, green: 0.25, blue: 0.15),
            "inputColor1": CIColor(red: 0.45, green: 0.5, blue: 0.3), "inputSharpness": 0.6,
        ])!.outputImage!
        let ground = checker.cropped(to: CGRect(x: 0, y: 0, width: side, height: rect.height * 0.35))
        return ground.composited(over: sky).cropped(to: rect)
    }

    private func pixels(_ image: CIImage, side: Int = 64) -> [SIMD3<Float>] {
        let bmp = StyleAnalyzer.sample(image, longSide: side)
        return (0..<(bmp.width * bmp.height)).map { bmp.rgb($0 % bmp.width, $0 / bmp.width) }
    }

    private func diff(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d: SIMD3<Float> = a - b
        return (abs(d.x) + abs(d.y) + abs(d.z)) / 3
    }

    private func meanAbsDiff(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Float {
        var total: Float = 0
        for (x, y) in zip(a, b) { total += diff(x, y) }
        return total / Float(max(a.count, 1))
    }

    // MARK: Intensity

    func testIntensityZeroIsTheOriginal() {
        let image = testCard(side: 256)
        let out = StyleRenderer(reference: blade.dna, source: .neutral).apply(image, settings: RenderSettings(intensity: 0))
        XCTAssertLessThan(meanAbsDiff(pixels(image), pixels(out)), 0.002)
    }

    func testIntensityIsMonotonic() {
        let image = testCard(side: 256)
        let renderer = StyleRenderer(reference: blade.dna, source: StyleAnalyzer.analyze(image))
        let base = pixels(image)
        let half = meanAbsDiff(base, pixels(renderer.apply(image, settings: RenderSettings(intensity: 0.5))))
        let full = meanAbsDiff(base, pixels(renderer.apply(image, settings: RenderSettings(intensity: 1))))
        XCTAssertGreaterThan(half, 0.01)
        XCTAssertGreaterThan(full, half * 1.5)
    }

    // MARK: Preview vs export

    /// The editor previews at ≤2000px and exports at full size; every effect
    /// is scaled to image size, so both must look the same when viewed alike.
    func testPreviewMatchesFullResolutionExport() {
        let full = testCard(side: 3000)
        let preview = full.fitting(longSide: 1000)
        let stats = StyleAnalyzer.analyze(preview)
        let renderer = StyleRenderer(reference: blade.dna, source: stats)
        let settings = RenderSettings(intensity: 1)
        let a = pixels(renderer.apply(full, settings: settings), side: 96)
        let b = pixels(renderer.apply(preview, settings: settings), side: 96)
        XCTAssertLessThan(meanAbsDiff(a, b), 0.025, "preview and export differ")
    }

    // MARK: LUT files

    func testCubeFileIsWellFormed() throws {
        let style = BuiltInStyles.all.first { $0.name == "Wes Red" }!
        let url = try CubeExporter.write(style: style, size: 9)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("LUT_3D_SIZE 9"))
        let data = lines.filter { $0.first.map { $0.isNumber } ?? false }
        XCTAssertEqual(data.count, 9 * 9 * 9)
        for line in data {
            let v = line.split(separator: " ").compactMap { Float($0) }
            XCTAssertEqual(v.count, 3)
            XCTAssertTrue(v.allSatisfy { $0 >= 0 && $0 <= 1 }, line)
        }
    }

    func testNeutralCubeIsNearIdentity() throws {
        let neutral = Style(name: "Neutral", dna: .neutral)
        let url = try CubeExporter.write(style: neutral, settings: RenderSettings(intensity: 1), size: 5)
        let data = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .filter { $0.first?.isNumber ?? false }
            .map { $0.split(separator: " ").compactMap { Float($0) } }
        // Red varies fastest: entry i = (r, g, b) on a 5-step grid.
        for (i, rgb) in data.enumerated() {
            let r = Float(i % 5) / 4, g = Float(i / 5 % 5) / 4, b = Float(i / 25) / 4
            XCTAssertEqual(rgb[0], r, accuracy: 0.06)
            XCTAssertEqual(rgb[1], g, accuracy: 0.06)
            XCTAssertEqual(rgb[2], b, accuracy: 0.06)
        }
    }

    // MARK: Depth

    func testFlatDepthProducesNoShading() {
        let flat = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        XCTAssertNil(Relighter.shadingMap(depth: flat, extent: flat.extent, light: Relighter.defaultLight))
    }

    func testRelightWithoutShadingIsNoop() {
        let image = testCard(side: 256)
        let renderer = StyleRenderer(reference: blade.dna, source: .neutral)
        var on = RenderSettings(intensity: 1)
        on.relight = true
        let off = RenderSettings(intensity: 1)
        XCTAssertLessThan(meanAbsDiff(pixels(renderer.apply(image, settings: on, seed: 1)),
                                      pixels(renderer.apply(image, settings: off, seed: 1))), 0.001)
    }

    // MARK: Regions

    func testMaskConfinesTheStyle() {
        let image = testCard(side: 256)
        let ext = image.extent
        let left = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: ext.width / 2, height: ext.height))
            .composited(over: CIImage(color: .black).cropped(to: ext))
        let renderer = StyleRenderer(reference: blade.dna, source: .neutral)
        var settings = RenderSettings(intensity: 1)
        settings.grain = false
        settings.optics = false
        let out = StyleAnalyzer.sample(renderer.apply(image, settings: settings, mask: left), longSide: 64)
        let src = StyleAnalyzer.sample(image, longSide: 64)
        let y = out.height / 2
        let leftChange = diff(out.rgb(8, y), src.rgb(8, y))
        let rightChange = diff(out.rgb(out.width - 8, y), src.rgb(src.width - 8, y))
        XCTAssertGreaterThan(leftChange, 0.02)
        XCTAssertLessThan(rightChange, 0.005)
    }

    func testMaskCoverage() {
        let ext = CGRect(x: 0, y: 0, width: 64, height: 64)
        XCTAssertLessThan(RegionMasker.coverage(of: CIImage(color: .black).cropped(to: ext)), 0.01)
        XCTAssertGreaterThan(RegionMasker.coverage(of: CIImage(color: .white).cropped(to: ext)), 0.99)
    }
}
