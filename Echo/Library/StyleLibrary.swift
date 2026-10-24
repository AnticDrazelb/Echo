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
    @ObservationIgnored private var previewVersions: [UUID: Int] = [:]
    @ObservationIgnored private var widgetSyncTask: Task<Void, Never>?
    /// Bumped when the preview subject changes; observed so cards refresh.
    private(set) var previewGeneration = 0

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
        previewVersions[style.id] = nil
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

    /// Card preview: the preview subject (your last photo) in this style.
    /// Stale previews stay on screen until their re-render lands.
    func preview(for style: Style) -> UIImage? {
        let cached = previews[style.id]
        if previewVersions[style.id] == previewGeneration { return cached }
        guard !pendingPreviews.contains(style.id) else { return cached }
        pendingPreviews.insert(style.id)
        let dna = style.dna
        let id = style.id
        let generation = previewGeneration
        Task.detached(priority: .userInitiated) {
            let image = SampleScene.shared.render(dna)
            await MainActor.run {
                self.pendingPreviews.remove(id)
                guard let image else { return }
                self.previewVersions[id] = generation
                withAnimation(.easeOut(duration: 0.35)) { self.previews[id] = image }
                self.scheduleWidgetSync()
            }
        }
        return cached
    }

    /// Re-previews every card on one of the user's own photos.
    func usePreviewSubject(_ photo: CIImage) {
        Task.detached(priority: .utility) {
            guard SampleScene.shared.update(with: photo) else { return }
            await MainActor.run { self.previewGeneration += 1 }
        }
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

    /// Coalesced publish of cards to the StandBy widget.
    private func scheduleWidgetSync() {
        widgetSyncTask?.cancel()
        widgetSyncTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            WidgetSync.publish(styles: styles, previews: previews)
        }
    }

    private func save() {
        scheduleWidgetSync()
        do {
            let data = try JSONEncoder().encode(styles)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("Echo: failed to save library: \(error)")
        }
    }
}

/// The photo style cards are previewed on: the last photo you styled or shot,
/// kept privately on device, or the bundled sample scene until then.
final class SampleScene: @unchecked Sendable {
    static let shared = SampleScene()

    private let lock = NSLock()
    private var image: CIImage
    private var stats: StyleDNA
    private(set) var isPersonal = false

    private static var subjectURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Styles", isDirectory: true)
            .appendingPathComponent("preview-subject.jpg")
    }

    private init() {
        var loaded: CIImage?
        if let ci = CIImage(contentsOf: Self.subjectURL) {
            loaded = ci
            isPersonal = true
        } else if let url = Bundle.main.url(forResource: "SampleScene", withExtension: "jpg") {
            loaded = CIImage(contentsOf: url)
        }
        let base = (loaded ?? CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 480, height: 640)))
        image = Self.cardCrop(base)
        stats = StyleAnalyzer.analyze(image, options: .init(ignoreText: false))
    }

    /// Center-crops to the card's portrait aspect and downsizes.
    private static func cardCrop(_ source: CIImage) -> CIImage {
        let img = source.normalizedToOrigin()
        let ext = img.extent
        let aspect: CGFloat = 0.78
        var rect = ext
        if ext.width / ext.height > aspect {
            rect.size.width = ext.height * aspect
            rect.origin.x = (ext.width - rect.width) / 2
        } else {
            rect.size.height = ext.width / aspect
            rect.origin.y = (ext.height - rect.height) / 2
        }
        return img.cropped(to: rect).normalizedToOrigin().fitting(longSide: 640)
    }

    /// Makes `photo` the preview subject. Returns false if rendering failed.
    @discardableResult
    func update(with photo: CIImage) -> Bool {
        let cropped = Self.cardCrop(photo)
        guard let cg = RenderEngine.shared.cgImage(cropped) else { return false }
        let baked = CIImage(cgImage: cg)
        let newStats = StyleAnalyzer.analyze(baked, options: .init(ignoreText: false))
        if let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.85) {
            try? data.write(to: Self.subjectURL, options: [.atomic, .completeFileProtection])
        }
        lock.lock()
        image = baked
        stats = newStats
        isPersonal = true
        lock.unlock()
        return true
    }

    func render(_ dna: StyleDNA, settings: RenderSettings = RenderSettings(intensity: 1)) -> UIImage? {
        lock.lock()
        let image = image, stats = stats
        lock.unlock()
        let renderer = StyleRenderer(reference: dna, source: stats)
        return RenderEngine.shared.uiImage(renderer.apply(image, settings: settings))
    }
}
