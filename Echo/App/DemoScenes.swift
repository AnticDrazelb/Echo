#if DEBUG
import CoreImage
import SwiftUI

/// Debug-only: `-EchoDemo <scene>` opens a screen with demo content so CI can
/// capture simulator screenshots without UI automation.
enum DemoScenes {
    static var requested: String? { UserDefaults.standard.string(forKey: "EchoDemo") }

    @MainActor
    static func run(_ app: AppModel) async {
        guard let scene = requested else { return }
        let library = app.library
        let styles = library.styles
        guard let first = styles.first else { return }
        func style(_ name: String) -> Style { styles.first { $0.name == name } ?? first }
        let sample = Bundle.main.url(forResource: "SampleScene", withExtension: "jpg").flatMap { CIImage(contentsOf: $0) }
        // Let the home grid render its card previews first.
        try? await Task.sleep(nanoseconds: 1_200_000_000)

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
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                model.demoShowExport = true
            }
        case "newstyle":
            guard let url = Bundle.main.url(forResource: "museum-great-wave", withExtension: "jpg"),
                  let image = CIImage(contentsOf: url) else { return }
            let pending = try? await StyleExtraction.pending(from: .photo(image, depth: nil), origin: .photos)
            if let pending { app.sheet = .naming(pending) }
        case "blend":
            app.sheet = .blend
        case "dna":
            app.sheet = .details(style("Golden Hour"))
        default:
            break
        }
    }
}
#endif
