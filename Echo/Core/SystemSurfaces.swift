import ActivityKit
import Foundation
import UIKit
import WidgetKit

/// Publishes style cards to the shared container for the StandBy widget.
enum WidgetSync {
    /// Writes card images rendered by the app's Metal pipeline; the widget
    /// itself only displays them, which keeps StandBy cheap on power.
    static func publish(styles: [Style], previews: [UUID: UIImage]) {
        guard let dir = EchoShared.container, let index = EchoShared.cardsIndex else { return }
        let cards = styles.map { style in
            WidgetCard(id: style.id, name: style.name, swatch: DNASwatchColors.rgb(for: style.dna))
        }
        let images = styles.compactMap { style in previews[style.id].map { (style.id, $0) } }
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (id, image) in images {
                guard let url = EchoShared.cardImage(id) else { continue }
                let thumb = image.preparingThumbnail(of: CGSize(width: 480, height: 480 * image.size.height / max(image.size.width, 1))) ?? image
                try? thumb.jpegData(compressionQuality: 0.85)?.write(to: url, options: .atomic)
            }
            // Remove images for deleted styles.
            let keep = Set(styles.map { "\($0.id.uuidString).jpg" })
            if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                for file in files where file.hasSuffix(".jpg") && !keep.contains(file) {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
                }
            }
            if let data = try? JSONEncoder().encode(cards) {
                try? data.write(to: index, options: .atomic)
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

enum DNASwatchColors {
    static func rgb(for dna: StyleDNA) -> [[Double]] {
        (0..<3).map { z in
            let c = Oklab.toSRGBClamped(SIMD3(dna.zoneLuma[z], dna.zoneTintA[z] * 2.2, dna.zoneTintB[z] * 2.2))
            return [Double(c.x), Double(c.y), Double(c.z)]
        }
    }
}

/// Lock Screen + Dynamic Island progress for long exports.
@MainActor
final class ExportActivity {
    private var activity: Activity<ExportActivityAttributes>?
    private var lastSent: Double = -1

    init(styleName: String, kind: String, thumbnail: UIImage?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let thumb = thumbnail?
            .preparingThumbnail(of: CGSize(width: 72, height: 72))?
            .jpegData(compressionQuality: 0.5)
        let attributes = ExportActivityAttributes(
            styleName: styleName, kind: kind,
            thumbnail: (thumb?.count ?? 0) < 3000 ? thumb : nil
        )
        let state = ExportActivityAttributes.ContentState(progress: 0, detail: "Starting…")
        activity = try? Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
    }

    func update(_ progress: Double, detail: String) {
        // Activity updates are budgeted; send meaningful steps only.
        guard let activity, progress - lastSent >= 0.02 || progress >= 1 else { return }
        lastSent = progress
        let state = ExportActivityAttributes.ContentState(progress: progress, detail: detail)
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func end(_ detail: String) {
        guard let activity else { return }
        let state = ExportActivityAttributes.ContentState(progress: lastSent < 0 ? 0 : lastSent, detail: detail)
        Task { await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + 4)) }
        self.activity = nil
    }
}
