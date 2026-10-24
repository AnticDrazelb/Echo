import SwiftUI

@main
struct EchoApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(app)
                .environment(app.library)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onOpenURL { app.handle(url: $0) }
        }
    }
}
