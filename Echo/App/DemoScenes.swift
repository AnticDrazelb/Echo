import CoreImage
import SwiftUI

/// `-EchoDemo <scene>` (a launch argument, so never reachable by users) opens
/// a screen with demo content so CI can capture simulator screenshots.
enum DemoScenes {
    static var requested: String? { UserDefaults.standard.string(forKey: "EchoDemo") }

    @MainActor
    static func run(_ app: AppModel) async {
        guard let scene = requested else { return }
        NSLog("EchoDemo: scene \(scene)")
        let library = app.library
        let styles = library.styles
        guard let first = styles.first else { print("EchoDemo: no styles"); return }
        func style(_ name: String) -> Style { styles.first { $0.name == name } ?? first }
        let sample = Bundle.main.url(forResource: "SampleScene", withExtension: "jpg").flatMap { CIImage(contentsOf: $0) }
        // Let the home grid render its card previews first.
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        NSLog("EchoDemo: presenting \(scene)")
        switch scene {
        case "editor", "editor-blend", "export":
            guard let sample else { return }
            app.openEditor(style: style("Blade Orange"), media: .photo(sample, depth: nil))
            guard case .editor(let model) = app.cover else { return }
            if scene == "editor-blend" {
                model.addBlend(style("Wes Red"))
                model.split = 0.35
            }
            if scene == "export" {
                for _ in 0..<40 where !model.isReady { try? await Task.sleep(nanoseconds: 250_000_000) }
                try? await Task.sleep(nanoseconds: 800_000_000)
                model.demoShowExport = true
            }
        case "newstyle":
            guard let url = Bundle.main.url(forResource: "museum-great-wave", withExtension: "jpg"),
                  let image = CIImage(contentsOf: url) else { return }
            do {
                let pending = try await StyleExtraction.pending(from: .photo(image, depth: nil), origin: .photos)
                NSLog("EchoDemo: extracted \(pending.suggestedName)")
                app.sheet = .naming(pending)
            } catch {
                NSLog("EchoDemo: extraction failed \(error)")
            }
        case "studio", "studio-inspector":
            guard let url = Bundle.main.url(forResource: "SampleScene", withExtension: "jpg"),
                  let data = try? Data(contentsOf: url),
                  var comp = try? app.studio.createPhotoProject(data: data, fileExtension: "jpg", name: "Golden Hour Reel")
            else { return }
            var look = Effect(.look)
            look.dna = style("Golden Hour").dna
            look.styleName = "Golden Hour"
            var grade = Layer(name: "Golden Hour", content: .adjustment)
            grade.effects = [look]
            var gradient = Layer(name: "Sky Gradient", content: .gradient(GradientContent()))
            gradient.blend = .softLight
            gradient.opacity = AnimatableValue(0.45)
            gradient.mask.kind = .linear
            gradient.mask.y = AnimatableValue(0.35)
            gradient.mask.angle = AnimatableValue(270)
            gradient.mask.feather = AnimatableValue(0.5)
            var text = TextContent()
            text.text = "GOLDEN HOUR"
            text.size = AnimatableValue(0.11)
            text.tracking = AnimatableValue(0.18)
            text.weight = 0.3
            var title = Layer(name: "Title", content: .text(text))
            title.transform.y = AnimatableValue(0.2)
            var fx = Layer(name: "Glow & Leak", content: .adjustment)
            fx.effects = [Effect(.glow), Effect(.lightLeak), Effect(.grain)]
            comp.layers += [grade, gradient, title, fx]
            app.studio.save(comp)
            app.openStudio(comp)
            guard case .studio(let model) = app.cover else { return }
            if let base = model.comp.layers.first { model.apply(.kenBurns, to: base.id) }
            model.apply(.popIn, to: title.id)
            model.time = 1.6
            model.selectedLayerID = scene == "studio" ? fx.id : title.id
            if scene == "studio-inspector" {
                model.demoInspector = true
                model.selectedLayerID = fx.id
                model.selectedEffectID = fx.effects.first?.id
            }
        case "blend":
            app.sheet = .blend
        case "dna":
            app.sheet = .details(style("Golden Hour"))
        default:
            break
        }
    }
}
