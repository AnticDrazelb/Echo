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
    var split: CGFloat = 0.5 { didSet { refresh() } }
    /// Optional second look mixed into the current one.
    var blendStyle: Style? { didSet { scheduleRebuild() } }
    var blendAmount: Float = 0.3 { didSet { scheduleRebuild() } }
    var saveState: SaveState = .idle

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
        case .photo(let image):
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

    /// The look actually applied: the style, or the style blended with another.
    var effectiveDNA: StyleDNA {
        guard let blendStyle else { return style.dna }
        return StyleDNA.blend([(style.dna, 1 - blendAmount), (blendStyle.dna, blendAmount)])
    }

    /// What sharing and LUT export operate on.
    var exportStyle: Style {
        guard let blendStyle else { return style }
        var s = Style(name: "\(style.name) × \(blendStyle.name)", dna: effectiveDNA, creator: style.creator)
        s.recipe = [
            Style.Ingredient(name: style.name, weight: 1 - blendAmount),
            Style.Ingredient(name: blendStyle.name, weight: blendAmount),
        ]
        return s
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

    private func rebuildRenderer() async {
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
                func bake(_ img: CIImage?) -> CIImage? {
                    guard let img, let cg = RenderEngine.shared.cgImage(img) else { return nil }
                    return CIImage(cgImage: cg)
                }
                return RegionMasker.Masks(sky: bake(m.sky), skin: bake(m.skin), subject: bake(m.subject))
            }.value
            masks = result
            masksLoading = false
            refresh()
        }
    }

    // MARK: Style switching

    func switchStyle(to newStyle: Style) {
        guard newStyle.id != style.id else { return }
        style = newStyle
        if blendStyle?.id == newStyle.id { blendStyle = nil }
        creditEnabled = newStyle.creator != nil
        creditHandle = newStyle.creator ?? ""
        Task {
            await rebuildRenderer()
            refresh()
        }
    }

    // MARK: Rendering

    func isRegionAvailable(_ region: StyleRegion) -> Bool {
        region == .auto || !isVideo
    }

    private var currentMask: CIImage? {
        guard region != .auto else { return nil }
        return masks?.mask(for: region)
    }

    func refresh() {
        guard let base = previewImage, let renderer else {
            frameStore.push(previewImage)
            return
        }
        let styled = renderer.apply(base, settings: settings, mask: currentMask, seed: frameIndex)
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
            let output = await Task.detached(priority: .userInitiated) { () -> (Data, String)? in
                var out = renderer.apply(full, settings: settings, mask: mask)
                if let credit { out = Watermark.apply(credit, to: out) }
                return RenderEngine.shared.photoData(out)
            }.value
            exportProgress = 1
            guard let output else { throw MediaError.exportFailed("Couldn't encode the photo.") }
            let (data, ext) = output
            try await PhotoSaver.savePhoto(data: data, uti: ext == "heic" ? "public.heic" : "public.jpeg")

        case .video(let url):
            pause()
            let file = try await VideoProcessor.export(url: url, renderer: renderer, settings: settings, credit: credit) { value in
                Task { @MainActor in self.exportProgress = value }
            }
            try await PhotoSaver.saveVideo(url: file)
            try? FileManager.default.removeItem(at: file)
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
