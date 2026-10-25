import CoreImage
import XCTest
@testable import Echo

final class StudioTests: XCTestCase {
    private let canvas = CGRect(x: 0, y: 0, width: 200, height: 150)

    private func gray(_ v: CGFloat = 0.5) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v)).cropped(to: canvas)
    }

    private func render(_ comp: Composition, at t: Double = 0, base: CIImage? = nil) -> StyleAnalyzer.Bitmap {
        let image = CompositionRenderer.render(comp, base: base ?? gray(), at: t, assets: StudioAssets(), renderers: RendererCache())
        return StyleAnalyzer.sample(image, longSide: 40)
    }

    private func comp(_ layers: [Layer]) -> Composition {
        var c = Composition.new(name: "Test", kind: .photo, file: "base.jpg", aspect: 4.0 / 3, duration: 2)
        c.layers += layers
        return c
    }

    // MARK: Keyframes

    func testKeyframeInterpolation() {
        var v = AnimatableValue(0)
        v.keyframes = [Keyframe(time: 0, value: 0, easing: .linear), Keyframe(time: 2, value: 10)]
        XCTAssertEqual(v.at(-1), 0, accuracy: 1e-9)
        XCTAssertEqual(v.at(1), 5, accuracy: 1e-9)
        XCTAssertEqual(v.at(3), 10, accuracy: 1e-9)
        v.keyframes[0].easing = .hold
        XCTAssertEqual(v.at(1.9), 0, accuracy: 1e-9)
        v.keyframes[0].easing = .easeInOut
        XCTAssertEqual(v.at(1), 5, accuracy: 1e-6)
        XCTAssertLessThan(v.at(0.5), 2.5)
    }

    func testStopwatchEditing() {
        var v = AnimatableValue(3)
        v.set(4, at: 1)
        XCTAssertEqual(v.value, 4)
        XCTAssertFalse(v.isAnimated)
        v.toggleAnimation(at: 0)
        v.set(8, at: 1)
        XCTAssertEqual(v.keyframes.count, 2)
        XCTAssertEqual(v.at(0), 4, accuracy: 1e-9)
        XCTAssertEqual(v.at(1), 8, accuracy: 1e-9)
        v.toggleKeyframe(at: 1)
        XCTAssertEqual(v.keyframes.count, 1)
    }

    // MARK: Compositing

    func testAdjustmentLayerAffectsLayersBelow() {
        var adjust = Layer(name: "Exposure", content: .adjustment)
        var effect = Effect(.exposure)
        effect.params["ev"] = AnimatableValue(1)
        adjust.effects = [effect]
        let before = render(comp([])).rgb(20, 15).x
        let after = render(comp([adjust])).rgb(20, 15).x
        XCTAssertGreaterThan(after, before + 0.1)
    }

    func testMultiplyBlendDarkens() {
        var solid = Layer(name: "Solid", content: .solid(AnimatableColor(0.5, 0.5, 0.5)))
        solid.blend = .multiply
        let out = render(comp([solid])).rgb(20, 15).x
        XCTAssertLessThan(out, 0.4)
    }

    func testEllipseMaskConfinesLayer() {
        var solid = Layer(name: "Red", content: .solid(AnimatableColor(1, 0, 0)))
        solid.mask.kind = .ellipse
        solid.mask.width = AnimatableValue(0.3)
        solid.mask.height = AnimatableValue(0.3)
        solid.mask.feather = AnimatableValue(0)
        let bmp = render(comp([solid]))
        XCTAssertGreaterThan(bmp.rgb(20, 15).x, 0.9)   // centre: red
        XCTAssertLessThan(bmp.rgb(1, 1).x, 0.6)        // corner: untouched grey
        solid.mask.inverted = true
        let inverted = render(comp([solid]))
        XCTAssertLessThan(inverted.rgb(20, 15).x, 0.6)
        XCTAssertGreaterThan(inverted.rgb(1, 1).x, 0.9)
    }

    func testAnimatedOpacity() {
        var solid = Layer(name: "White", content: .solid(AnimatableColor(1, 1, 1)))
        solid.opacity.keyframes = [Keyframe(time: 0, value: 0, easing: .linear), Keyframe(time: 2, value: 1)]
        let c = comp([solid])
        let start = render(c, at: 0).rgb(20, 15).x
        let end = render(c, at: 2).rgb(20, 15).x
        XCTAssertEqual(start, 0.5, accuracy: 0.05)
        XCTAssertGreaterThan(end, 0.95)
    }

    func testTextLayerDrawsSomething() {
        var text = TextContent()
        text.text = "ECHO"
        text.size = AnimatableValue(0.3)
        text.color = AnimatableColor(1, 0, 0)
        let layer = Layer(name: "Text", content: .text(text))
        let bmp = render(comp([layer]), base: gray(0))
        var redPixels = 0
        for y in 0..<bmp.height { for x in 0..<bmp.width where bmp.rgb(x, y).x > 0.5 { redPixels += 1 } }
        XCTAssertGreaterThan(redPixels, 5)
    }

    func testEveryEffectRenders() {
        for type in EffectType.allCases {
            var layer = Layer(name: type.title, content: .adjustment)
            var effect = Effect(type)
            if type == .look { effect.dna = BuiltInStyles.all[0].dna }
            layer.effects = [effect]
            let image = CompositionRenderer.render(comp([layer]), base: gray(), at: 0.5, assets: StudioAssets(), renderers: RendererCache())
            XCTAssertEqual(image.extent, canvas, "\(type) changed the canvas")
            XCTAssertNotNil(RenderEngine.shared.cgImage(image), "\(type) failed to render")
        }
    }

    // MARK: Persistence

    func testCompositionRoundTrip() throws {
        var text = Layer(name: "T", content: .text(TextContent()))
        text.transform.scale.keyframes = [Keyframe(time: 0, value: 1), Keyframe(time: 1, value: 2)]
        var adjust = Layer(name: "A", content: .adjustment)
        adjust.effects = [Effect(.glitch), Effect(.duotone)]
        adjust.mask.kind = .linear
        let original = comp([text, adjust, Layer(name: "G", content: .gradient(GradientContent())), Layer(name: "S", content: .shape(ShapeContent()))])
        let decoded = try JSONDecoder().decode(Composition.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }
}
