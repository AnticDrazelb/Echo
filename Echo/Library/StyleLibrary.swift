import CoreImage
import Observation
import SwiftUI
import UIKit

/// The user's styles, persisted as JSON with reference thumbnails on disk.
@Observable
@MainActor
final class StyleLibrary {
    private(set) var styles: [Style] = []
    /// Rendered card previews keyed by style id.
    private(set) var previews: [UUID: UIImage] = [:]
    @ObservationIgnored private var references: [UUID: UIImage] = [:]
    @ObservationIgnored private var pendingPreviews: Set<UUID> = []

    private let folder: URL
    private var indexURL: URL { folder.appendingPathComponent("styles.json") }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("Styles", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
    }

    // MARK: Mutations

    func add(_ style: Style, reference: UIImage? = nil) {
        styles.insert(style, at: 0)
        if let reference { saveReference(reference, for: style.id) }
        save()
    }

    func remove(_ style: Style) {
        styles.removeAll { $0.id == style.id }
        previews[style.id] = nil
        references[style.id] = nil
        try? FileManager.default.removeItem(at: referenceURL(style.id))
        save()
    }

    func rename(_ style: Style, to name: String) {
        guard let i = styles.firstIndex(where: { $0.id == style.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        styles[i].name = trimmed
        save()
    }

    func duplicate(_ style: Style) {
        var copy = style
        copy.id = UUID()
        copy.name = "\(style.name) Copy"
        copy.isBuiltIn = false
        copy.createdAt = Date()
        if let ref = reference(for: style) { saveReference(ref, for: copy.id) }
        if let i = styles.firstIndex(where: { $0.id == style.id }) {
            styles.insert(copy, at: i + 1)
        } else {
            styles.insert(copy, at: 0)
        }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        styles.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func style(id: UUID) -> Style? {
        styles.first { $0.id == id }
    }

    func uniqueName(_ base: String) -> String {
        let names = Set(styles.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Images

    func reference(for style: Style) -> UIImage? {
        if let cached = references[style.id] { return cached }
        guard let image = UIImage(contentsOfFile: referenceURL(style.id).path) else { return nil }
        references[style.id] = image
        return image
    }

    /// Card preview: the bundled sample scene rendered with the style.
    func preview(for style: Style) -> UIImage? {
        if let image = previews[style.id] { return image }
        guard !pendingPreviews.contains(style.id) else { return nil }
        pendingPreviews.insert(style.id)
        let dna = style.dna
        let id = style.id
        Task.detached(priority: .userInitiated) {
            let image = SampleScene.shared.render(dna)
            await MainActor.run {
                self.pendingPreviews.remove(id)
                if let image {
                    withAnimation(.easeOut(duration: 0.35)) { self.previews[id] = image }
                }
            }
        }
        return nil
    }

    private func saveReference(_ image: UIImage, for id: UUID) {
        let thumb = image.preparingThumbnail(of: CGSize(width: 360, height: 360 * image.size.height / max(image.size.width, 1))) ?? image
        references[id] = thumb
        if let data = thumb.jpegData(compressionQuality: 0.85) {
            try? data.write(to: referenceURL(id), options: .atomic)
        }
    }

    private func referenceURL(_ id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString).jpg")
    }

    // MARK: Persistence

    private func load() {
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([Style].self, from: data) {
            styles = saved.filter { $0.dna.isValid }
        } else {
            styles = BuiltInStyles.all
            save()
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(styles)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("Echo: failed to save library: \(error)")
        }
    }
}

/// Bundled scene used for style card previews.
final class SampleScene: @unchecked Sendable {
    static let shared = SampleScene()

    let image: CIImage
    let stats: StyleDNA

    private init() {
        if let url = Bundle.main.url(forResource: "SampleScene", withExtension: "jpg"),
           let ci = CIImage(contentsOf: url) {
            image = ci.fitting(longSide: 640).normalizedToOrigin()
        } else {
            image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 480, height: 640))
        }
        stats = StyleAnalyzer.analyze(image, options: .init(ignoreText: false))
    }

    func render(_ dna: StyleDNA, settings: RenderSettings = RenderSettings(intensity: 1)) -> UIImage? {
        let renderer = StyleRenderer(reference: dna, source: stats)
        return RenderEngine.shared.uiImage(renderer.apply(image, settings: settings))
    }
}
