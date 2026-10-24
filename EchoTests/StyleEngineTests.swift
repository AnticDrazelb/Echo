import CoreImage
import XCTest
@testable import Echo

final class StyleEngineTests: XCTestCase {
    func testOklabRoundTrip() {
        for r in stride(from: Float(0), through: 1, by: 0.25) {
            for g in stride(from: Float(0), through: 1, by: 0.25) {
                for b in stride(from: Float(0), through: 1, by: 0.25) {
                    let rgb = SIMD3(r, g, b)
                    let back = Oklab.toSRGBClamped(Oklab.fromSRGB(rgb))
                    XCTAssertEqual(back.x, r, accuracy: 0.002)
                    XCTAssertEqual(back.y, g, accuracy: 0.002)
                    XCTAssertEqual(back.z, b, accuracy: 0.002)
                }
            }
        }
    }

    func testSameStatsIsNearIdentity() {
        let dna = StyleDNA.neutral
        let transfer = StyleTransfer(reference: dna, source: dna)
        for v in stride(from: Float(0.1), through: 0.9, by: 0.2) {
            let out = transfer.map(srgb: SIMD3(v, v * 0.9, v * 0.8))
            XCTAssertEqual(out.x, v, accuracy: 0.03)
            XCTAssertEqual(out.y, v * 0.9, accuracy: 0.03)
            XCTAssertEqual(out.z, v * 0.8, accuracy: 0.03)
        }
    }

    func testToneCurveIsMonotonic() {
        for style in BuiltInStyles.all {
            let curve = StyleTransfer.buildCurve(from: StyleDNA.neutral.luminance, to: style.dna.luminance)
            for i in 1..<curve.count {
                XCTAssertGreaterThanOrEqual(curve[i], curve[i - 1] - 1e-5, "\(style.name) not monotonic at \(i)")
            }
        }
    }

    func testMonochromeStyleRemovesColor() {
        let dust = BuiltInStyles.all.first { $0.name == "Dust Film" }!
        let transfer = StyleTransfer(reference: dust.dna, source: .neutral)
        let out = transfer.map(srgb: SIMD3(0.9, 0.2, 0.1))
        XCTAssertEqual(out.x, out.y, accuracy: 0.01)
        XCTAssertEqual(out.y, out.z, accuracy: 0.01)
    }

    func testAnalyzerOnSolidColor() {
        let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let dna = StyleAnalyzer.analyze(image, options: .init(ignoreText: false))
        XCTAssertTrue(dna.isValid)
        XCTAssertLessThan(dna.contrast, 0.02)
        XCTAssertLessThan(dna.grain, 0.1)
        // Blue cast shows up as negative Oklab b.
        XCTAssertLessThan(dna.zoneTintB[1], 0)
    }

    func testShareLinkRoundTrip() throws {
        let style = BuiltInStyles.all[0]
        var withCreator = style
        withCreator.creator = "@echo"
        let link = try SharedStyle(withCreator).link()
        XCTAssertEqual(link.scheme, "echo")
        XCTAssertLessThan(link.absoluteString.count, 2048)
        let decoded = try SharedStyle.from(url: link)
        XCTAssertEqual(decoded.name, style.name)
        XCTAssertEqual(decoded.creator, "@echo")
        XCTAssertEqual(decoded.dna, style.dna)
    }

    func testBlendIsWeightedAverage() {
        let a = BuiltInStyles.all[0].dna, b = BuiltInStyles.all[2].dna
        let mix = StyleDNA.blend([(a, 1), (b, 1)])
        XCTAssertEqual(mix.grain, (a.grain + b.grain) / 2, accuracy: 1e-5)
        XCTAssertEqual(mix.luminance[8], (a.luminance[8] + b.luminance[8]) / 2, accuracy: 1e-5)
    }

    func testCubeHasExpectedSize() {
        let transfer = StyleTransfer(reference: BuiltInStyles.all[1].dna, source: .neutral)
        XCTAssertEqual(transfer.cubeData(size: 8).count, 8 * 8 * 8 * 4 * MemoryLayout<Float>.size)
    }

    func testRendererProducesImage() {
        let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let renderer = StyleRenderer(reference: BuiltInStyles.all[0].dna, source: .neutral)
        let out = renderer.apply(image, settings: RenderSettings(intensity: 1))
        XCTAssertEqual(out.extent, image.extent)
        XCTAssertNotNil(RenderEngine.shared.cgImage(out))
    }
}
