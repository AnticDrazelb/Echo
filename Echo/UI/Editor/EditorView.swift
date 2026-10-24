import SwiftUI

struct EditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(StyleLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: EditorModel

    @State private var showExport = false
    @State private var panelExpanded = true
    @State private var exportError: String?

    var body: some View {
        @Bindable var app = app
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                CompareView(model: model)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .frame(maxHeight: .infinity)
                controls
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(model: model)
                .environment(app)
                .presentationDetents([.medium, .large])
                .presentationBackground(Theme.surface)
                .presentationCornerRadius(30)
        }
        .toast($app.toast)
        .onDisappear { model.tearDown() }
        .onChange(of: model.demoShowExport) { _, show in if show { showExport = true } }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Menu {
                ForEach(library.styles) { style in
                    Button {
                        withAnimation { model.switchStyle(to: style) }
                    } label: {
                        if style.id == model.style.id {
                            Label(style.name, systemImage: "checkmark")
                        } else {
                            Text(style.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    DNASwatch(dna: model.style.dna)
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
                    Text(model.style.name)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                }
                .foregroundStyle(.white)
                .padding(.leading, 6)
                .padding(.trailing, 14)
                .frame(height: 40)
                .echoGlass(Capsule(), interactive: true)
            }
            Spacer()
            if model.isVideo {
                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .echoGlass(Circle(), interactive: true)
                }
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            }
        }
    }

    // MARK: Bottom panel

    private var controls: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.22))
                .frame(width: 44, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { togglePanel() }
                .gesture(DragGesture(minimumDistance: 8).onEnded { g in
                    if (g.translation.height > 20) == panelExpanded { togglePanel() }
                })
                .accessibilityLabel(panelExpanded ? "Collapse controls" : "Expand controls")
                .accessibilityAddTraits(.isButton)

            VStack(alignment: .leading, spacing: 16) {
                Text("Intensity")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .padding(.top, 6)
                IntensitySlider(value: $model.settings.intensity)

                if panelExpanded {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
                        Chip(title: "Color", systemImage: "paintpalette.fill", isOn: model.settings.color) {
                            model.settings.color.toggle()
                        }
                        Chip(title: "Light", systemImage: "sun.max", isOn: model.settings.light) {
                            model.settings.light.toggle()
                        }
                        Chip(title: "Grain", systemImage: "circle.dotted", isOn: model.settings.grain) {
                            model.settings.grain.toggle()
                        }
                        Chip(title: "Optics", systemImage: "camera.aperture", isOn: model.settings.optics) {
                            model.settings.optics.toggle()
                        }
                        ForEach(StyleRegion.allCases) { region in
                            let selected = model.region == region
                            let excluded = selected && model.regionExcluded
                            Chip(
                                title: excluded ? "No \(region.title)" : region.title,
                                systemImage: excluded ? "minus.circle" : nil,
                                isOn: selected,
                                tint: excluded ? Color(red: 0.75, green: 0.2, blue: 0.3) : Theme.accentDeep,
                                isLoading: region != .auto && model.masksLoading && selected
                            ) {
                                withAnimation(.easeOut(duration: 0.2)) { model.tapRegion(region) }
                            }
                            .accessibilityHint(region == .auto ? "Applies everywhere" : "Tap to apply only here, tap again to protect it")
                            .disabled(!model.isRegionAvailable(region))
                            .opacity(model.isRegionAvailable(region) ? 1 : 0.35)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    if !model.isVideo {
                        relightRow
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    blendRow
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.horizontal, 20)

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button {
                    showExport = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .frame(width: 22)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!model.isReady)
                .accessibilityLabel("More export options")
                Button {
                    Task {
                        do {
                            try await model.quickSave()
                        } catch is CancellationError {
                            // Cancelled from the Live Activity.
                        } catch {
                            exportError = error.localizedDescription
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        switch model.saveState {
                        case .idle:
                            Text("Export")
                        case .saving:
                            ProgressView().tint(.white)
                            Text(model.isVideo ? "\(Int(model.exportProgress * 100))%" : "Saving")
                                .monospacedDigit()
                        case .saved:
                            Image(systemName: "checkmark")
                            Text("Saved")
                        }
                    }
                    .frame(minWidth: 118)
                }
                .buttonStyle(PrimaryButtonStyle(color: model.saveState == .saved ? Color.green.opacity(0.85) : Theme.accent))
                .disabled(!model.isReady || model.saveState == .saving)
                .sensoryFeedback(.success, trigger: model.saveState) { _, new in new == .saved }
                .animation(.spring(response: 0.3), value: model.saveState)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.black.opacity(0.18))
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1)
                )
                .ignoresSafeArea(edges: .bottom)
        )
        .alert("Couldn't export", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private func togglePanel() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { panelExpanded.toggle() }
    }

    /// Light › Relight: uses the photo's depth to match the reference's key light.
    private var relightRow: some View {
        Toggle(isOn: $model.settings.relight.animation()) {
            HStack(spacing: 10) {
                Image(systemName: "light.max")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Relight")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(model.hasDepth
                         ? "Uses depth to match the reference's light direction"
                         : "Needs a photo with depth (Portrait mode or LiDAR)")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .tint(Theme.accent)
        .disabled(!model.hasDepth || !model.settings.light)
    }

    /// Mix up to two more looks into the current one.
    private var blendRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "circle.hexagongrid.circle")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.violet)
                Text("Blend")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Spacer()
                if model.blendParts.count < EditorModel.maxBlendParts {
                    Menu {
                        ForEach(library.styles.filter { s in
                            s.id != model.style.id && !model.blendParts.contains { $0.style.id == s.id }
                        }) { style in
                            Button(style.name) { withAnimation { model.addBlend(style) } }
                        }
                    } label: {
                        Label(model.isBlending ? "Add another" : "Add a look", systemImage: "plus")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(Theme.surfaceRaised, in: Capsule())
                    }
                }
            }
            if model.isBlending {
                blendSlider(name: model.style.name, dna: model.style.dna, weight: $model.mainWeight, onRemove: nil)
                ForEach($model.blendParts) { $part in
                    blendSlider(name: part.style.name, dna: part.style.dna, weight: $part.weight) {
                        withAnimation { model.removeBlend(part) }
                    }
                }
            }
        }
    }

    private func blendSlider(name: String, dna: StyleDNA, weight: Binding<Float>, onRemove: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            DNASwatch(dna: dna).frame(width: 16, height: 16).clipShape(Circle())
            Text(name)
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)
            Slider(value: weight, in: 0.05...1)
                .tint(Theme.violet)
                .accessibilityLabel("\(name) share")
            Text("\(Int((model.share(of: weight.wrappedValue) * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(name)")
            } else {
                Color.clear.frame(width: 17, height: 1)
            }
        }
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .foregroundStyle(Theme.secondaryText)
    }
}

