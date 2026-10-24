import ActivityKit
import AppIntents
import Foundation

// Code compiled into both the app and the widget extension.

enum EchoShared {
    static let appGroup = "group.com.anticdrazelb.echo"

    /// Shared container (nil when the build isn't signed with the app group,
    /// e.g. some sideloaded installs; widgets then show a placeholder).
    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Widget", isDirectory: true)
    }

    static var cardsIndex: URL? { container?.appendingPathComponent("cards.json") }

    static func cardImage(_ id: UUID) -> URL? {
        container?.appendingPathComponent("\(id.uuidString).jpg")
    }

    static func openURL(style id: UUID?) -> URL {
        var components = URLComponents()
        components.scheme = "echo"
        components.host = "open"
        if let id { components.queryItems = [URLQueryItem(name: "style", value: id.uuidString)] }
        return components.url ?? URL(string: "echo://open")!
    }
}

/// What the StandBy / home-screen widget shows for each style.
struct WidgetCard: Codable, Hashable, Identifiable {
    let id: UUID
    let name: String
    /// Shadow → highlight colors (sRGB 0...1) for the fallback gradient.
    let swatch: [[Double]]
}

/// Live Activity for long exports (video renders and batch processing).
struct ExportActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var progress: Double
        var detail: String
    }

    var styleName: String
    var kind: String
    /// Tiny JPEG preview (kept well under the Live Activity payload limit).
    var thumbnail: Data?
}

/// Lets the Live Activity's Cancel button reach the running export.
enum ExportCancellation {
    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var handlers: [UUID: () -> Void] = [:]
    }
    private static let store = Store()

    @discardableResult
    static func register(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        store.lock.lock(); store.handlers[id] = handler; store.lock.unlock()
        return id
    }

    static func unregister(_ id: UUID) {
        store.lock.lock(); store.handlers[id] = nil; store.lock.unlock()
    }

    static func cancelAll() {
        store.lock.lock()
        let all = Array(store.handlers.values)
        store.lock.unlock()
        all.forEach { $0() }
    }
}

/// Runs in the app's process when tapped on the Lock Screen / Dynamic Island.
struct CancelExportIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Cancel Export"
    static var description = IntentDescription("Stops the export that's in progress.")

    func perform() async throws -> some IntentResult {
        ExportCancellation.cancelAll()
        return .result()
    }
}
