import AVFoundation
import CoreImage
import Observation
import QuartzCore
import SwiftUI
import UIKit

extension Layer {
    var textContent: TextContent? {
        get { if case .text(let t) = content { return t }; return nil }
        set { if let newValue { content = .text(newValue) } }
    }
    var shapeContent: ShapeContent? {
        get { if case .shape(let s) = content { return s }; return nil }
        set { if let newValue { content = .shape(newValue) } }
    }
    var solidColor: AnimatableColor? {
        get { if case .solid(let c) = content { return c }; return nil }
        set { if let newValue { content = .solid(newValue) } }
    }
    var gradientContent: GradientContent? {
        get { if case .gradient(let g) = content { return g }; return nil }
        set { if let newValue { content = .gradient(newValue) } }
    }
}

/// Drives one open Studio project: editing, undo, playback and rendering.
@Observable
@MainActor
final class StudioModel {
    private(set) var comp: Composition
    let store: StudioStore
    let library: StyleLibrary
    let frameStore = FrameStore()

    var time: Double = 0 {
        didSet {
            if !isPlaying, comp.baseKind == .video { seekVideo() }
            render()
        }
    }
    private(set) var isPlaying = false
    var selectedLayerID: UUID?
    var selectedEffectID: UUID?
    private(set) var isReady = false
    private(set) var canUndo = false
    private(set) var canRedo = false

    var exportProgress: Double = 0
    var isExporting = false

    // Media
    @ObservationIgnored private var previewBase: CIImage?
    @ObservationIgnored private var fullBase: CIImage?
    @ObservationIgnored private(set) var assets = StudioAssets()
    @ObservationIgnored let renderers = RendererCache()
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var videoOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored private var videoOrientation: CGImagePropertyOrientation = .up
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var lastTick: CFTimeInterval = 0

    // Undo
    @ObservationIgnored private var undoStack: [Composition] = []
    @ObservationIgnored private var redoStack: [Composition] = []
    @ObservationIgnored private var lastEditKey: String?
    @ObservationIgnored private var lastEditTime = Date.distantPast
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(comp: Composition, store: StudioStore, library: StyleLibrary) {
        self.comp = comp
        self.store = store
        self.library = library
        selectedLayerID = comp.layers.last?.id
        Task { await load() }
    }

    var canvasAspect: CGFloat { CGFloat(comp.aspect) }
    var selectedLayer: Layer? { comp.layers.first { $0.id == selectedLayerID } }
    var selectedEffect: Effect? { selectedLayer?.effects.first { $0.id == selectedEffectID } }

    // MARK: Loading

    private func load() async {
        let url = store.mediaURL(comp)
        switch comp.baseKind {
        case .photo:
            let loaded = await Task.detached(priority: .userInitiated) { () -> (CIImage, CIImage, StyleDNA)? in
                guard let data = try? Data(contentsOf: url),
                      let full = CIImage(data: data, options: [.applyOrientationProperty: true])?.normalizedToOrigin()
                else { return nil }
                let fitted = full.fitting(longSide: 1600)
                let preview = RenderEngine.shared.cgImage(fitted).map { CIImage(cgImage: $0) } ?? fitted
                return (full, preview, StyleAnalyzer.analyze(preview, options: .init(ignoreText: false)))
            }.value
            guard let loaded else { return }
            fullBase = loaded.0
            previewBase = loaded.1
            assets.baseStats = loaded.2
            loadMasks(loaded.1)
        case .video:
            let frames = await MediaLoader.frames(of: url, count: 3)
            if let first = frames.first { previewBase = first.fitting(longSide: 1280).normalizedToOrigin() }
            assets.baseStats = await Task.detached {
                StyleDNA.blend(frames.map { (StyleAnalyzer.analyze($0.fitting(longSide: 800), options: .init(ignoreText: false)), 1) })
            }.value
            await setUpVideo(url)
        }
        loadOverlayImages()
        isReady = true
        render()
        refreshThumbnail()
    }

    private func loadMasks(_ image: CIImage) {
        Task {
            let masks = await Task.detached(priority: .utility) { () -> (CIImage?, CIImage?, CIImage?) in
                let m = RegionMasker.masks(for: image)
                func bake(_ i: CIImage?) -> CIImage? {
                    guard let i, RegionMasker.coverage(of: i) > 0.01, let cg = RenderEngine.shared.cgImage(i) else { return nil }
                    return CIImage(cgImage: cg)
                }
                return (bake(m.sky), bake(m.skin), bake(m.subject))
            }.value
            assets.sky = masks.0
            assets.skin = masks.1
            assets.subject = masks.2
            render()
        }
    }

