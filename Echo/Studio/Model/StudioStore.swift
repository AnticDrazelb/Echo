import AVFoundation
import CoreImage
import Observation
import SwiftUI
import UIKit

/// Studio projects on disk: `Projects/<id>/project.json` plus media files.
@Observable
@MainActor
final class StudioStore {
    private(set) var projects: [Composition] = []
    private(set) var thumbnails: [UUID: UIImage] = [:]

    let root: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    func mediaURL(_ comp: Composition, file: String? = nil) -> URL {
        folder(comp.id).appendingPathComponent(file ?? comp.baseFile)
    }

    // MARK: Create

    /// New project from a photo's encoded data (kept as-is, no re-encode).
    func createPhotoProject(data: Data, fileExtension: String, name: String) throws -> Composition {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { throw MediaError.unreadable }
        let id = UUID()
        let file = "base.\(fileExtension)"
        try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
        try data.write(to: folder(id).appendingPathComponent(file))
        var comp = Composition.new(name: name, kind: .photo, file: file, aspect: image.extent.width / max(image.extent.height, 1), duration: 6)
        comp.id = id
        save(comp)
        return comp
    }

    func createPhotoProject(image: CIImage, name: String) throws -> Composition {
        guard let encoded = RenderEngine.shared.photoData(image) else { throw MediaError.unreadable }
        return try createPhotoProject(data: encoded.0, fileExtension: encoded.1, name: name)
    }

    func createVideoProject(url: URL, name: String) async throws -> Composition {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MediaError.unreadable }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: size).applying(transform)
        let fps = Double(try await track.load(.nominalFrameRate))
        let id = UUID()
        let file = "base.\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)"
        try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: folder(id).appendingPathComponent(file))
        var comp = Composition.new(
            name: name, kind: .video, file: file,
            aspect: abs(oriented.width) / max(abs(oriented.height), 1), duration: max(duration, 0.1)
        )
        comp.id = id
        comp.fps = fps > 1 ? min(fps, 60) : 30
        save(comp)
        return comp
    }

    /// Stores an overlay image for an Image layer; returns its file name.
    func addImage(_ data: Data, to comp: Composition) throws -> String {
        let name = "overlay-\(UUID().uuidString.prefix(8)).img"
        try data.write(to: folder(comp.id).appendingPathComponent(name))
        return name
    }

    // MARK: Persist

    func save(_ comp: Composition) {
        var c = comp
        c.modifiedAt = Date()
        if let i = projects.firstIndex(where: { $0.id == c.id }) { projects[i] = c } else { projects.insert(c, at: 0) }
        projects.sort { $0.modifiedAt > $1.modifiedAt }
        let url = folder(c.id).appendingPathComponent("project.json")
        if let data = try? JSONEncoder().encode(c) { try? data.write(to: url, options: .atomic) }
    }

    func setThumbnail(_ image: UIImage, for id: UUID) {
        thumbnails[id] = image
        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: folder(id).appendingPathComponent("thumb.jpg"), options: .atomic)
        }
    }

    func delete(_ comp: Composition) {
        projects.removeAll { $0.id == comp.id }
        thumbnails[comp.id] = nil
        try? FileManager.default.removeItem(at: folder(comp.id))
    }

    func duplicate(_ comp: Composition) {
        var copy = comp
        copy.id = UUID()
        copy.name = "\(comp.name) Copy"
        copy.createdAt = Date()
        try? FileManager.default.copyItem(at: folder(comp.id), to: folder(copy.id))
        save(copy)
        thumbnails[copy.id] = thumbnails[comp.id]
    }

    private func load() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("project.json")),
                  let comp = try? JSONDecoder().decode(Composition.self, from: data) else { continue }
            projects.append(comp)
            if let thumb = UIImage(contentsOfFile: dir.appendingPathComponent("thumb.jpg").path) {
                thumbnails[comp.id] = thumb
            }
        }
        projects.sort { $0.modifiedAt > $1.modifiedAt }
    }
}
