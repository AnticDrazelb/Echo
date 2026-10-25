import AVFoundation
import CoreImage
import Observation
import QuartzCore
import SwiftUI

/// Drives the apply/refine screen for one photo or video.
@Observable
@MainActor
final class EditorModel {
    private(set) var style: Style
    let media: Media
    let library: StyleLibrary
    let frameStore = FrameStore()

    var settings = RenderSettings() { didSet { refresh() } }
    var region: StyleRegion = .auto { didSet { refresh() } }
    /// When true the selected region is protected from the style instead.
    var regionExcluded = false { didSet { refresh() } }
    var split: CGFloat = 0.5 { didSet { refresh() } }
    /// Optional second look mixed into the current one.
    /// Up to two extra looks mixed in ("50% Dune, 30% Kodak Gold, 20% Cyberpunk").
    var blendParts: [BlendPart] = [] { didSet { scheduleRebuild() } }
    var mainWeight: Float = 0.5 { didSet { scheduleRebuild() } }
    static let maxBlendParts = 2

    struct BlendPart: Identifiable, Equatable {
        var style: Style
        var weight: Float
        var id: UUID { style.id }
    }
    var saveState: SaveState = .idle
    /// Debug screenshots: asks the view to open the export sheet.
    var demoShowExport = false

    enum SaveState: Equatable { case idle, saving, saved }

    private(set) var aspectRatio: CGFloat = 3 / 4
    private(set) var isReady = false
    private(set) var masksLoading = false
    private(set) var isPlaying = false

    var isExporting = false
    var exportProgress: Float = 0
    var creditEnabled: Bool
    var creditHandle: String

    @ObservationIgnored private var fullImage: CIImage?
    @ObservationIgnored private var previewImage: CIImage?
    @ObservationIgnored private var sourceStats: StyleDNA?
    @ObservationIgnored private var renderer: StyleRenderer?
    @ObservationIgnored private var masks: RegionMasker.Masks?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var depthMap: CIImage?
    @ObservationIgnored private var shading: CIImage?
    /// The photo carries depth, so Light can relight it.
    private(set) var hasDepth = false

    // Video
    @ObservationIgnored private(set) var player: AVPlayer?
    @ObservationIgnored private var videoOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var videoOrientation: CGImagePropertyOrientation = .up
    @ObservationIgnored private var loopObserver: NSObjectProtocol?
    @ObservationIgnored private var frameIndex = 0

    init(style: Style, media: Media, library: StyleLibrary) {
        self.style = style
        self.media = media
        self.library = library
        creditEnabled = style.creator != nil
        creditHandle = style.creator ?? ""
        Task { await prepare() }
    }

    var isVideo: Bool { media.isVideo }

    // MARK: Setup

    private func prepare() async {
        switch media {
        case .photo(let image, let depth):
            let prepared = await Task.detached(priority: .userInitiated) { () -> (CIImage, StyleDNA) in
                // Bake the preview to a bitmap so interaction never re-decodes the original.
                let fitted = image.fitting(longSide: 2000)
                let baked = RenderEngine.shared.cgImage(fitted).map { CIImage(cgImage: $0) } ?? fitted
                return (baked, StyleAnalyzer.analyze(baked, options: .init(ignoreText: false)))
            }.value
            fullImage = image
            previewImage = prepared.0
            aspectRatio = prepared.0.extent.width / max(prepared.0.extent.height, 1)
            sourceStats = prepared.1
            await rebuildRenderer()
            isReady = true
            refresh()
            loadMasks(for: prepared.0)
            library.usePreviewSubject(prepared.0)
            depthMap = depth
            hasDepth = depth != nil
            rebuildShading()

        case .video(let url):
            let frames = await MediaLoader.frames(of: url, count: 4)
            let stats = await Task.detached(priority: .userInitiated) {
                StyleDNA.blend(frames.map { (StyleAnalyzer.analyze($0.fitting(longSide: 800), options: .init(ignoreText: false)), 1) })
            }.value
            sourceStats = stats
            if let first = frames.first {
                previewImage = first
                aspectRatio = first.extent.width / max(first.extent.height, 1)
            }
            await rebuildRenderer()
            await setUpPlayer(url: url)
            isReady = true
            refresh()
        }
    }

    var isBlending: Bool { !blendParts.isEmpty }

    private var totalWeight: Float {
        max(0.0001, mainWeight + blendParts.reduce(0) { $0 + $1.weight })
    }

    /// Normalized share (0...1) for display.
    func share(of weight: Float) -> Float { weight / totalWeight }

    /// The look actually applied: the style, or the style blended with others.
    var effectiveDNA: StyleDNA {
        guard isBlending else { return style.dna }
        return StyleDNA.blend([(style.dna, mainWeight)] + blendParts.map { ($0.style.dna, $0.weight) })
    }

