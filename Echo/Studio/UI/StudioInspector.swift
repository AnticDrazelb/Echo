import SwiftUI

/// Properties of the selected layer: content, transform, mask, effects.
struct StudioInspector: View {
    @Bindable var model: StudioModel
    @Environment(StyleLibrary.self) private var library
    @State private var showEffects = false

    var body: some View {
        if let layer = model.selectedLayer {
            VStack(spacing: 12) {
                layerSection(layer)
                contentSection(layer)
                if !layer.isAdjustment { transformSection(layer) }
                maskSection(layer)
                effectsSection(layer)
            }
            .sheet(isPresented: $showEffects) {
                EffectBrowser { type in
                    model.addEffect(type, to: layer.id)
                    showEffects = false
                }
                .presentationDetents([.medium, .large])
                .presentationBackground(Theme.background)
            }
        } else {
            Text("Select a layer")
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private var t: Double { model.time }

    // MARK: Layer

    private func layerSection(_ layer: Layer) -> some View {
        InspectorSection(title: layer.name, systemImage: layer.icon) {
            HStack {
                Text("Blend").font(.system(size: 14, weight: .medium, design: .rounded))
                Spacer()
                Menu {
                    ForEach(BlendMode.allCases) { mode in
                        Button(mode.title) { model.editLayer(layer.id) { $0.blend = mode } }
                    }
                } label: {
                    Label(layer.blend.title, systemImage: "square.2.layers.3d")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .disabled(layer.isAdjustment || layer.isBase)
            }
            ParamRow(label: "Opacity", range: 0...1, format: pct, value: layer.opacity, time: t) { v in
                model.editLayer(layer.id, key: "opacity") { $0.opacity = v }
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private func contentSection(_ layer: Layer) -> some View {
        if let text = layer.textContent {
            InspectorSection(title: "Text", systemImage: "textformat") {
                TextField("Text", text: Binding(
                    get: { text.text },
                    set: { newValue in model.editLayer(layer.id, key: "text") { $0.textContent?.text = newValue } }
                ), axis: .vertical)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Picker("Font", selection: Binding(
                    get: { text.font },
                    set: { f in model.editLayer(layer.id) { $0.textContent?.font = f } }
                )) {
                    ForEach(TextFont.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Weight").font(.system(size: 14, weight: .medium, design: .rounded))
                    Slider(value: Binding(
                        get: { text.weight },
                        set: { w in model.editLayer(layer.id, key: "weight") { $0.textContent?.weight = w } }
                    ), in: -0.6...0.62)
                }
                ParamRow(label: "Size", range: 0.02...0.5, format: pct, value: text.size, time: t) { v in
                    model.editLayer(layer.id, key: "size") { $0.textContent?.size = v }
                }
                ParamRow(label: "Tracking", range: -0.1...0.5, value: text.tracking, time: t) { v in
                    model.editLayer(layer.id, key: "tracking") { $0.textContent?.tracking = v }
                }
                ParamRow(label: "Shadow", range: 0...1, format: pct, value: text.shadow, time: t) { v in
                    model.editLayer(layer.id, key: "shadow") { $0.textContent?.shadow = v }
                }
                ColorRow(label: "Color", color: text.color, time: t) { c in
                    model.editLayer(layer.id, key: "color") { $0.textContent?.color = c }
                }
            }
        } else if let shape = layer.shapeContent {
            InspectorSection(title: "Shape", systemImage: "square.on.circle") {
                Picker("Kind", selection: Binding(
                    get: { shape.kind },
                    set: { k in model.editLayer(layer.id) { $0.shapeContent?.kind = k } }
                )) {
                    Text("Rectangle").tag(ShapeKind.rectangle)
                    Text("Ellipse").tag(ShapeKind.ellipse)
                }
                .pickerStyle(.segmented)
                ParamRow(label: "Width", range: 0.02...1.5, format: pct, value: shape.width, time: t) { v in
                    model.editLayer(layer.id, key: "w") { $0.shapeContent?.width = v }
                }
                ParamRow(label: "Height", range: 0.02...1.5, format: pct, value: shape.height, time: t) { v in
                    model.editLayer(layer.id, key: "h") { $0.shapeContent?.height = v }
                }
                if shape.kind == .rectangle {
                    ParamRow(label: "Corner Radius", range: 0...0.3, format: pct, value: shape.cornerRadius, time: t) { v in
                        model.editLayer(layer.id, key: "corner") { $0.shapeContent?.cornerRadius = v }
                    }
                }
                ColorRow(label: "Fill", color: shape.color, time: t) { c in
                    model.editLayer(layer.id, key: "fill") { $0.shapeContent?.color = c }
                }
            }
        } else if let color = layer.solidColor {
            InspectorSection(title: "Solid", systemImage: "square.fill") {
                ColorRow(label: "Color", color: color, time: t) { c in
                    model.editLayer(layer.id, key: "solid") { $0.solidColor = c }
                }
            }
        } else if let grad = layer.gradientContent {
            InspectorSection(title: "Gradient", systemImage: "square.lefthalf.filled") {
                ColorRow(label: "From", color: grad.from, time: t) { c in
                    model.editLayer(layer.id, key: "from") { $0.gradientContent?.from = c }
                }
                ColorRow(label: "To", color: grad.to, time: t) { c in
                    model.editLayer(layer.id, key: "to") { $0.gradientContent?.to = c }
                }
                ParamRow(label: "Angle", range: 0...360, format: deg, value: grad.angle, time: t) { v in
                    model.editLayer(layer.id, key: "angle") { $0.gradientContent?.angle = v }
                }
            }
        }
    }

    // MARK: Transform

    private func transformSection(_ layer: Layer) -> some View {
        InspectorSection(title: "Transform", systemImage: "move.3d", trailing: AnyView(presetsMenu(layer))) {
            ParamRow(label: "Position X", range: -0.5...1.5, format: pct, value: layer.transform.x, time: t) { v in
                model.editLayer(layer.id, key: "tx") { $0.transform.x = v }
            }
            ParamRow(label: "Position Y", range: -0.5...1.5, format: pct, value: layer.transform.y, time: t) { v in
                model.editLayer(layer.id, key: "ty") { $0.transform.y = v }
            }
            ParamRow(label: "Scale", range: 0.05...4, format: pct, value: layer.transform.scale, time: t) { v in
                model.editLayer(layer.id, key: "ts") { $0.transform.scale = v }
            }
            ParamRow(label: "Rotation", range: -360...360, format: deg, value: layer.transform.rotation, time: t) { v in
                model.editLayer(layer.id, key: "tr") { $0.transform.rotation = v }
            }
        }
    }

    private func presetsMenu(_ layer: Layer) -> some View {
        Menu {
            ForEach(StudioModel.Preset.allCases) { preset in
                Button { model.apply(preset, to: layer.id) } label: { Label(preset.rawValue, systemImage: preset.icon) }
            }
        } label: {
            Label("Animate", systemImage: "wand.and.stars")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
    }

    // MARK: Mask

    private func maskSection(_ layer: Layer) -> some View {
        let mask = layer.mask
        return InspectorSection(title: "Mask", systemImage: "circle.dashed.inset.filled", trailing: AnyView(
            Menu {
                ForEach(MaskKind.allCases) { kind in
                    Button(kind.title) { model.editLayer(layer.id) { $0.mask.kind = kind } }
                        .disabled(!maskAvailable(kind))
                }
            } label: {
                Text(mask.kind.title).font(.system(size: 13, weight: .semibold, design: .rounded))
            }
        )) {
            if mask.kind != .none {
                Toggle("Invert", isOn: Binding(
                    get: { mask.inverted },
                    set: { v in model.editLayer(layer.id) { $0.mask.inverted = v } }
                ))
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .tint(Theme.accent)
            }
            switch mask.kind {
            case .ellipse, .rectangle:
                maskParam(layer, "Center X", \.x, -0.2...1.2)
                maskParam(layer, "Center Y", \.y, -0.2...1.2)
                maskParam(layer, "Width", \.width, 0.02...1.6)
                maskParam(layer, "Height", \.height, 0.02...1.6)
                maskParam(layer, "Feather", \.feather, 0...1)
            case .linear:
                maskParam(layer, "Center X", \.x, -0.2...1.2)
                maskParam(layer, "Center Y", \.y, -0.2...1.2)
                maskParam(layer, "Angle", \.angle, 0...360, format: deg)
                maskParam(layer, "Softness", \.feather, 0...1)
            case .luminance:
                maskParam(layer, "Low", \.low, 0...1)
                maskParam(layer, "High", \.high, 0...1)
            default:
                EmptyView()
            }
        }
    }

    private func maskAvailable(_ kind: MaskKind) -> Bool {
        switch kind {
        case .sky: model.assets.sky != nil
        case .skin: model.assets.skin != nil
        case .subject: model.assets.subject != nil
        default: true
        }
    }

    private func maskParam(_ layer: Layer, _ label: String, _ path: WritableKeyPath<LayerMask, AnimatableValue>, _ range: ClosedRange<Double>, format: @escaping (Double) -> String = pct) -> some View {
        ParamRow(label: label, range: range, format: format, value: layer.mask[keyPath: path], time: t) { v in
            model.editLayer(layer.id, key: "mask-\(label)") { $0.mask[keyPath: path] = v }
        }
    }

    // MARK: Effects

    private func effectsSection(_ layer: Layer) -> some View {
        InspectorSection(title: "Effects", systemImage: "fx", trailing: AnyView(
            Button { showEffects = true } label: {
                Label("Add", systemImage: "plus").font(.system(size: 13, weight: .semibold, design: .rounded))
            }
        )) {
            if layer.effects.isEmpty {
                Text(layer.isAdjustment ? "Effects here change every layer below." : "Add glow, blur, glitch, grain and more.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(layer.effects) { effect in
                effectRow(effect, layer: layer)
            }
        }
    }

    private func effectRow(_ effect: Effect, layer: Layer) -> some View {
        let expanded = model.selectedEffectID == effect.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: effect.type.icon)
                    .frame(width: 22)
                    .foregroundStyle(effect.isEnabled ? Theme.violet : .white.opacity(0.3))
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { model.selectedEffectID = expanded ? nil : effect.id }
                } label: {
                    HStack {
                        Text(effect.type.title)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(effect.isEnabled ? .white : .white.opacity(0.4))
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .buttonStyle(.plain)
                Toggle("", isOn: Binding(
                    get: { effect.isEnabled },
                    set: { v in model.editEffect(layer: layer.id, effect: effect.id) { $0.isEnabled = v } }
                ))
                .labelsHidden()
                .tint(Theme.violet)
                Menu {
                    Button { model.moveEffect(effect.id, in: layer.id, by: -1) } label: { Label("Move Up", systemImage: "arrow.up") }
                    Button { model.moveEffect(effect.id, in: layer.id, by: 1) } label: { Label("Move Down", systemImage: "arrow.down") }
                    Button(role: .destructive) { model.removeEffect(effect.id, from: layer.id) } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.white.opacity(0.6))
                }
            }
            if expanded {
                if effect.type == .look {
                    Menu {
                        ForEach(library.styles) { style in
                            Button(style.name) { model.setLook(style, effect: effect.id, layer: layer.id) }
                        }
                    } label: {
                        Label(effect.styleName ?? "Choose a look", systemImage: "sparkles")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                }
                if effect.type == .duotone {
                    duotoneRows(effect, layer: layer)
                }
                ForEach(effect.type.params.filter { $0.unit != .color } + [ParamSpec.mix], id: \.key) { spec in
                    ParamRow(
                        label: spec.label, range: spec.min...spec.max, format: spec.format,
                        value: effect.params[spec.key] ?? AnimatableValue(spec.defaultValue), time: t
                    ) { v in
                        model.editEffect(layer: layer.id, effect: effect.id, key: spec.key) { $0.params[spec.key] = v }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func duotoneRows(_ effect: Effect, layer: Layer) -> some View {
        func color(_ i: Int) -> AnimatableColor {
            var c = AnimatableColor(0, 0, 0)
            c.r = effect.params["r\(i)"] ?? AnimatableValue(0)
            c.g = effect.params["g\(i)"] ?? AnimatableValue(0)
            c.b = effect.params["b\(i)"] ?? AnimatableValue(0)
            return c
        }
        return VStack(spacing: 10) {
            ForEach(0..<2, id: \.self) { i in
                ColorRow(label: i == 0 ? "Shadows" : "Highlights", color: color(i), time: t) { c in
                    model.editEffect(layer: layer.id, effect: effect.id, key: "duo\(i)") { e in
                        e.params["r\(i)"] = c.r
                        e.params["g\(i)"] = c.g
                        e.params["b\(i)"] = c.b
                    }
                }
            }
        }
    }
}

private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
private func deg(_ v: Double) -> String { "\(Int(v.rounded()))°" }

/// Grid of all effects by category.
struct EffectBrowser: View {
    let onPick: (EffectType) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(EffectCategory.allCases) { category in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(category.rawValue)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                                ForEach(EffectType.allCases.filter { $0.category == category }) { type in
                                    Button { onPick(type) } label: {
                                        VStack(spacing: 8) {
                                            Image(systemName: type.icon)
                                                .font(.system(size: 22, weight: .medium))
                                                .foregroundStyle(Theme.waveGradient)
                                            Text(type.title)
                                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                                .multilineTextAlignment(.center)
                                                .lineLimit(2)
                                                .foregroundStyle(.white)
                                        }
                                        .frame(maxWidth: .infinity, minHeight: 84)
                                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    }
                                    .buttonStyle(PressableStyle())
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Add Effect")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
