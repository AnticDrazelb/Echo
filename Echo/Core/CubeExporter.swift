import Foundation

/// Writes a style as an Adobe/Resolve-compatible `.cube` 3D LUT.
enum CubeExporter {
    static func write(style: Style, source: StyleDNA = .neutral, settings: RenderSettings = RenderSettings(), size: Int = 33) throws -> URL {
        let transfer = StyleTransfer(reference: style.dna, source: source, light: settings.light, color: settings.color)
        let strength = settings.intensity
        var text = """
        TITLE "\(style.name.replacingOccurrences(of: "\"", with: "'"))"
        # Created with Echo — Style DNA color transform
        LUT_3D_SIZE \(size)
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0

        """
        text.reserveCapacity(size * size * size * 28)
        let d = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let input = SIMD3(Float(r) / d, Float(g) / d, Float(b) / d)
                    let mapped = transfer.map(srgb: input)
                    let c = input + (mapped - input) * strength
                    text += String(format: "%.6f %.6f %.6f\n", c.x, c.y, c.z)
                }
            }
        }
        let safe = style.name.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(safe.isEmpty ? "Echo" : safe).cube")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
