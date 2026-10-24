import PhotosUI
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(StyleLibrary.self) private var library

    @State private var applyTarget: Style?
    @State private var showApplyPicker = false
    @State private var applyItem: PhotosPickerItem?

    @State private var showReferencePicker = false
    @State private var referenceItem: PhotosPickerItem?

    @State private var busyMessage: String?
    @State private var renaming: Style?
    @State private var renameText = ""
    @State private var deleting: Style?
    @State private var shareFile: ShareItem?

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        @Bindable var app = app
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    EchoHeader { newStyleMenu }
                    if library.styles.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(library.styles) { style in
                                card(style)
                            }
                        }
                    }
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .photosPicker(isPresented: $showApplyPicker, selection: $applyItem, matching: .any(of: [.images, .videos, .livePhotos]), preferredItemEncoding: .current)
            .sheet(item: $shareFile) { item in
                ActivityView(items: item.items).presentationDetents([.medium, .large])
            }

            if let busyMessage {
                BusyOverlay(message: busyMessage)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: busyMessage)
        .toast($app.toast)
        .photosPicker(isPresented: $showReferencePicker, selection: $referenceItem, matching: .any(of: [.images, .videos, .screenshots, .livePhotos]), preferredItemEncoding: .current)
        .onChange(of: applyItem) { _, item in
            guard let item, let style = applyTarget else { return }
            applyItem = nil
            Task { await openEditor(style: style, item: item) }
        }
        .onChange(of: referenceItem) { _, item in
            guard let item else { return }
            referenceItem = nil
            Task { await extractStyle(from: item) }
        }
        .fullScreenCover(item: $app.cover) { cover in
            switch cover {
            case .editor(let model):
                EditorView(model: model)
                    .environment(app)
                    .environment(library)
            case .camera(let initial):
                CameraView(initialStyleID: initial)
                    .environment(app)
                    .environment(library)
            }
        }
        .sheet(item: $app.sheet) { sheet in
            Group {
                switch sheet {
                case .naming(let pending):
                    NameStyleSheet(pending: pending)
                case .importing(let shared):
                    ImportStyleSheet(shared: shared)
                case .blend:
                    BlendView()
                case .details(let style):
                    StyleDetailSheet(style: style)
                }
            }
            .environment(app)
            .environment(library)
        }
        .alert("Rename Style", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let renaming { library.rename(renaming, to: renameText) }
                renaming = nil
            }
        }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Style", role: .destructive) {
                if let deleting { withAnimation(.spring) { library.remove(deleting) } }
                deleting = nil
            }
        } message: {
            Text("This removes the look from your library. Photos you've already exported keep it.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.errorMessage ?? "")
        }
    }

    // MARK: Pieces

    /// Opens the capture screen: live camera plus Photos picker and Blend.
    private var newStyleMenu: some View {
        Button {
            app.openCamera()
        } label: {
            Text("+ New Style")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(height: 46)
                .echoGlass(Capsule(), interactive: true)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("New Style")
    }

    private func card(_ style: Style) -> some View {
        Button {
            applyTarget = style
            showApplyPicker = true
        } label: {
            StyleCard(style: style)
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            Button { applyTarget = style; showApplyPicker = true } label: {
                Label("Apply to Photo or Video", systemImage: "wand.and.stars")
            }
            Button { app.openCamera(with: style) } label: {
                Label("Shoot with This Look", systemImage: "camera")
            }
            Button { app.sheet = .details(style) } label: {
                Label("Style DNA", systemImage: "waveform.path.ecg")
            }
            Button { app.sheet = .blend } label: {
                Label("Blend Styles", systemImage: "circle.hexagongrid.circle")
            }
            Divider()
            Button { share(style) } label: {
                Label("Share Style", systemImage: "square.and.arrow.up")
            }
            Button { copyLink(style) } label: {
                Label("Copy Echo Link", systemImage: "link")
            }
            Button { exportLUT(style) } label: {
                Label("Export .cube LUT", systemImage: "cube.transparent")
            }
            Divider()
            Button { renameText = style.name; renaming = style } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button { library.duplicate(style) } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) { deleting = style } label: {
                Label("Delete", systemImage: "trash")
            }
        } preview: {
            StyleCard(style: style)
                .frame(width: 280)
                .environment(library)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: applyTarget?.id)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 44, weight: .light, design: .rounded))
                .foregroundStyle(Theme.waveGradient)
            Text("Steal the vibe.")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text("Point your camera at a movie, a poster or a sunset — or pick any photo — and Echo will learn its look.")
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Camera") { app.openCamera() }.buttonStyle(PrimaryButtonStyle())
                Button("Photos") { showReferencePicker = true }.buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, 6)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var footer: some View {
        Label("Styles are analysed on your iPhone. Reference images never leave it.", systemImage: "lock.fill")
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.35))
            .padding(.top, 8)
    }

    // MARK: Actions

    private func openEditor(style: Style, item: PhotosPickerItem) async {
        busyMessage = "Opening…"
        defer { busyMessage = nil }
        do {
            let media = try await MediaLoader.load(item)
            app.openEditor(style: style, media: media)
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    private func extractStyle(from item: PhotosPickerItem) async {
        busyMessage = "Reading Style DNA…"
        defer { busyMessage = nil }
        do {
            let media = try await MediaLoader.load(item)
            let pending = try await StyleExtraction.pending(from: media, origin: .photos)
            app.sheet = .naming(pending)
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    private func share(_ style: Style) {
        do {
            let shared = SharedStyle(style)
            shareFile = ShareItem(items: [try shared.writeFile()])
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    private func copyLink(_ style: Style) {
        if let url = try? SharedStyle(style).link() {
            UIPasteboard.general.url = url
            app.toast = "Echo Link copied"
        }
    }

    private func exportLUT(_ style: Style) {
        Task {
            busyMessage = "Baking LUT…"
            let url = await Task.detached { try? CubeExporter.write(style: style) }.value
            busyMessage = nil
            if let url { shareFile = ShareItem(items: [url]) }
        }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// Bridges UIActivityViewController (AirDrop, Files, Messages…).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct BusyOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(.white)
                Text(message).font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

/// Turns picked media into a pending style.
enum StyleExtraction {
    static func pending(from media: Media, origin: PendingStyle.Origin) async throws -> PendingStyle {
        switch media {
        case .photo(let image):
            let result = await Task.detached(priority: .userInitiated) { () -> (StyleDNA, UIImage?) in
                let preview = image.fitting(longSide: 1600)
                return (StyleAnalyzer.analyze(preview), RenderEngine.shared.uiImage(preview.fitting(longSide: 600)))
            }.value
            return PendingStyle(dna: result.0, reference: result.1, suggestedName: suggestName(for: result.0), origin: origin)
        case .video(let url):
            let frames = await MediaLoader.frames(of: url)
            guard !frames.isEmpty else { throw MediaError.unreadable }
            let result = await Task.detached(priority: .userInitiated) { () -> (StyleDNA, UIImage?) in
                let dnas = frames.map { StyleAnalyzer.analyze($0.fitting(longSide: 1000)) }
                let blended = StyleDNA.blend(dnas.map { ($0, 1) })
                let thumb = RenderEngine.shared.uiImage(frames[frames.count / 2].fitting(longSide: 600))
                return (blended, thumb)
            }.value
            return PendingStyle(dna: result.0, reference: result.1, suggestedName: suggestName(for: result.0), origin: origin)
        }
    }

    /// A friendly default name based on the look's character.
    static func suggestName(for dna: StyleDNA) -> String {
        let mood: String
        if dna.isMonochrome {
            mood = dna.grain > 0.3 ? "Silver" : "Mono"
        } else {
            let mid = SIMD2(dna.zoneTintA[1], dna.zoneTintB[1])
            var hue = atan2f(mid.y, mid.x) * 180 / .pi
            if hue < 0 { hue += 360 }
            let strength = (mid.x * mid.x + mid.y * mid.y).squareRoot()
            if strength < 0.008 {
                mood = dna.chroma > 0.08 ? "Vivid" : "Natural"
            } else {
                switch hue {
                case 0..<35: mood = "Rose"
                case 35..<75: mood = "Amber"
                case 75..<110: mood = "Gold"
                case 110..<170: mood = "Moss"
                case 170..<230: mood = "Teal"
                case 230..<290: mood = "Cobalt"
                case 290..<330: mood = "Violet"
                default: mood = "Crimson"
                }
            }
        }
        let tone: String
        let mean = dna.luminance[8]
        if mean < 0.4 { tone = "Night" } else if dna.luminance[0] > 0.18 { tone = "Fade" } else if dna.contrast > 0.5 { tone = "Punch" } else if dna.grain > 0.35 { tone = "Film" } else { tone = "Light" }
        return "\(mood) \(tone)"
    }
}