// MARK: - Compare

/// Before/after split with a draggable divider.
struct CompareView: View {
    @Bindable var model: EditorModel
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let size = fittedSize(in: geo.size)
            ZStack {
                MetalImageView(store: model.frameStore)
                    .frame(width: size.width, height: size.height)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay { overlays(size: size) }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragging = true
                                model.split = min(max(value.location.x / size.width, 0), 1)
                            }
                            .onEnded { _ in dragging = false }
                    )
                if !model.isReady {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("Reading your shot…")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: dragging)
    }

    private func fittedSize(in container: CGSize) -> CGSize {
        let ratio = model.aspectRatio
        guard container.width > 0, container.height > 0 else { return .zero }
        if container.width / container.height > ratio {
            return CGSize(width: container.height * ratio, height: container.height)
        }
        return CGSize(width: container.width, height: container.width / ratio)
    }

    private func overlays(size: CGSize) -> some View {
        let x = model.split * size.width
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.85))
                .frame(width: 3, height: size.height)
                .shadow(color: .black.opacity(0.4), radius: 3)
                .position(x: x, y: size.height / 2)
            Circle()
                .fill(Color(white: 0.62))
                .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                .frame(width: dragging ? 58 : 52, height: dragging ? 58 : 52)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                .position(x: x, y: size.height * 0.52)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dragging)

            label("Original")
                .position(x: 52, y: size.height - 28)
                .opacity(model.split > 0.18 ? 1 : 0)
            label("Echo")
                .position(x: size.width - 40, y: size.height - 28)
                .opacity(model.split < 0.82 ? 1 : 0)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: model.split > 0.18)
        .animation(.easeOut(duration: 0.15), value: model.split < 0.82)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .shadow(color: .black.opacity(0.6), radius: 4)
    }
}

// MARK: - Intensity slider

struct IntensitySlider: View {
    @Binding var value: Float
    @State private var isDragging = false

    /// Haptic detents at 0, 50 and 100.
    private var detent: Int? {
        let pct = Int((value * 100).rounded())
        return [0, 50, 100].contains(pct) ? pct : nil
    }

    var body: some View {
        HStack(spacing: 14) {
            Text("0")
                .font(.system(size: 16, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
            GeometryReader { geo in
                let width = geo.size.width
                let knob: CGFloat = 34
                let x = CGFloat(value) * (width - knob) + knob / 2
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 8)
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(x, 8), height: 8)
                    Circle()
                        .fill(.white)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                        .scaleEffect(isDragging ? 1.1 : 1)
                        .position(x: x, y: geo.size.height / 2)
                    Text("\(Int((value * 100).rounded()))")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .position(x: min(max(x - 22, 18), width - 18), y: -16)
                }
                .frame(height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            isDragging = true
                            var v = Float(min(max((g.location.x - knob / 2) / max(width - knob, 1), 0), 1))
                            if abs(v - 0.5) < 0.015 { v = 0.5 } // gentle magnet at 50
                            value = v
                        }
                        .onEnded { _ in isDragging = false }
                )
                .animation(.spring(response: 0.2, dampingFraction: 0.75), value: isDragging)
            }
            .frame(height: 36)
            Text("100")
                .font(.system(size: 16, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.top, 14)
        .sensoryFeedback(.impact(weight: .medium), trigger: detent) { _, new in new != nil }
        .accessibilityElement()
        .accessibilityLabel("Intensity")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(1, value + 0.05)
            case .decrement: value = max(0, value - 0.05)
            @unknown default: break
            }
        }
    }
}
