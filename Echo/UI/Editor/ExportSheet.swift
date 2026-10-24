import SwiftUI

struct ExportSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: EditorModel

    @State private var shareItem: ShareItem?
    @State private var errorText: String?


    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Share & Export")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 32, height: 32)
                        .background(Theme.surfaceRaised, in: Circle())
                }
                .accessibilityLabel("Close")
            }

            if model.isBlending {
                Button {
                    let saved = model.saveBlendAsStyle()
                    app.toast = "“\(saved.name)” added to your styles"
                    dismiss()
                } label: {
                    Label("Save Blend as New Style", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(color: Theme.violet))
            }

            VStack(spacing: 0) {
                row(icon: "cube.transparent", title: "Export .cube LUT", subtitle: "For Final Cut, DaVinci Resolve & Premiere") {
                    Task {
                        do { shareItem = ShareItem(items: [try await model.exportLUT()]) } catch { errorText = error.localizedDescription }
                    }
                }
                Divider().overlay(Theme.stroke).padding(.leading, 56)
                row(icon: "dot.radiowaves.left.and.right", title: "Share Style", subtitle: "AirDrop the look — the photo stays with you") {
                    if let url = try? SharedStyle(model.exportStyle).writeFile() { shareItem = ShareItem(items: [url]) }
                }
                Divider().overlay(Theme.stroke).padding(.leading, 56)
                row(icon: "link", title: "Copy Echo Link", subtitle: "Anyone with Echo can install it in one tap") {
                    if let url = try? SharedStyle(model.exportStyle).link() {
                        UIPasteboard.general.url = url
                        app.toast = "Echo Link copied"
                        dismiss()
                    }
                }
            }
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $model.creditEnabled.animation()) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Attribution").font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text("Adds “Style inspired by @creator” to the export")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                if model.creditEnabled {
                    TextField("@creator", text: $model.creditHandle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(16)
            .background(Theme.surfaceRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            if let errorText {
                Text(errorText)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.red.opacity(0.9))
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .sheet(item: $shareItem) { item in
            ActivityView(items: item.items).presentationDetents([.medium, .large])
        }
    }

    private func row(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    Text(subtitle).font(.system(size: 13, design: .rounded)).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
