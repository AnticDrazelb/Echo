import Foundation
import UniformTypeIdentifiers

/// A saved look in the user's library.
struct Style: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var dna: StyleDNA
    /// Optional @handle credited on export.
    var creator: String?
    var createdAt = Date()
    var isBuiltIn = false
    /// For blends: the recipe that produced it.
    var recipe: [Ingredient]?

    struct Ingredient: Codable, Hashable {
        var name: String
        var weight: Float
    }

    var creditLine: String? {
        guard let creator, !creator.isEmpty else { return nil }
        let handle = creator.hasPrefix("@") ? creator : "@\(creator)"
        return "Style inspired by \(handle)"
    }
}

extension UTType {
    static let echoStyle = UTType(exportedAs: "com.anticdrazelb.echo.style", conformingTo: .data)
}

/// Portable form of a style for Echo Links, AirDrop and files.
/// Contains only Style DNA: never the reference image.
struct SharedStyle: Codable {
    var name: String
    var creator: String?
    var dna: StyleDNA

    init(_ style: Style) {
        name = style.name
        creator = style.creator
        dna = style.dna
    }

    func makeStyle() -> Style {
        Style(name: name, dna: dna, creator: creator)
    }

    // MARK: Encoding

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try encoder.encode(self)
        return try (json as NSData).compressed(using: .zlib) as Data
    }

    static func decode(_ data: Data) throws -> SharedStyle {
        let json = (try? (data as NSData).decompressed(using: .zlib) as Data) ?? data
        let style = try JSONDecoder().decode(SharedStyle.self, from: json)
        guard style.dna.isValid else { throw CocoaError(.fileReadCorruptFile) }
        return style
    }

    /// `echo://style?d=<base64url>`
    func link() throws -> URL {
        let payload = try encoded().base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var components = URLComponents()
        components.scheme = "echo"
        components.host = "style"
        components.queryItems = [URLQueryItem(name: "d", value: payload)]
        guard let url = components.url else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    static func from(url: URL) throws -> SharedStyle {
        if url.isFileURL {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return try decode(Data(contentsOf: url))
        }
        guard url.scheme == "echo",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
              .queryItems?.first(where: { $0.name == "d" })?.value
        else { throw CocoaError(.fileReadUnsupportedScheme) }
        var b64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { throw CocoaError(.fileReadCorruptFile) }
        return try decode(data)
    }

    /// Writes a `.echostyle` file suitable for AirDrop / Files.
    func writeFile() throws -> URL {
        let safe = name.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(safe.isEmpty ? "Style" : safe).echostyle")
        try encoded().write(to: url)
        return url
    }
}
