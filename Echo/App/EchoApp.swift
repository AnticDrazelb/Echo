import SwiftUI

@main
struct EchoApp: App {
    @State private var app = AppModel()

    init() {
        WatchBridge.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(app)
                .environment(app.library)
                .preferredColorScheme(.dark)
                .fontDesign(.rounded)
                .tint(Theme.accent)
                .onOpenURL { app.handle(url: $0) }
        }
    }
}
