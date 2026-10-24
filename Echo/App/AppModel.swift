import Observation
import SwiftUI
import UIKit

/// A freshly extracted look waiting to be named and saved.
struct PendingStyle: Identifiable {
    let id = UUID()
    var dna: StyleDNA
    var reference: UIImage?
    var suggestedName: String
    var origin: Origin

    enum Origin { case camera, photos, blend }
}

/// App-wide navigation and cross-screen actions.
@Observable
@MainActor
final class AppModel {
    let library = StyleLibrary()

    enum Cover: Identifiable {
        case editor(EditorModel)
        case camera(initialStyle: UUID?)

        var id: String {
            switch self {
            case .editor(let model): "editor-\(ObjectIdentifier(model).hashValue)"
            case .camera: "camera"
            }
        }
    }

    enum Sheet: Identifiable {
        case naming(PendingStyle)
        case importing(SharedStyle)
        case blend
        case details(Style)

        var id: String {
            switch self {
            case .naming(let p): "naming-\(p.id)"
            case .importing(let s): "import-\(s.name)"
            case .blend: "blend"
            case .details(let s): "details-\(s.id)"
            }
        }
    }

    var cover: Cover?
    var sheet: Sheet?
    var toast: String?
    var errorMessage: String?

    // MARK: Flows

    func openEditor(style: Style, media: Media) {
        cover = .editor(EditorModel(style: style, media: media, library: library))
    }

    func openCamera(with style: Style? = nil) {
        cover = .camera(initialStyle: style?.id)
    }

    func save(_ pending: PendingStyle, name: String, creator: String?) -> Style {
        var style = Style(name: library.uniqueName(name), dna: pending.dna)
        let handle = creator?.trimmingCharacters(in: .whitespacesAndNewlines)
        style.creator = (handle?.isEmpty ?? true) ? nil : handle
        library.add(style, reference: pending.reference)
        toast = "“\(style.name)” added to your styles"
        return style
    }

    // MARK: Links & AirDrop

    func handle(url: URL) {
        do {
            let shared = try SharedStyle.from(url: url)
            cover = nil
            sheet = .importing(shared)
        } catch {
            errorMessage = "That Echo link looks damaged or came from a newer version of Echo."
        }
    }

    func importStyle(_ shared: SharedStyle) {
        var style = shared.makeStyle()
        style.name = library.uniqueName(style.name)
        library.add(style)
        toast = "“\(style.name)” installed"
    }
}
