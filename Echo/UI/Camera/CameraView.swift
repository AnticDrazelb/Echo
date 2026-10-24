import AVFoundation
import Observation
import PhotosUI
import SwiftUI

@Observable
@MainActor
final class CameraModel: WatchRemote {
    enum Mode: String, CaseIterable { case look = "Look", shoot = "Shoot", museum = "Museum" }
    enum Access { case unknown, granted, denied }

    let pipeline = CameraPipeline()
    var mode: Mode = .look {
        didSet {
            if mode == .museum { startMuseum() } else { stopMuseum() }
            applyStyle()
            syncWatch()
        }
    }
    /// Museum Mode: the recognised painting, if any.
    private(set) var museumMatch: MuseumCatalog.Entry?
    private(set) var museumCount = 0
    private(set) var museumReady = false
    @ObservationIgnored private var museumTask: Task<Void, Never>?
    var access: Access = .unknown
    var selectedStyleID: UUID? { didSet { applyStyle(); syncWatch() } }
    var intensity: Float = 1 { didSet { pipeline.setIntensity(intensity); syncWatch() } }
    /// A look captured this session that hasn't been saved yet.
    var pendingLook: PendingStyle?
    var isCapturing = false
    var flash = false
    var shutterCount = 0
    private(set) var isRecording = false
    private(set) var recordingStarted: Date?
    var isSavingVideo = false

    private let library: StyleLibrary

