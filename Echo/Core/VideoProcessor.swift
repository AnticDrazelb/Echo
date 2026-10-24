import AVFoundation
import CoreImage

/// Renders a style into a video file, preserving audio and orientation.
enum VideoProcessor {
    static func export(
        url: URL,
        renderer: StyleRenderer,
        settings: RenderSettings,
        credit: String?,
        progress: @escaping @Sendable (Float) -> Void
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let frame = request.sourceImage
            let seed = Int(request.compositionTime.seconds * 30)
            var out = renderer.apply(frame, settings: settings, seed: seed)
            if let credit { out = Watermark.apply(credit, to: out) }
            request.finish(with: out.cropped(to: frame.extent), context: RenderEngine.shared.context)
        }

        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Echo-\(UUID().uuidString).mov")
        // HEVC keeps 10-bit HDR sources intact; frame rate follows the source track.
        let compatible = AVAssetExportSession.exportPresets(compatibleWith: asset)
        let preset = compatible.contains(AVAssetExportPresetHEVCHighestQuality)
            ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MediaError.exportFailed("This video format isn't supported.")
        }
        session.outputURL = output
        session.outputFileType = .mov
        session.videoComposition = composition
        session.shouldOptimizeForNetworkUse = true

        let box = SessionBox(session)
        let timer = Task {
            while !Task.isCancelled {
                progress(box.session.progress)
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            box.session.exportAsynchronously { cont.resume() }
        }
        timer.cancel()
        progress(1)

        switch session.status {
        case .completed: return output
        case .cancelled: throw CancellationError()
        default: throw MediaError.exportFailed(session.error?.localizedDescription ?? "Unknown error")
        }
    }

    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }
}