    /// What sharing and LUT export operate on.
    var exportStyle: Style {
        guard isBlending else { return style }
        let names = [style.name] + blendParts.map(\.style.name)
        var s = Style(name: names.joined(separator: " × "), dna: effectiveDNA, creator: style.creator)
        s.recipe = [Style.Ingredient(name: style.name, weight: share(of: mainWeight))]
            + blendParts.map { Style.Ingredient(name: $0.style.name, weight: share(of: $0.weight)) }
        return s
    }

    func addBlend(_ other: Style) {
        guard other.id != style.id, blendParts.count < Self.maxBlendParts,
              !blendParts.contains(where: { $0.style.id == other.id }) else { return }
        // Defaults read as 50 / 30 / 20.
        blendParts.append(BlendPart(style: other, weight: blendParts.isEmpty ? 0.3 : 0.2))
    }

    func removeBlend(_ part: BlendPart) {
        blendParts.removeAll { $0.id == part.id }
    }

    func saveBlendAsStyle() -> Style {
        var s = exportStyle
        s.name = library.uniqueName(s.name)
        library.add(s)
        return s
    }

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task {
            try? await Task.sleep(nanoseconds: 50_000_000) // coalesce slider ticks
            if Task.isCancelled { return }
            await rebuildRenderer()
            if !Task.isCancelled { refresh() }
        }
    }

    /// Shading map for the preview, from the photo's depth and the look's light.
    private func rebuildShading() {
        guard let depthMap, let preview = previewImage else { shading = nil; return }
        let light = Relighter.light(for: effectiveDNA)
        let extent = preview.extent
        Task {
            let map = await Task.detached(priority: .userInitiated) {
                Relighter.shadingMap(depth: depthMap, extent: extent, light: light)
                    .flatMap { RenderEngine.shared.cgImage($0) }
                    .map { CIImage(cgImage: $0) }
            }.value
            shading = map
            refresh()
        }
    }

    private func rebuildRenderer() async {
        rebuildShading()
        guard let stats = sourceStats else { return }
        let r = StyleRenderer(reference: effectiveDNA, source: stats)
        await Task.detached(priority: .userInitiated) { r.warmUp() }.value
        renderer = r
    }

    private func loadMasks(for image: CIImage) {
        masksLoading = true
        Task {
            let result = await Task.detached(priority: .utility) { () -> RegionMasker.Masks in
                let m = RegionMasker.masks(for: image)
                // Materialize so previews don't re-run the mask graph every frame.
                // Empty masks (no sky / no people found) are dropped so the
                // region shows as unavailable instead of silently doing nothing.
                func bake(_ img: CIImage?) -> CIImage? {
                    guard let img, RegionMasker.coverage(of: img) > 0.01,
                          let cg = RenderEngine.shared.cgImage(img) else { return nil }
                    return CIImage(cgImage: cg)
                }
                return RegionMasker.Masks(sky: bake(m.sky), skin: bake(m.skin), subject: bake(m.subject))
            }.value
            masks = result
            masksLoading = false
            if region != .auto, result.mask(for: region) == nil {
                region = .auto
                regionExcluded = false
            }
            refresh()
        }
    }

    // MARK: Style switching

    func switchStyle(to newStyle: Style) {
        guard newStyle.id != style.id else { return }
        style = newStyle
        blendParts.removeAll { $0.style.id == newStyle.id }
        creditEnabled = newStyle.creator != nil
        creditHandle = newStyle.creator ?? ""
        Task {
            await rebuildRenderer()
            refresh()
        }
    }

    // MARK: Rendering

    func isRegionAvailable(_ region: StyleRegion) -> Bool {
        if region == .auto { return true }
        if isVideo { return false }
        // Until masks are ready, allow selection (a spinner shows on the chip).
        guard !masksLoading, let masks else { return true }
        return masks.mask(for: region) != nil
    }

    /// Why a region chip is disabled, for the user.
    func unavailableReason(_ region: StyleRegion) -> String? {
        guard !isRegionAvailable(region) else { return nil }
        if isVideo { return "Regions work on photos" }
        switch region {
        case .sky: return "No sky found in this photo"
        case .skin: return "No skin found in this photo"
        case .subject: return "No clear subject found"
        case .auto: return nil
        }
    }

    /// Tap cycles: include region → exclude (protect) region → everywhere.
    func tapRegion(_ tapped: StyleRegion) {
        if tapped == .auto || tapped != region {
            region = tapped
            regionExcluded = false
        } else if !regionExcluded {
            regionExcluded = true
        } else {
            region = .auto
            regionExcluded = false
        }
    }

    private var currentMask: CIImage? {
        guard region != .auto, let mask = masks?.mask(for: region) else { return nil }
        return regionExcluded ? mask.applyingFilter("CIColorInvert") : mask
    }

    func refresh() {
        guard let base = previewImage, let renderer else {
            frameStore.push(previewImage)
            return
        }
        let styled = renderer.apply(base, settings: settings, mask: currentMask, seed: frameIndex, shading: shading)
        let ext = base.extent
        let cut = CGRect(x: ext.minX + ext.width * split, y: ext.minY, width: ext.width * (1 - split), height: ext.height)
        frameStore.push(styled.cropped(to: cut).composited(over: base))
    }

    // MARK: Video playback

    private func setUpPlayer(url: URL) async {
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let transform = try? await track.load(.preferredTransform) {
            videoOrientation = Self.orientation(for: transform)
        }
        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        videoOutput = output
        let player = AVPlayer(playerItem: item)
        player.isMuted = false
        player.actionAtItemEnd = .none
        self.player = player
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
        let link = CADisplayLink(target: DisplayLinkProxy { [weak self] in self?.tick() }, selector: #selector(DisplayLinkProxy.fire))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
        play()
    }

    private func tick() {
        guard let output = videoOutput else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else { return }
        let frame = CIImage(cvPixelBuffer: buffer).oriented(videoOrientation).normalizedToOrigin()
        previewImage = frame.fitting(longSide: 1600)
        frameIndex += 1
        refresh()
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        player?.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func tearDown() {
        displayLink?.invalidate()
        displayLink = nil
        player?.pause()
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = nil
    }

    static func orientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        let angle = atan2(t.b, t.a) * 180 / .pi
        switch Int(angle.rounded()) {
        case 90: return .right
        case -90: return .left
        case 180, -180: return .down
        default: return .up
        }
    }

    // MARK: Export

    /// One-tap export straight to Photos.
    func quickSave() async throws {
        guard saveState != .saving else { return }
        saveState = .saving
        do {
            try await saveToPhotos()
            saveState = .saved
            Task {
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                if saveState == .saved { saveState = .idle }
            }
        } catch {
            saveState = .idle
            throw error
        }
    }

    var credit: String? {
        guard creditEnabled else { return nil }
        let handle = creditHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !handle.isEmpty else { return nil }
        return "Style inspired by \(handle.hasPrefix("@") ? handle : "@\(handle)")"
    }

    func saveToPhotos() async throws {
        guard let renderer else { return }
        isExporting = true
        exportProgress = 0
        defer { isExporting = false }
        let settings = settings
        let credit = credit

        switch media {
        case .photo:
            guard let full = fullImage, let preview = previewImage else { return }
            var mask = currentMask
            if let m = mask {
                let sx = full.extent.width / preview.extent.width
                let sy = full.extent.height / preview.extent.height
                mask = m.transformed(by: CGAffineTransform(scaleX: sx, y: sy)).cropped(to: full.extent)
            }
            let fullShading = shading.map {
                $0.transformed(by: CGAffineTransform(
                    scaleX: full.extent.width / preview.extent.width,
                    y: full.extent.height / preview.extent.height
                )).cropped(to: full.extent)
            }
            let output = await Task.detached(priority: .userInitiated) { () -> (Data, String)? in
                var out = renderer.apply(full, settings: settings, mask: mask, shading: fullShading)
                if let credit { out = Watermark.apply(credit, to: out) }
                return RenderEngine.shared.photoData(out)
            }.value
            exportProgress = 1
            guard let output else { throw MediaError.exportFailed("Couldn't encode the photo.") }
            let (data, ext) = output
            try await PhotoSaver.savePhoto(data: data, uti: ext == "heic" ? "public.heic" : "public.jpeg")

        case .video(let url):
            pause()
            let thumb = previewImage.flatMap { RenderEngine.shared.uiImage(renderer.apply($0.fitting(longSide: 200), settings: settings)) }
            let activity = ExportActivity(styleName: exportStyle.name, kind: "Video", thumbnail: thumb)
            do {
                let file = try await VideoProcessor.export(url: url, renderer: renderer, settings: settings, credit: credit) { value in
                    Task { @MainActor in
                        self.exportProgress = value
                        activity.update(Double(value), detail: "Rendering frames")
                    }
                }
                activity.update(1, detail: "Saving to Photos")
                try await PhotoSaver.saveVideo(url: file)
                try? FileManager.default.removeItem(at: file)
                activity.end("Saved to Photos")
            } catch is CancellationError {
                activity.end("Cancelled")
                throw CancellationError()
            } catch {
                activity.end("Export failed")
                throw error
            }
        }
    }

    func exportLUT() async throws -> URL {
        let style = exportStyle
        let source = sourceStats ?? .neutral
        let settings = settings
        return try await Task.detached { try CubeExporter.write(style: style, source: source, settings: settings) }.value
    }
}

/// Avoids a retain cycle between CADisplayLink and its target.
private final class DisplayLinkProxy: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}