    init(library: StyleLibrary, initialStyleID: UUID?) {
        self.library = library
        if let initialStyleID {
            selectedStyleID = initialStyleID
            mode = .shoot
        } else {
            selectedStyleID = library.styles.first?.id
        }
    }

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: access = .granted
        case .notDetermined:
            access = await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        default: access = .denied
        }
        guard access == .granted else { return }
        WatchBridge.shared.remote = self
        syncWatch()
        applyStyle()
        pipeline.start { ok in
            if !ok { Task { @MainActor in self.access = .denied } }
        }
    }

    func stop() {
        if WatchBridge.shared.remote === self { WatchBridge.shared.remote = nil }
        WatchBridge.shared.sendState(mode: mode.rawValue, style: nil, intensity: intensity, recording: false, cameraOpen: false)
        stopMuseum()
        if isRecording {
            isRecording = false
            pipeline.stopRecording { url in
                if let url { try? FileManager.default.removeItem(at: url) }
            }
        }
        pipeline.stop()
    }

    private func applyStyle() {
        if mode == .shoot, let id = selectedStyleID, let style = library.style(id: id) {
            pipeline.setStyle(style.dna)
        } else if mode == .museum, let match = museumMatch {
            pipeline.setStyle(match.dna)
        } else {
            pipeline.setStyle(nil)
        }
    }

    // MARK: Museum Mode

    private func startMuseum() {
        museumTask?.cancel()
        museumTask = Task { [weak self] in
            let entries = await Task.detached(priority: .userInitiated) { MuseumCatalog.shared.load() }.value
            guard let self else { return }
            museumCount = entries.count
            museumReady = true
            var candidate: String?
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let frame = pipeline.latestFrame() else { continue }
                let found = await Task.detached(priority: .utility) {
                    MuseumCatalog.shared.match(frame.normalizedToOrigin())
                }.value
                if Task.isCancelled { return }
                if let found {
                    misses = 0
                    // Require two agreeing frames before announcing a match.
                    if found.artwork.id == candidate, museumMatch?.artwork.id != found.artwork.id {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { museumMatch = found }
                        applyStyle()
                    }
                    candidate = found.artwork.id
                } else {
                    misses += 1
                    candidate = nil
                    if misses >= 4, museumMatch != nil {
                        withAnimation(.easeOut) { museumMatch = nil }
                        applyStyle()
                    }
                }
            }
        }
    }

    private func stopMuseum() {
        museumTask?.cancel()
        museumTask = nil
        museumMatch = nil
    }

    /// Saves the recognised work's look. Only the bundled catalog thumbnail
    /// is used; nothing from the camera is stored.
    func saveMuseumLook() -> Style? {
        guard let match = museumMatch else { return nil }
        let style = Style(name: library.uniqueName(match.artwork.title), dna: match.dna, creator: match.artwork.artist)
        library.add(style, reference: match.thumbnail)
        return style
    }

    /// Freezes the current frame's look ("hold to lock").
    func lockLook() async {
        guard let frame = pipeline.latestFrame(), !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        flashScreen()
        let result = await Task.detached(priority: .userInitiated) { () -> (StyleDNA, UIImage?) in
            let still = frame.normalizedToOrigin()
            let baked = RenderEngine.shared.cgImage(still.fitting(longSide: 1200)).map { CIImage(cgImage: $0) } ?? still
            return (StyleAnalyzer.analyze(baked), RenderEngine.shared.uiImage(baked.fitting(longSide: 600)))
        }.value
        // Preview the captured look live right away.
        pipeline.setStyle(result.0)
        WatchBridge.shared.sendEvent(WatchMessage.locked)
        pendingLook = PendingStyle(
            dna: result.0, reference: result.1,
            suggestedName: StyleExtraction.suggestName(for: result.0), origin: .camera
        )
    }

    func didSaveLook(_ style: Style) {
        selectedStyleID = style.id
        mode = .shoot
    }

    func didDiscardLook() {
        applyStyle()
    }

    /// Takes a full-resolution photo with the current look and saves it.
    func shoot() async throws {
        guard mode == .shoot, let id = selectedStyleID, let style = library.style(id: id) else { return }
        isCapturing = true
        shutterCount += 1
        flashScreen()
        defer { isCapturing = false }
        let image: CIImage = try await withCheckedThrowingContinuation { cont in
            pipeline.capturePhoto { cont.resume(with: $0) }
        }
        library.usePreviewSubject(image)
        let settings = RenderSettings(intensity: intensity)
        let data = await Task.detached(priority: .userInitiated) { () -> (Data, String)? in
            let stats = StyleAnalyzer.analyze(image.fitting(longSide: 1200), options: .init(ignoreText: false))
            let renderer = StyleRenderer(reference: style.dna, source: stats)
            var out = renderer.apply(image, settings: settings)
            if let credit = style.creditLine { out = Watermark.apply(credit, to: out) }
            return RenderEngine.shared.photoData(out)
        }.value
        guard let data else { throw MediaError.exportFailed("Couldn't encode the photo.") }
        try await PhotoSaver.savePhoto(data: data.0, uti: data.1 == "heic" ? "public.heic" : "public.jpeg")
    }

    /// Hold the shutter: records the styled feed (with sound if allowed).
    func startRecording() async {
        guard mode == .shoot, !isRecording else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            pipeline.enableAudio { cont.resume() }
        }
        pipeline.startRecording()
        isRecording = true
        recordingStarted = Date()
        shutterCount += 1
        syncWatch()
    }

    func stopRecording() async throws {
        guard isRecording else { return }
        isRecording = false
        recordingStarted = nil
        shutterCount += 1
        syncWatch()
        isSavingVideo = true
        defer { isSavingVideo = false }
        let url: URL? = await withCheckedContinuation { cont in
            pipeline.stopRecording { cont.resume(returning: $0) }
        }
        guard let url else { throw MediaError.exportFailed("The clip was too short.") }
        try await PhotoSaver.saveVideo(url: url)
        try? FileManager.default.removeItem(at: url)
    }

    /// A reference picked from Photos inside the capture screen.
    func useReference(_ media: Media) async throws {
        isCapturing = true
        defer { isCapturing = false }
        let pending = try await StyleExtraction.pending(from: media, origin: .photos)
        pipeline.setStyle(pending.dna)
        pendingLook = pending
    }

    private func syncWatch() {
        let name = mode == .museum ? museumMatch?.artwork.title
            : (mode == .shoot ? selectedStyleID.flatMap { library.style(id: $0)?.name } : nil)
        WatchBridge.shared.sendState(mode: mode.rawValue, style: name, intensity: intensity, recording: isRecording)
    }

    private func flashScreen() {
        flash = true
        withAnimation(.easeOut(duration: 0.35)) { flash = false }
    }
}

