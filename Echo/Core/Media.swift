import AVFoundation
import CoreImage
import CoreTransferable
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A photo or video the user picked.
enum Media {
    /// `depth` is the photo's disparity/depth map when it has one
    /// (Portrait mode, LiDAR), used for relighting.
    case photo(CIImage, depth: CIImage?)
    case video(URL)

    var isVideo: Bool {
        if case .video = self { return true }
        return false
    }
}

struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return MovieFile(url: dest)
        }
    }
}

enum MediaError: LocalizedError {
    case unreadable
    case permissionDenied
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: "That file couldn't be opened."
        case .permissionDenied: "Echo needs permission to save to your Photos library. You can enable it in Settings."
        case .exportFailed(let reason): "Export failed: \(reason)"
        }
    }
}

enum MediaLoader {
    static func load(_ item: PhotosPickerItem) async throws -> Media {
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) || $0.conforms(to: .video) }) {
            if let movie = try await item.loadTransferable(type: MovieFile.self) {
                return .video(movie.url)
            }
            throw MediaError.unreadable
        }
        guard let data = try await item.loadTransferable(type: Data.self),
              let image = CIImage(data: data, options: [.applyOrientationProperty: true])
        else { throw MediaError.unreadable }
        let depth = CIImage(data: data, options: [.auxiliaryDisparity: true, .applyOrientationProperty: true])
            ?? CIImage(data: data, options: [.auxiliaryDepth: true, .applyOrientationProperty: true])
        return .photo(image.normalizedToOrigin(), depth: depth?.normalizedToOrigin())
    }

    /// A representative still from a video (used as a style reference).
    static func frame(of url: URL, at fraction: Double = 0.5) async throws -> CIImage {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        let time = CMTime(seconds: duration.seconds * fraction, preferredTimescale: 600)
        let (cg, _) = try await generator.image(at: time)
        return CIImage(cgImage: cg)
    }

    /// Several stills spread across a video, for stable statistics.
    static func frames(of url: URL, count: Int = 5) async -> [CIImage] {
        var out: [CIImage] = []
        for i in 0..<count {
            let f = (Double(i) + 0.5) / Double(count)
            if let img = try? await frame(of: url, at: f) { out.append(img) }
        }
        return out
    }
}

enum PhotoSaver {
    static func ensureAccess() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw MediaError.permissionDenied }
    }

    static func savePhoto(data: Data, uti: String) async throws {
        try await ensureAccess()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = uti
            request.addResource(with: .photo, data: data, options: options)
        }
    }

    static func saveVideo(url: URL) async throws {
        try await ensureAccess()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
        }
    }
}

/// "Style inspired by @creator" credit, burned into exports when enabled.
enum Watermark {
    static func apply(_ text: String, to image: CIImage) -> CIImage {
        let extent = image.extent
        let size = max(12, extent.shortSide * 0.026)
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = size * 0.3
        let attributed = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.82),
            .shadow: shadow,
        ])
        let generator = CIFilter(name: "CIAttributedTextImageGenerator", parameters: [
            "inputText": attributed,
            "inputScaleFactor": 1.0,
        ])
        guard let label = generator?.outputImage else { return image }
        let margin = size * 1.1
        let placed = label.transformed(by: CGAffineTransform(
            translationX: extent.maxX - label.extent.width - margin,
            y: extent.minY + margin
        ))
        return placed.composited(over: image).cropped(to: extent)
    }
}
