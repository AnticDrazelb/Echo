import SwiftUI

/// Mix up to three looks ("50 / 30 / 20") into a new style.
struct BlendView: View {
    @Environment(AppModel.self) private var app
    @Environment(StyleLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var parts: [Part] = []
    @State private var name = ""
    @State private var preview: UIImage?

    struct Part: Identifiable, Equatable {
        var id: UUID { style.id }
        var style: Style
        var weight: Double
    }

    static let maxParts = 3

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Color.clear
                        .aspectRatio(1.25, contentMode: .fit)
                        .overlay {
                            if let preview {
                                Image(uiImage: preview).resizable().scaledToFill().transition(.opacity)
                            } else {
                                ZStack {
                                    Theme.surface
                                    Text("Pick up to three looks")
                                        .foregroundStyle(Theme.secondaryText)
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .animation(.easeInOut(duration: 0.25), value: preview)

                    if !parts.isEmpty {
                        VStack(spacing: 14) {
                            ForEach($parts) { $part in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        DNASwatch(dna: part.style.dna).frame(width: 18, height: 18).clipShape(Circle())
                                        Text(part.style.name).font(.system(size: 15, weight: .semibold))
                                        Spacer()
                                        Text("\(percent(part))%")
                                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                                            .monospacedDigit()
                                            .foregroundStyle(Theme.accent)
                                    }
                                    Slider(value: $part.weight, in: 0.05...1)
                                }
                            }
                        }
                        .padding(16)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }

                    Text("Ingredients").font(.system(size: 17, weight: .semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                        ForEach(library.styles) { style in
                            let selected = parts.contains { $0.style.id == style.id }
                            Button {
                                toggle(style)
                            } label: {
                                VStack(spacing: 6) {
                                    Color.clear
                                        .aspectRatio(1, contentMode: .fit)
                                        .overlay {
                                            if let image = library.preview(for: style) {
                                                Image(uiImage: image).resizable().scaledToFill()
                                            } else {
                                                DNASwatch(dna: style.dna)
                                            }
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 3)
                                        )
                                        .overlay(alignment: .topTrailing) {
                                            if selected {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.system(size: 20))
                                                    .foregroundStyle(.white, Theme.accent)
                                                    .padding(6)
                                            }
                                        }
                                    Text(style.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                        .foregroundStyle(.white.opacity(selected ? 1 : 0.7))
                                }
                            }
                            .buttonStyle(PressableStyle())
                            .disabled(!selected && parts.count >= Self.maxParts)
                            .opacity(!selected && parts.count >= Self.maxParts ? 0.4 : 1)
                        }
                    }

                    TextField("Blend name", text: $name)
                        .font(.system(size: 18, weight: .semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Blend Styles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(parts.count < 2)
                }
            }
            .sensoryFeedback(.selection, trigger: parts.count)
        }
        .task(id: blendKey) {
            guard !parts.isEmpty else { preview = nil; return }
            try? await Task.sleep(nanoseconds: 120_000_000) // debounce slider drags
            if Task.isCancelled { return }
            let dna = blended
            let image = await Task.detached(priority: .userInitiated) { SampleScene.shared.render(dna) }.value
            if !Task.isCancelled { preview = image }
        }
        .presentationBackground(Theme.background)
    }

    private var total: Double { parts.reduce(0) { $0 + $1.weight } }

    private func percent(_ part: Part) -> Int {
        total > 0 ? Int((part.weight / total * 100).rounded()) : 0
    }

    private var blended: StyleDNA {
        StyleDNA.blend(parts.map { ($0.style.dna, Float($0.weight)) })
    }

    private var blendKey: String {
        parts.map { "\($0.style.id)-\(Int($0.weight * 100))" }.joined(separator: "|")
    }

    private func toggle(_ style: Style) {
        withAnimation(.spring(response: 0.3)) {
            if let i = parts.firstIndex(where: { $0.style.id == style.id }) {
                parts.remove(at: i)
            } else if parts.count < Self.maxParts {
                let defaults = [0.5, 0.3, 0.2]
                parts.append(Part(style: style, weight: defaults[parts.count]))
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = parts.map(\.style.name).prefix(2).joined(separator: " × ")
        var style = Style(name: library.uniqueName(trimmed.isEmpty ? fallback : trimmed), dna: blended)
        style.recipe = parts.map { Style.Ingredient(name: $0.style.name, weight: Float($0.weight / total)) }
        library.add(style)
        app.toast = "“\(style.name)” blended"
        dismiss()
    }
}