// MARK: - Apple Watch remote

extension CameraModel {
    func watchShutter() {
        Task {
            switch mode {
            case .look:
                await lockLook()
            case .shoot:
                if (try? await shoot()) != nil { WatchBridge.shared.sendEvent(WatchMessage.captured) }
            case .museum:
                if saveMuseumLook() != nil { WatchBridge.shared.sendEvent(WatchMessage.locked) }
            }
        }
    }

    func watchRecord(_ on: Bool) {
        Task {
            if on {
                if mode != .shoot { mode = .shoot }
                await startRecording()
            } else if (try? await stopRecording()) != nil {
                WatchBridge.shared.sendEvent(WatchMessage.captured)
            }
        }
    }

    func watchIntensity(_ value: Float) {
        intensity = min(max(value, 0), 1)
    }

    func watchStep(_ delta: Int) {
        let styles = library.styles
        guard !styles.isEmpty else { return }
        let current = selectedStyleID.flatMap { id in styles.firstIndex { $0.id == id } } ?? 0
        selectedStyleID = styles[(current + delta + styles.count) % styles.count].id
        if mode != .shoot { mode = .shoot }
    }
}

struct CameraView: View {
    @Environment(AppModel.self) private var app
    @Environment(StyleLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let initialStyleID: UUID?

    @State private var model: CameraModel?
    @State private var holdProgress: CGFloat = 0
    @State private var holdTask: Task<Void, Never>?
    @State private var toast: String?
    @State private var showPicker = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var shutterTask: Task<Void, Never>?
    @State private var holdFired = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model {
                content(model)
            }
        }
        .statusBarHidden()
        .task {
            if model == nil { model = CameraModel(library: library, initialStyleID: initialStyleID) }
            await model?.start()
        }
        .onDisappear { model?.stop() }
    }

    @ViewBuilder
    private func content(_ model: CameraModel) -> some View {
        @Bindable var model = model
        ZStack {
            MetalImageView(store: model.pipeline.frameStore, fill: .fill)
                .ignoresSafeArea()
                .gesture(holdGesture(model))
            Color.white.opacity(model.flash ? 0.55 : 0).ignoresSafeArea().allowsHitTesting(false)

            if model.access == .denied {
                deniedView
            }

            VStack {
                topBar(model)
                Spacer()
                bottomBar(model)
            }
        }
        .toast($toast)
        .sheet(item: $model.pendingLook) { pending in
            NameStyleSheet(pending: pending) { saved in
                if let saved { model.didSaveLook(saved) } else { model.didDiscardLook() }
            }
            .environment(app)
            .environment(library)
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: model.shutterCount)
        .sensoryFeedback(.success, trigger: model.pendingLook?.id) { _, new in new != nil }
        .sensoryFeedback(.success, trigger: model.museumMatch?.artwork.id) { _, new in new != nil }
        .photosPicker(isPresented: $showPicker, selection: $pickedItem, matching: .any(of: [.images, .videos, .screenshots, .livePhotos]), preferredItemEncoding: .current)
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            pickedItem = nil
            Task {
                do {
                    let media = try await MediaLoader.load(item)
                    if model.mode == .shoot, let id = model.selectedStyleID, let style = library.style(id: id) {
                        app.openEditor(style: style, media: media)
                    } else {
                        try await model.useReference(media)
                    }
                } catch {
                    toast = error.localizedDescription
                }
            }
        }
    }

    private func topBar(_ model: CameraModel) -> some View {
        HStack {
            circleButton("xmark") { dismiss() }
                .accessibilityLabel("Close")
            Spacer()
            Picker("Mode", selection: Binding(get: { model.mode }, set: { model.mode = $0 })) {
                ForEach(CameraModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 250)
            .disabled(model.isRecording)
            Spacer()
            circleButton("arrow.triangle.2.circlepath.camera") { model.pipeline.flip() }
                .accessibilityLabel("Switch camera")
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func bottomBar(_ model: CameraModel) -> some View {
        VStack(spacing: 18) {
            switch model.mode {
            case .look:
                Text(model.isCapturing ? "Reading Style DNA…" : "Point at a screen, poster or scene.\nHold to lock the look.")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.6), radius: 6)
                HStack {
                    sideButton("photo.on.rectangle.angled", label: "Photos") { showPicker = true }
                    Spacer()
                    holdButton(model)
                    Spacer()
                    sideButton("circle.hexagongrid.circle", label: "Blend") { openBlend() }
                        .disabled(library.styles.count < 2)
                }
                .padding(.horizontal, 36)
            case .museum:
                museumPanel(model)
            case .shoot:
                styleStrip(model)
                if let started = model.recordingStarted {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        let secs = Int(context.date.timeIntervalSince(started))
                        Label(String(format: "%d:%02d", secs / 60, secs % 60), systemImage: "record.circle")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.85), in: Capsule())
                    }
                } else {
                    Text(model.isSavingVideo ? "Saving video…" : "Tap to shoot · hold for video")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                }
                HStack {
                    sideButton("photo.on.rectangle", label: "Edit Photo") { showPicker = true }
                        .disabled(model.isRecording)
                    Spacer()
                    shutterButton(model)
                    Spacer()
                    Color.clear.frame(width: 52, height: 52)
                }
                .padding(.horizontal, 36)
            }
        }
        .padding(.bottom, 28)
        .padding(.top, 20)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private func shutterButton(_ model: CameraModel) -> some View {
        ZStack {
            Circle()
                .strokeBorder(model.isRecording ? Color.red : .white, lineWidth: 4)
                .frame(width: 80, height: 80)
            RoundedRectangle(cornerRadius: model.isRecording ? 8 : 32, style: .continuous)
                .fill(model.isRecording ? Color.red : .white)
                .frame(width: model.isRecording ? 32 : 64, height: model.isRecording ? 32 : 64)
                .scaleEffect(model.isCapturing ? 0.85 : 1)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: model.isRecording)
        .contentShape(Circle())
        .opacity(model.selectedStyleID == nil || model.isSavingVideo ? 0.4 : 1)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard shutterTask == nil, !model.isCapturing, !model.isSavingVideo, model.selectedStyleID != nil else { return }
                    // Holding past the threshold starts a video; a quick tap shoots a photo.
                    holdFired = false
                    shutterTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        if Task.isCancelled { return }
                        holdFired = true
                        await model.startRecording()
                    }
                }
                .onEnded { _ in
                    guard let task = shutterTask else { return }
                    shutterTask = nil
                    if holdFired {
                        Task {
                            await task.value // recording may still be starting
                            do {
                                try await model.stopRecording()
                                toast = "Video saved to Photos"
                            } catch {
                                toast = error.localizedDescription
                            }
                        }
                    } else {
                        task.cancel()
                        Task {
                            do {
                                try await model.shoot()
                                toast = "Saved to Photos"
                            } catch {
                                toast = error.localizedDescription
                            }
                        }
                    }
                }
        )
        .accessibilityLabel("Shutter")
        .accessibilityHint("Tap to take a photo, hold to record video")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { Task { try? await model.shoot() } }
    }

    @ViewBuilder
    private func museumPanel(_ model: CameraModel) -> some View {
        if let match = model.museumMatch {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    if let thumb = match.thumbnail {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 58, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(match.artwork.title)
                            .font(.system(size: 19, weight: .semibold, design: .serif))
                        Text("\(match.artwork.artist), \(match.artwork.date)")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                        Label("\(match.artwork.museum), \(match.artwork.city)", systemImage: "building.columns")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
                Button {
                    if let saved = model.saveMuseumLook() {
                        toast = "“\(saved.name)” added to your styles"
                    }
                } label: {
                    Label("Save This Look", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(16)
            .echoGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "building.columns")
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                Text(model.museumReady
                     ? "Point at a painting.\nEcho recognises \(model.museumCount) masterpieces on device."
                     : "Preparing the collection…")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white.opacity(0.9))
            .shadow(color: .black.opacity(0.6), radius: 6)
            .padding(.bottom, 20)
        }
    }

    private func sideButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .echoGlass(Circle(), interactive: true)
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .buttonStyle(.plain)
    }

    private func openBlend() {
        app.cover = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            app.sheet = .blend
        }
    }

    private func holdButton(_ model: CameraModel) -> some View {
        ZStack {
            Circle().fill(.clear).frame(width: 84, height: 84).echoGlass(Circle())
            Circle()
                .trim(from: 0, to: holdProgress)
                .stroke(Theme.waveGradient, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 84, height: 84)
            Image(systemName: model.isCapturing ? "sparkles" : "camera.aperture")
                .font(.system(size: 30, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, isActive: model.isCapturing)
        }
        .gesture(holdGesture(model))
        .accessibilityLabel("Hold to capture look")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { Task { await model.lockLook() } }
    }

    private func holdGesture(_ model: CameraModel) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard model.mode == .look, holdTask == nil, !model.isCapturing else { return }
                holdTask = Task { @MainActor in
                    let steps = 30
                    for i in 1...steps {
                        try? await Task.sleep(nanoseconds: 700_000_000 / UInt64(steps))
                        if Task.isCancelled { return }
                        holdProgress = CGFloat(i) / CGFloat(steps)
                    }
                    await model.lockLook()
                    withAnimation { holdProgress = 0 }
                }
            }
            .onEnded { _ in
                holdTask?.cancel()
                holdTask = nil
                if !model.isCapturing { withAnimation(.easeOut(duration: 0.2)) { holdProgress = 0 } }
            }
    }

    private func styleStrip(_ model: CameraModel) -> some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(library.styles) { style in
                        let selected = model.selectedStyleID == style.id
                        Button {
                            withAnimation(.spring(response: 0.3)) { model.selectedStyleID = style.id }
                        } label: {
                            VStack(spacing: 6) {
                                Group {
                                    if let ref = library.reference(for: style) {
                                        Image(uiImage: ref).resizable().scaledToFill()
                                    } else if let preview = library.preview(for: style) {
                                        Image(uiImage: preview).resizable().scaledToFill()
                                    } else {
                                        DNASwatch(dna: style.dna)
                                    }
                                }
                                .frame(width: 56, height: 56)
                                .clipShape(Circle())
                                .overlay(Circle().strokeBorder(selected ? Theme.accent : .white.opacity(0.6), lineWidth: selected ? 3 : 1.5))
                                .scaleEffect(selected ? 1.08 : 1)
                                Text(style.name)
                                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                    .foregroundStyle(.white.opacity(selected ? 1 : 0.7))
                                    .lineLimit(1)
                                    .frame(width: 76)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .sensoryFeedback(.selection, trigger: model.selectedStyleID)

            HStack(spacing: 12) {
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(.white.opacity(0.7))
                Slider(value: Binding(get: { Double(model.intensity) }, set: { model.intensity = Float($0) }), in: 0...1)
                    .tint(Theme.accent)
                Text("\(Int(model.intensity * 100))")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 34)
            }
            .padding(.horizontal, 28)
        }
    }

    private var deniedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.system(size: 36, design: .rounded)).foregroundStyle(Theme.secondaryText)
            Text("Camera access is off").font(.system(size: 20, weight: .semibold, design: .rounded))
            Text("Allow camera access in Settings to capture looks live.")
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(32)
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .echoGlass(Circle(), interactive: true)
        }
    }
}
