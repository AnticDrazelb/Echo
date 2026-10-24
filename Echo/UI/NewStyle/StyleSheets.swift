import SwiftUI

/// Name and save a freshly captured look.
struct NameStyleSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let pending: PendingStyle
    var onComplete: ((Style?) -> Void)?

    @State private var name = ""
    @State private var creator = ""
    @State private var preview: UIImage?
    @State private var saved: Style?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        thumb(pending.reference, label: "Reference")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.secondaryText)
                        thumb(preview, label: "Applied")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Style name", text: $name)
                            .font(.system(size: 22, weight: .semibold))
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .padding(.horizontal, 16)
                            .frame(height: 54)
                            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        TextField("Inspired by @creator (optional)", text: $creator)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 16)
                            .frame(height: 46)
                            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Style DNA").font(.system(size: 17, weight: .semibold))
                        DNAView(dna: pending.dna)
                    }
                    .padding(16)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("New Style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved = app.save(pending, name: base.isEmpty ? pending.suggestedName : base, creator: creator)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear { name = pending.suggestedName }
        .task {
            let dna = pending.dna
            preview = await Task.detached(priority: .userInitiated) { SampleScene.shared.render(dna) }.value
        }
        .onDisappear { onComplete?(saved) }
        .presentationBackground(Theme.background)
    }

    private func thumb(_ image: UIImage?, label: String) -> some View {
        VStack(spacing: 8) {
            Color.clear
                .aspectRatio(0.8, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Theme.surfaceRaised
                            ProgressView().tint(.white)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

/// Confirms installing a style received via Echo Link or AirDrop.
struct ImportStyleSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let shared: SharedStyle
    @State private var preview: UIImage?

    var body: some View {
        VStack(spacing: 20) {
            Capsule().fill(Color.white.opacity(0.2)).frame(width: 40, height: 5).padding(.top, 10)
            Group {
                if let preview {
                    Image(uiImage: preview).resizable().scaledToFill()
                } else {
                    DNASwatch(dna: shared.dna)
                }
            }
            .frame(width: 180, height: 225)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 20, y: 10)

            VStack(spacing: 6) {
                Text(shared.name).font(.system(size: 26, weight: .bold))
                if let creator = shared.creator, !creator.isEmpty {
                    Text("by \(creator.hasPrefix("@") ? creator : "@" + creator)")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            DNAView(dna: shared.dna)
                .padding(16)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Button {
                app.importStyle(shared)
                dismiss()
            } label: {
                Text("Add to My Styles").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .task {
            let dna = shared.dna
            preview = await Task.detached(priority: .userInitiated) { SampleScene.shared.render(dna) }.value
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.background)
    }
}

/// Read-only Style DNA inspector for a saved look.
struct StyleDetailSheet: View {
    @Environment(StyleLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let style: Style

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        if let ref = library.reference(for: style) {
                            image(ref)
                        }
                        if let preview = library.preview(for: style) {
                            image(preview)
                        }
                    }
                    if let recipe = style.recipe {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Blend recipe").font(.system(size: 15, weight: .semibold))
                            ForEach(recipe, id: \.self) { part in
                                HStack {
                                    Text(part.name)
                                    Spacer()
                                    Text("\(Int(part.weight * 100))%").monospacedDigit().foregroundStyle(Theme.secondaryText)
                                }
                                .font(.system(size: 15))
                            }
                        }
                        .padding(16)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    DNAView(dna: style.dna)
                        .padding(16)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    if let credit = style.creditLine {
                        Label(credit, systemImage: "person.crop.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle(style.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationBackground(Theme.background)
    }

    private func image(_ ui: UIImage) -> some View {
        Color.clear
            .aspectRatio(0.8, contentMode: .fit)
            .overlay(Image(uiImage: ui).resizable().scaledToFill())
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
