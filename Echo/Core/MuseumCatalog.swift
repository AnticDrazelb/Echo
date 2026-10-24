import CoreImage
import UIKit
import Vision

/// A painting Echo can recognise in Museum Mode.
struct Artwork: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let date: String
    let museum: String
    let city: String
}

/// On-device recognition of well-known public-domain paintings.
///
/// The catalog ships with the app (small reference images + metadata). Each
/// work's Style DNA and Vision feature print are computed on device the first
/// time Museum Mode opens. Camera frames are compared in memory only; nothing
/// from the camera is stored.
final class MuseumCatalog: @unchecked Sendable {
    static let shared = MuseumCatalog()

    struct Entry {
        let artwork: Artwork
        let dna: StyleDNA
        let print: VNFeaturePrintObservation
        let thumbnail: UIImage?
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var loaded = false

    /// Loads (once) and returns the catalog. Call off the main thread.
    func load() -> [Entry] {
        lock.lock()
        if loaded { defer { lock.unlock() }; return entries }
        lock.unlock()

        var built: [Entry] = []
        if let url = Bundle.main.url(forResource: "museum-catalog", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let works = try? JSONDecoder().decode([Artwork].self, from: data) {
            for work in works {
                guard let imageURL = Bundle.main.url(forResource: "museum-\(work.id)", withExtension: "jpg"),
                      let image = CIImage(contentsOf: imageURL),
                      let print = Self.featurePrint(of: image)
                else { continue }
                let dna = StyleAnalyzer.analyze(image, options: .init(ignoreText: false))
                built.append(Entry(artwork: work, dna: dna, print: print, thumbnail: UIImage(contentsOfFile: imageURL.path)))
            }
        }
        lock.lock()
        entries = built
        loaded = true
        lock.unlock()
        return built
    }

    static func featurePrint(of image: CIImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFit
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try? handler.perform([request])
        return request.results?.first
    }

    /// Best match for a camera frame, or nil when nothing is clearly a match.
    /// Scale-free test: the winner must be well below the catalog's median
    /// distance and clearly ahead of the runner-up.
    func match(_ frame: CIImage) -> Entry? {
        let entries = load()
        guard entries.count >= 3 else { return nil }
        let ext = frame.extent
        // Paintings are usually framed in the middle of the viewfinder.
        let crop = ext.insetBy(dx: ext.width * 0.12, dy: ext.height * 0.12)
        guard let print = Self.featurePrint(of: frame.cropped(to: crop).normalizedToOrigin()) else { return nil }

        var scored: [(Entry, Float)] = []
        for entry in entries {
            var d: Float = 0
            if (try? print.computeDistance(&d, to: entry.print)) != nil { scored.append((entry, d)) }
        }
        guard scored.count >= 3 else { return nil }
        scored.sort { $0.1 < $1.1 }
        let best = scored[0].1, second = scored[1].1
        let median = scored[scored.count / 2].1
        guard best < median * 0.72, best < second * 0.86 else { return nil }
        return scored[0].0
    }
}
