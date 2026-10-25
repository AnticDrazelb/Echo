import AVFoundation
import CoreImage

/// Renders Studio compositions to movies.
enum StudioExporter {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    /// A photo-based composition (animated stills) → H.265 movie.
    static func renderPhotoMovie(
        _ comp: Composition, base: CIImage, assets: StudioAssets, renderers: RendererCache,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let cancelled = Flag()
        let token = ExportCancellation.register { cancelled.set() }
        defer { ExportCancellation.unregister(token) }

        // Even dimensions keep the encoder happy.
        let width = Int(base.extent.width) / 2 * 2, height = Int(base.extent.height) / 2 * 2
        let canvas = base.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Studio-\(UUID().uuidString).mov")

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { () -> URL in
                let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                ])
                input.expectsMediaDataInRealTime = false
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                ])
                guard writer.canAdd(input) else { throw MediaError.exportFailed("Encoder unavailable") }
                writer.add(input)
                guard writer.startWriting() else { throw writer.error ?? MediaError.exportFailed("Encoder failed to start") }
                writer.startSession(atSourceTime: .zero)

                let fps = comp.fps
                let frames = max(1, Int((comp.duration * fps).rounded()))
                for i in 0..<frames {
                    if cancelled.isSet || Task.isCancelled {
                        writer.cancelWriting()
                        throw CancellationError()
                    }
                    while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                    let t = Double(i) / fps
                    let image = CompositionRenderer.render(comp, base: canvas, at: t, assets: assets, renderers: renderers)
                    guard let pool = adaptor.pixelBufferPool else { throw MediaError.exportFailed("No pixel buffers") }
                    var buffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                    guard let buffer else { throw MediaError.exportFailed("No pixel buffers") }
                    RenderEngine.shared.context.render(image, to: buffer, bounds: canvas.extent, colorSpace: RenderEngine.sRGB)
                    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps.rounded())))
                    if i % 3 == 0 { progress(Double(i) / Double(frames)) }
                }
                input.markAsFinished()
                await writer.finishWriting()
                guard writer.status == .completed else { throw writer.error ?? MediaError.exportFailed("Encoding failed") }
                progress(1)
                return url
            }.value
        } onCancel: {
            cancelled.set()
        }
    }

    /// A video-based composition → movie with the original audio.
    static func renderVideoMovie(
        _ comp: Composition, source: URL, assets: StudioAssets, renderers: RendererCache,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let frame = request.sourceImage.normalizedToOrigin()
            let out = CompositionRenderer.render(comp, base: frame, at: request.compositionTime.seconds, assets: assets, renderers: renderers)
            request.finish(with: out.cropped(to: frame.extent), context: RenderEngine.shared.context)
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Studio-\(UUID().uuidString).mov")
        let presets = AVAssetExportSession.exportPresets(compatibleWith: asset)
        let preset = presets.contains(AVAssetExportPresetHEVCHighestQuality) ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MediaError.exportFailed("This video format isn't supported.")
        }
        session.outputURL = output
        session.outputFileType = .mov
        session.videoComposition = composition

        final class Box: @unchecked Sendable { let s: AVAssetExportSession; init(_ s: AVAssetExportSession) { self.s = s } }
        let box = Box(session)
        let token = ExportCancellation.register { box.s.cancelExport() }
        defer { ExportCancellation.unregister(token) }
        let ticker = Task {
            while !Task.isCancelled {
                progress(Double(box.s.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                box.s.exportAsynchronously { cont.resume() }
            }
        } onCancel: {
            box.s.cancelExport()
        }
        ticker.cancel()
        switch session.status {
        case .completed:
            progress(1)
            return output
        case .cancelled: throw CancellationError()
        default: throw MediaError.exportFailed(session.error?.localizedDescription ?? "Unknown error")
        }
    }
}
