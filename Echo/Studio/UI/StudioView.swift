import PhotosUI
import SwiftUI

struct StudioView: View {
    @Environment(AppModel.self) private var app
    @Environment(StyleLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: StudioModel

    enum Tab: String, CaseIterable { case layers = "Layers", inspector = "Inspector" }
    @State private var tab: Tab = .layers
    @State private var showImagePicker = false
    @State private var imageItem: PhotosPickerItem?
    @State private var renaming = false
    @State private var nameDraft = ""
    @State private var exportError: String?

    // Gesture baselines
    @State private var dragStart: (Double, Double)?
    @State private var scaleStart: Double?
    @State private var rotationStart: Double?

    var body: some View {
        @Bindable var app = app
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 10) {
                topBar
                canvas
                    .padding(.horizontal, 14)
                    .frame(maxHeight: .infinity)
                TimelineBar(model: model)
                    .padding(.horizontal, 16)
                panel
            }
            if model.isExporting {
                exportOverlay
            }
        }
        .toast($app.toast)
        .photosPicker(isPresented: $showImagePicker, selection: $imageItem, matching: .images)
        .onChange(of: imageItem) { _, item in
            guard let item else { return }
            imageItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { model.addImage(data: data) }
                tab = .inspector
            }
        }
        .alert("Rename Project", isPresented: $renaming) {
            TextField("Name", text: $nameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") { model.rename(nameDraft) }
        }
        .alert("Couldn't export", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(exportError ?? "") }
        .onAppear { if model.demoInspector { tab = .inspector } }
        .onDisappear { model.close() }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 38, height: 38)
                    .echoGlass(Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")

            Button {
                nameDraft = model.comp.name
                renaming = true
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.comp.name)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text("\(model.comp.layers.count) layers · \(String(format: "%.1f", model.comp.duration))s")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .accessibilityLabel("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .accessibilityLabel("Redo")

            Menu {
                Button {
                    Task {
                        do { try await model.exportVideo(); app.toast = "Video saved to Photos" }
                        catch is CancellationError {}
                        catch { exportError = error.localizedDescription }
                    }
                } label: { Label("Render Video", systemImage: "film") }
                Button {
                    Task {
                        do { try await model.exportStill(); app.toast = "Frame saved to Photos" }
                        catch { exportError = error.localizedDescription }
                    }
                } label: { Label("Save This Frame", systemImage: "photo") }
                if model.comp.baseKind == .photo {
                    Divider()
                    Menu("Duration") {
                        ForEach([3.0, 5, 6, 8, 10, 15, 30], id: \.self) { d in
                            Button("\(Int(d)) seconds") { model.setDuration(d) }
                        }
                    }
                }
            } label: {
                Text("Export")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .background(Theme.accent, in: Capsule())
            }
        }
        .font(.system(size: 17, weight: .semibold))
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let size = fitted(geo.size)
            ZStack {
                MetalImageView(store: model.frameStore)
                    .frame(width: size.width, height: size.height)
                    .background(Color(white: 0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(selectionOverlay(size: size))
                    .gesture(transformGesture(size: size))
                if !model.isReady {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func fitted(_ container: CGSize) -> CGSize {
        let ratio = max(model.canvasAspect, 0.1)
        guard container.width > 0, container.height > 0 else { return .zero }
        if container.width / container.height > ratio {
            return CGSize(width: container.height * ratio, height: container.height)
        }
        return CGSize(width: container.width, height: container.width / ratio)
    }

    /// A crosshair at the selected layer's anchor.
    @ViewBuilder
    private func selectionOverlay(size: CGSize) -> some View {
        if let layer = model.selectedLayer, !layer.isAdjustment {
            let x = layer.transform.x.at(model.time) * size.width
            let y = layer.transform.y.at(model.time) * size.height
            ZStack {
                Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5).frame(width: 22, height: 22)
                Circle().fill(Theme.accent).frame(width: 6, height: 6)
            }
            .position(x: x, y: y)
            .allowsHitTesting(false)
            .shadow(color: .black.opacity(0.5), radius: 3)
        }
    }

    /// Drag to move, pinch to scale, twist to rotate the selected layer.
    private func transformGesture(size: CGSize) -> some Gesture {
        let drag = DragGesture(minimumDistance: 2)
            .onChanged { g in
                guard let layer = model.selectedLayer, !layer.isAdjustment else { return }
                let t = model.time
                if dragStart == nil { dragStart = (layer.transform.x.at(t), layer.transform.y.at(t)) }
                guard let start = dragStart else { return }
                let nx = start.0 + g.translation.width / max(size.width, 1)
                let ny = start.1 + g.translation.height / max(size.height, 1)
                model.editLayer(layer.id, key: "drag") { l in
                    l.transform.x.set(nx, at: t)
                    l.transform.y.set(ny, at: t)
                }
            }
            .onEnded { _ in dragStart = nil }
        let pinch = MagnifyGesture()
            .onChanged { g in
                guard let layer = model.selectedLayer, !layer.isAdjustment else { return }
                let t = model.time
                if scaleStart == nil { scaleStart = layer.transform.scale.at(t) }
                let s = max(0.05, (scaleStart ?? 1) * g.magnification)
                model.editLayer(layer.id, key: "pinch") { $0.transform.scale.set(s, at: t) }
            }
            .onEnded { _ in scaleStart = nil }
        let twist = RotateGesture()
            .onChanged { g in
                guard let layer = model.selectedLayer, !layer.isAdjustment else { return }
                let t = model.time
                if rotationStart == nil { rotationStart = layer.transform.rotation.at(t) }
                let r = (rotationStart ?? 0) + g.rotation.degrees
                model.editLayer(layer.id, key: "twist") { $0.transform.rotation.set(r, at: t) }
            }
            .onEnded { _ in rotationStart = nil }
        return drag.simultaneously(with: pinch.simultaneously(with: twist))
    }

    // MARK: Panel

    private var panel: some View {
        VStack(spacing: 10) {
            Picker("Panel", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            ScrollView {
                Group {
                    switch tab {
                    case .layers: layersList
                    case .inspector: StudioInspector(model: model)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .frame(height: 330)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26, style: .continuous)
                .fill(Theme.surface)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var layersList: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Layers").font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Menu {
                    Button { model.addAdjustment(); tab = .inspector } label: { Label("Adjustment Layer", systemImage: "slider.horizontal.3") }
                    Button { model.addText(); tab = .inspector } label: { Label("Text", systemImage: "textformat") }
                    Button { model.addShape(.rectangle); tab = .inspector } label: { Label("Rectangle", systemImage: "square") }
                    Button { model.addShape(.ellipse); tab = .inspector } label: { Label("Ellipse", systemImage: "circle") }
                    Button { model.addGradient(); tab = .inspector } label: { Label("Gradient", systemImage: "square.lefthalf.filled") }
                    Button { model.addSolid(); tab = .inspector } label: { Label("Solid", systemImage: "square.fill") }
                    Button { showImagePicker = true } label: { Label("Image", systemImage: "photo.on.rectangle") }
                    Divider()
                    Menu("Quick Looks") {
                        Button { model.addAdjustment(with: .look); tab = .inspector } label: { Label("Echo Look", systemImage: "sparkles") }
                        Button { model.addAdjustment(with: .glow); tab = .inspector } label: { Label("Dreamy Glow", systemImage: "sun.max.fill") }
                        Button { model.addAdjustment(with: .glitch); tab = .inspector } label: { Label("Glitch", systemImage: "rectangle.split.3x1") }
                        Button { model.addAdjustment(with: .shake); tab = .inspector } label: { Label("Handheld Shake", systemImage: "iphone.radiowaves.left.and.right") }
                        Button { model.addAdjustment(with: .lightLeak); tab = .inspector } label: { Label("Light Leak", systemImage: "light.max") }
                    }
                } label: {
                    Label("Add Layer", systemImage: "plus")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Theme.accent.opacity(0.2), in: Capsule())
                }
            }
            ForEach(model.comp.layers.reversed()) { layer in
                layerRow(layer)
            }
        }
    }

    private func layerRow(_ layer: Layer) -> some View {
        let selected = model.selectedLayerID == layer.id
        return HStack(spacing: 12) {
            Button {
                model.editLayer(layer.id) { $0.isVisible.toggle() }
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.isVisible ? .white.opacity(0.8) : .white.opacity(0.3))
                    .frame(width: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(layer.isVisible ? "Hide \(layer.name)" : "Show \(layer.name)")

            Image(systemName: layer.icon)
                .frame(width: 30, height: 30)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(layer.name).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1)
                Text(layerSubtitle(layer))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            if !layer.isBase {
                Menu {
                    Button { model.moveLayer(layer.id, by: 1) } label: { Label("Bring Forward", systemImage: "arrow.up") }
                    Button { model.moveLayer(layer.id, by: -1) } label: { Label("Send Backward", systemImage: "arrow.down") }
                    Button { model.duplicateLayer(layer.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Button(role: .destructive) { model.deleteLayer(layer.id) } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 30, height: 30)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.22) : Theme.surfaceRaised.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.selectedLayerID = layer.id
            tab = .inspector
        }
        .onTapGesture {
            model.selectedLayerID = layer.id
            model.selectedEffectID = nil
        }
    }

    private func layerSubtitle(_ layer: Layer) -> String {
        var parts: [String] = []
        if layer.blend != .normal { parts.append(layer.blend.title) }
        let op = layer.opacity.at(model.time)
        if op < 0.995 { parts.append("\(Int(op * 100))%") }
        if !layer.effects.isEmpty { parts.append("\(layer.effects.count) fx") }
        if layer.mask.kind != .none { parts.append("Mask: \(layer.mask.kind.title)") }
        var animated = false
        layer.visitValues { if $0.isAnimated { animated = true } }
        if animated { parts.append("Animated") }
        return parts.isEmpty ? (layer.isAdjustment ? "Adjustment" : "Normal") : parts.joined(separator: " · ")
    }

    private var exportOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView(value: model.exportProgress).tint(Theme.accent).frame(width: 220)
                Text("Rendering \(Int(model.exportProgress * 100))%")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Button("Cancel") { ExportCancellation.cancelAll() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(26)
            .echoGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}
