import CoreImage
import PhotosUI
import SwiftUI

/// Applies one look to many photos, saving each to Photos, with progress on
/// the Lock Screen / Dynamic Island.
@Observable
@MainActor
final class BatchProcessor {
    private(set) var total = 0
    private(set) var done = 0
    private(set) var failed = 0
    private(set) var isRunning = false
    @ObservationIgnored private var cancelled = false

    var progress: Double { total == 0 ? 0 : Double(done + failed) / Double(total) }

    func cancel() { cancelled = true }

    func run(style: Style, items: [PhotosPickerItem], settings: RenderSettings = RenderSettings()) async -> String {
        guard !items.isEmpty, !isRunning else { return "" }
        total = items.count
        done = 0
        failed = 0
        cancelled = false
        isRunning = true
        defer { isRunning = false }
        let token = ExportCancellation.register { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
        defer { ExportCancellation.unregister(token) }

        let thumb = SampleScene.shared.render(style.dna)
        let activity = ExportActivity(styleName: style.name, kind: "Batch", thumbnail: thumb)
        do {
            try await PhotoSaver.ensureAccess()
        } catch {
            activity.end("Photos access needed")
            return error.localizedDescription
        }
        for item in items {
            if cancelled { break }
            do {
                guard case .photo(let image, _) = try await MediaLoader.load(item) else {
                    failed += 1
                    continue
                }
                let dna = style.dna
                let credit = style.creditLine
                let output = await Task.detached(priority: .userInitiated) { () -> (Data, String)? in
                    let stats = StyleAnalyzer.analyze(image.fitting(longSide: 1024), options: .init(ignoreText: false))
                    var out = StyleRenderer(reference: dna, source: stats).apply(image, settings: settings)
                    if let credit { out = Watermark.apply(credit, to: out) }
                    return RenderEngine.shared.photoData(out)
                }.value
                guard let output else { failed += 1; continue }
                try await PhotoSaver.savePhoto(data: output.0, uti: output.1 == "heic" ? "public.heic" : "public.jpeg")
                done += 1
            } catch {
                failed += 1
            }
            activity.update(progress, detail: "\(done) of \(total) photos")
        }
        let summary: String
        if cancelled {
            summary = "Stopped after \(done) of \(total)"
        } else if failed > 0 {
            summary = "Saved \(done), \(failed) couldn't be processed"
        } else {
            summary = "Saved \(done) photo\(done == 1 ? "" : "s") to Photos"
        }
        activity.end(summary)
        return summary
    }
}

/// In-app progress card for a running batch.
struct BatchOverlay: View {
    let batch: BatchProcessor
    let styleName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Applying \(styleName)")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Spacer()
                Text("\(batch.done + batch.failed)/\(batch.total)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
            }
            ProgressView(value: batch.progress).tint(Theme.accent)
            Button("Cancel", role: .cancel) { batch.cancel() }
                .font(.system(size: 15, weight: .medium, design: .rounded))
        }
        .padding(18)
        .echoGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 20)
    }
}
