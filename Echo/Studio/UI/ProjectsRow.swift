import PhotosUI
import SwiftUI

/// Home-screen strip of Studio projects with a "New Project" tile.
struct ProjectsRow: View {
    @Environment(AppModel.self) private var app
    @State private var showPicker = false
    @State private var item: PhotosPickerItem?
    @State private var creating = false
    @State private var deleting: Composition?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Studio")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Layers · Keyframes · FX")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
            }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    Button { showPicker = true } label: {
                        VStack(spacing: 10) {
                            if creating {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "plus")
                                    .font(.system(size: 26, weight: .semibold))
                                    .foregroundStyle(Theme.waveGradient)
                            }
                            Text("New Project")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                        }
                        .frame(width: 120, height: 150)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        )
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(creating)

                    ForEach(app.studio.projects) { comp in
                        Button { app.openStudio(comp) } label: { tile(comp) }
                            .buttonStyle(PressableStyle())
                            .contextMenu {
                                Button { app.studio.duplicate(comp) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                                Button(role: .destructive) { deleting = comp } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .photosPicker(isPresented: $showPicker, selection: $item, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
        .onChange(of: item) { _, picked in
            guard let picked else { return }
            item = nil
            Task { await create(from: picked) }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            Button("Delete Project", role: .destructive) {
                if let deleting { withAnimation { app.studio.delete(deleting) } }
                deleting = nil
            }
        }
    }

    private func tile(_ comp: Composition) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .frame(width: 120, height: 120)
                .overlay {
                    if let thumb = app.studio.thumbnails[comp.id] {
                        Image(uiImage: thumb).resizable().scaledToFill()
                    } else {
                        Theme.surfaceRaised
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    if comp.baseKind == .video {
                        Image(systemName: "video.fill")
                            .font(.system(size: 11, weight: .bold))
                            .padding(6)
                            .background(.black.opacity(0.5), in: Circle())
                            .padding(6)
                    }
                }
            Text(comp.name)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)
        }
    }

    private func create(from picked: PhotosPickerItem) async {
        creating = true
        defer { creating = false }
        let count = app.studio.projects.count + 1
        do {
            let isVideo = picked.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
            let comp: Composition
            if isVideo {
                guard let movie = try await picked.loadTransferable(type: MovieFile.self) else { throw MediaError.unreadable }
                comp = try await app.studio.createVideoProject(url: movie.url, name: "Project \(count)")
            } else {
                guard let data = try await picked.loadTransferable(type: Data.self) else { throw MediaError.unreadable }
                let ext = picked.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                comp = try app.studio.createPhotoProject(data: data, fileExtension: ext, name: "Project \(count)")
            }
            app.openStudio(comp)
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }
}