    private func loadOverlayImages() {
        for layer in comp.layers {
            guard case .image(let file) = layer.content, assets.images[file] == nil else { continue }
            let url = store.mediaURL(comp, file: file)
            if let data = try? Data(contentsOf: url),
               let image = CIImage(data: data, options: [.applyOrientationProperty: true]) {
                assets.images[file] = image.normalizedToOrigin()
            }
        }
    }

    // MARK: Rendering

    func render() {
        guard let base = currentBase() else { return }
        let image = CompositionRenderer.render(comp, base: base, at: time, assets: assets, renderers: renderers)
        frameStore.push(image)
    }

    private func currentBase() -> CIImage? { previewBase }

    private func refreshThumbnail() {
        guard let base = previewBase else { return }
        let comp = comp, assets = assets, renderers = renderers, id = comp.id
        Task {
            let thumb = await Task.detached(priority: .utility) { () -> UIImage? in
                let small = base.fitting(longSide: 480)
                return RenderEngine.shared.uiImage(CompositionRenderer.render(comp, base: small, at: 0, assets: assets, renderers: renderers))
            }.value
            if let thumb { store.setThumbnail(thumb, for: id) }
        }
    }

    // MARK: Editing

    /// Applies a change with undo. Rapid edits with the same key (a slider
    /// drag) collapse into one undo step.
    func edit(_ key: String? = nil, _ change: (inout Composition) -> Void) {
        let before = comp
        change(&comp)
        guard comp != before else { return }
        let now = Date()
        if key == nil || key != lastEditKey || now.timeIntervalSince(lastEditTime) > 0.8 {
            undoStack.append(before)
            if undoStack.count > 80 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        lastEditKey = key
        lastEditTime = now
        updateUndoState()
        scheduleSave()
        render()
    }

    func editLayer(_ id: UUID, key: String? = nil, _ change: (inout Layer) -> Void) {
        edit(key.map { "\(id)-\($0)" }) { comp in
            guard let i = comp.layers.firstIndex(where: { $0.id == id }) else { return }
            change(&comp.layers[i])
        }
    }

    func editEffect(layer: UUID, effect: UUID, key: String? = nil, _ change: (inout Effect) -> Void) {
        editLayer(layer, key: key.map { "\(effect)-\($0)" }) { l in
            guard let j = l.effects.firstIndex(where: { $0.id == effect }) else { return }
            change(&l.effects[j])
        }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(comp)
        comp = previous
        lastEditKey = nil
        afterHistoryJump()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(comp)
        comp = next
        lastEditKey = nil
        afterHistoryJump()
    }

    private func afterHistoryJump() {
        if let id = selectedLayerID, !comp.layers.contains(where: { $0.id == id }) { selectedLayerID = comp.layers.last?.id }
        updateUndoState()
        scheduleSave()
        render()
    }

    private func updateUndoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            store.save(comp)
        }
    }

    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        edit { $0.name = trimmed }
    }

    func setDuration(_ seconds: Double) {
        guard comp.baseKind == .photo else { return }
        edit("duration") { $0.duration = min(max(seconds, 1), 60) }
        if time > comp.duration { time = comp.duration }
    }

    // MARK: Layers

    private func insert(_ layer: Layer) {
        edit { comp in
            if let id = selectedLayerID, let i = comp.layers.firstIndex(where: { $0.id == id }) {
                comp.layers.insert(layer, at: i + 1)
            } else {
                comp.layers.append(layer)
            }
        }
        selectedLayerID = layer.id
        selectedEffectID = nil
    }

    func addAdjustment(with effect: EffectType? = nil) {
        var layer = Layer(name: effect?.title ?? "Adjustment", content: .adjustment)
        if let effect { layer.effects = [makeEffect(effect)] }
        insert(layer)
        selectedEffectID = layer.effects.first?.id
    }

    func addText() {
        insert(Layer(name: "Text", content: .text(TextContent())))
    }

    func addShape(_ kind: ShapeKind) {
        var shape = ShapeContent()
        shape.kind = kind
        if kind == .ellipse { shape.height = AnimatableValue(0.5); shape.width = AnimatableValue(0.5) }
        insert(Layer(name: kind == .ellipse ? "Ellipse" : "Rectangle", content: .shape(shape)))
    }

    func addSolid() {
        var layer = Layer(name: "Solid", content: .solid(AnimatableColor(0.05, 0.05, 0.08)))
        layer.opacity = AnimatableValue(0.5)
        layer.blend = .multiply
        insert(layer)
    }

    func addGradient() {
        var layer = Layer(name: "Gradient", content: .gradient(GradientContent()))
        layer.opacity = AnimatableValue(0.55)
        layer.blend = .softLight
        insert(layer)
    }

    func addImage(data: Data) {
        guard let file = try? store.addImage(data, to: comp) else { return }
        if let image = CIImage(data: data, options: [.applyOrientationProperty: true]) {
            assets.images[file] = image.normalizedToOrigin()
        }
        insert(Layer(name: "Image", content: .image(file)))
    }

    func deleteLayer(_ id: UUID) {
        guard let layer = comp.layers.first(where: { $0.id == id }), !layer.isBase else { return }
        edit { $0.layers.removeAll { $0.id == id } }
        if selectedLayerID == id { selectedLayerID = comp.layers.last?.id; selectedEffectID = nil }
    }

    func duplicateLayer(_ id: UUID) {
        guard let i = comp.layers.firstIndex(where: { $0.id == id }), !comp.layers[i].isBase else { return }
        var copy = comp.layers[i]
        copy.id = UUID()
        copy.name += " Copy"
        copy.effects = copy.effects.map { var e = $0; e.id = UUID(); return e }
        edit { $0.layers.insert(copy, at: i + 1) }
        selectedLayerID = copy.id
    }

    /// Moves a layer up (+1) or down (-1); the base layer stays at the bottom.
    func moveLayer(_ id: UUID, by delta: Int) {
        guard let i = comp.layers.firstIndex(where: { $0.id == id }), !comp.layers[i].isBase else { return }
        let j = i + delta
        guard j >= 1, j < comp.layers.count else { return }
        edit { $0.layers.swapAt(i, j) }
    }

    // MARK: Effects

    func makeEffect(_ type: EffectType) -> Effect {
        var effect = Effect(type)
        if type == .look, let style = library.styles.first {
            effect.dna = style.dna
            effect.styleName = style.name
        }
        return effect
    }

    func addEffect(_ type: EffectType, to layerID: UUID) {
        let effect = makeEffect(type)
        editLayer(layerID) { $0.effects.append(effect) }
        selectedEffectID = effect.id
    }

    func removeEffect(_ effectID: UUID, from layerID: UUID) {
        editLayer(layerID) { $0.effects.removeAll { $0.id == effectID } }
        if selectedEffectID == effectID { selectedEffectID = nil }
    }

    func moveEffect(_ effectID: UUID, in layerID: UUID, by delta: Int) {
        editLayer(layerID) { layer in
            guard let i = layer.effects.firstIndex(where: { $0.id == effectID }) else { return }
            let j = i + delta
            guard j >= 0, j < layer.effects.count else { return }
            layer.effects.swapAt(i, j)
        }
    }

    func setLook(_ style: Style, effect: UUID, layer: UUID) {
        editEffect(layer: layer, effect: effect) { e in
            e.dna = style.dna
            e.styleName = style.name
        }
    }

    // MARK: Animation presets

    enum Preset: String, CaseIterable, Identifiable {
        case kenBurns = "Ken Burns", fadeIn = "Fade In", fadeOut = "Fade Out", popIn = "Pop In", slideIn = "Slide In", spin = "Spin"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .kenBurns: "arrow.up.left.and.arrow.down.right"
            case .fadeIn: "circle.lefthalf.filled"
            case .fadeOut: "circle.righthalf.filled"
            case .popIn: "sparkle"
            case .slideIn: "arrow.right.to.line"
            case .spin: "arrow.clockwise"
            }
        }
    }

    func apply(_ preset: Preset, to layerID: UUID) {
        let d = comp.duration
        let t0 = time
        editLayer(layerID) { l in
            switch preset {
            case .kenBurns:
                l.transform.scale.keyframes = [Keyframe(time: 0, value: 1.0, easing: .linear), Keyframe(time: d, value: 1.18)]
                l.transform.x.keyframes = [Keyframe(time: 0, value: 0.5, easing: .linear), Keyframe(time: d, value: 0.46)]
                l.transform.y.keyframes = [Keyframe(time: 0, value: 0.5, easing: .linear), Keyframe(time: d, value: 0.47)]
            case .fadeIn:
                l.opacity.keyframes = [Keyframe(time: t0, value: 0, easing: .easeOut), Keyframe(time: min(d, t0 + 0.8), value: 1)]
            case .fadeOut:
                l.opacity.keyframes = [Keyframe(time: max(0, d - 0.8), value: 1, easing: .easeIn), Keyframe(time: d, value: 0)]
            case .popIn:
                let s = l.transform.scale.at(t0)
                l.transform.scale.keyframes = [
                    Keyframe(time: t0, value: s * 0.4, easing: .easeOut),
                    Keyframe(time: min(d, t0 + 0.35), value: s * 1.08, easing: .easeInOut),
                    Keyframe(time: min(d, t0 + 0.55), value: s),
                ]
                l.opacity.keyframes = [Keyframe(time: t0, value: 0, easing: .easeOut), Keyframe(time: min(d, t0 + 0.2), value: 1)]
            case .slideIn:
                let x = l.transform.x.at(t0)
                l.transform.x.keyframes = [Keyframe(time: t0, value: x - 0.6, easing: .easeOut), Keyframe(time: min(d, t0 + 0.7), value: x)]
            case .spin:
                l.transform.rotation.keyframes = [Keyframe(time: 0, value: 0, easing: .linear), Keyframe(time: d, value: 360)]
            }
        }
    }

    // MARK: Playback

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        if time >= comp.duration - 0.01 { time = 0 }
        isPlaying = true
        if comp.baseKind == .video {
            player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            player?.play()
        }
        lastTick = CACurrentMediaTime()
        if displayLink == nil {
            let link = CADisplayLink(target: StudioLinkProxy { [weak self] in self?.tick() }, selector: #selector(StudioLinkProxy.fire))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 30)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    func pause() {
        isPlaying = false
        player?.pause()
    }

    private func tick() {
        guard isPlaying else {
            // While paused, still pull fresh video frames after a seek.
            if comp.baseKind == .video { pullVideoFrame() }
            return
        }
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now
        if comp.baseKind == .video {
            pullVideoFrame()
            if let current = player?.currentTime().seconds, current.isFinite {
                if current >= comp.duration - 0.02 {
                    player?.seek(to: .zero)
                    player?.play()
                }
                setTimeSilently(current)
            }
        } else {
            var t = time + dt
            if t > comp.duration { t = 0 }
            setTimeSilently(t)
        }
        render()
    }

    private func setTimeSilently(_ t: Double) {
        // Updating `time` normally seeks video; during playback the player
        // is the clock, so skip that.
        let wasPlaying = isPlaying
        isPlaying = true
        time = t
        isPlaying = wasPlaying
    }

    // MARK: Video base

    private func setUpVideo(_ url: URL) async {
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let transform = try? await track.load(.preferredTransform) {
            videoOrientation = EditorModel.orientation(for: transform)
        }
        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        videoOutput = output
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        self.player = player
        // Display link also services paused seeks.
        let link = CADisplayLink(target: StudioLinkProxy { [weak self] in self?.tick() }, selector: #selector(StudioLinkProxy.fire))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func seekVideo() {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func pullVideoFrame() {
        guard let output = videoOutput else { return }
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else { return }
        previewBase = CIImage(cvPixelBuffer: buffer).oriented(videoOrientation).normalizedToOrigin().fitting(longSide: 1280)
        if !isPlaying { render() }
    }

    func close() {
        pause()
        displayLink?.invalidate()
        displayLink = nil
        saveTask?.cancel()
        store.save(comp)
        refreshThumbnail()
    }

    // MARK: Export

    /// Full-resolution still at the playhead.
    func exportStill() async throws {
        guard let full = fullBase ?? previewBase else { return }
        isExporting = true
        defer { isExporting = false }
        let comp = comp, assets = assets, renderers = renderers, t = time
        let encoded = await Task.detached(priority: .userInitiated) {
            RenderEngine.shared.photoData(CompositionRenderer.render(comp, base: full, at: t, assets: assets, renderers: renderers))
        }.value
        guard let encoded else { throw MediaError.exportFailed("Couldn't render the frame.") }
        try await PhotoSaver.savePhoto(data: encoded.0, uti: encoded.1 == "heic" ? "public.heic" : "public.jpeg")
    }

    /// Renders the whole composition to an H.265 movie and saves it.
    func exportVideo() async throws {
        isExporting = true
        exportProgress = 0
        defer { isExporting = false }
        pause()
        let activity = ExportActivity(styleName: comp.name, kind: "Studio", thumbnail: store.thumbnails[comp.id])
        do {
            let url: URL
            let progress: @Sendable (Double) -> Void = { value in
                Task { @MainActor in
                    self.exportProgress = value
                    activity.update(value, detail: "Rendering frames")
                }
            }
            switch comp.baseKind {
            case .photo:
                guard let full = fullBase ?? previewBase else { throw MediaError.unreadable }
                url = try await StudioExporter.renderPhotoMovie(comp, base: full.fitting(longSide: 1920), assets: assets, renderers: renderers, progress: progress)
            case .video:
                url = try await StudioExporter.renderVideoMovie(comp, source: store.mediaURL(comp), assets: assets, renderers: renderers, progress: progress)
            }
            activity.update(1, detail: "Saving to Photos")
            try await PhotoSaver.saveVideo(url: url)
            try? FileManager.default.removeItem(at: url)
            activity.end("Saved to Photos")
        } catch {
            activity.end(error is CancellationError ? "Cancelled" : "Export failed")
            throw error
        }
    }
}

private final class StudioLinkProxy: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}
