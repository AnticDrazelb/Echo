import AVFoundation
import Observation
import SwiftUI

@Observable
@MainActor
final class CameraModel {
    enum Mode: String, CaseIterable { case look = "Capture Look", shoot = "Shoot" }
    enum Access { case unknown, granted, denied }

    let pipeline = CameraPipeline()
    var mode: Mode = .look { didSet { applyStyle() } }
    var access: Access = .unknown
    var selectedStyleID: UUID? { didSet { applyStyle() } }
    var intensity: Float = 1 { didSet { pipeline.setIntensity(intensity) } }
    /// A look captured this session that hasn't been saved yet.
    var pendingLook: PendingStyle?
    var isCapturing = false
    var flash = false
    var shutterCount = 0

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
        applyStyle()
        pipeline.start { ok in
            if !ok { Task { @MainActor in self.access = .denied } }
        }
    }

    func stop() { pipeline.stop() }

    private func applyStyle() {
        if mode == .shoot, let id = selectedStyleID, let style = library.style(id: id) {
            pipeline.setStyle(style.dna)
        } else {
            pipeline.setStyle(nil)
        }
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

    private func flashScreen() {
        flash = true
        withAnimation(.easeOut(duration: 0.35)) { flash = false }
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
            .frame(width: 220)
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
                    .font(.system(size: 15, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.6), radius: 6)
                holdButton(model)
            case .shoot:
                styleStrip(model)
                HStack {
                    Spacer()
                    Button {
                        Task {
                            do {
                                try await model.shoot()
                                toast = "Saved to Photos"
                            } catch {
                                toast = error.localizedDescription
                            }
                        }
                    } label: {
                        ZStack {
                            Circle().strokeBorder(.white, lineWidth: 4).frame(width: 80, height: 80)
                            Circle().fill(.white).frame(width: 64, height: 64)
                                .scaleEffect(model.isCapturing ? 0.85 : 1)
                        }
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(model.isCapturing || model.selectedStyleID == nil)
                    .accessibilityLabel("Take photo")
                    Spacer()
                }
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

    private func holdButton(_ model: CameraModel) -> some View {
        ZStack {
            Circle().fill(.ultraThinMaterial).frame(width: 84, height: 84)
            Circle()
                .trim(from: 0, to: holdProgress)
                .stroke(Theme.waveGradient, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 84, height: 84)
            Image(systemName: model.isCapturing ? "sparkles" : "camera.aperture")
                .font(.system(size: 30, weight: .medium))
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
            Image(systemName: "camera.fill").font(.system(size: 36)).foregroundStyle(Theme.secondaryText)
            Text("Camera access is off").font(.system(size: 20, weight: .semibold))
            Text("Allow camera access in Settings to capture looks live.")
                .font(.system(size: 15))
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
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
    }
}
