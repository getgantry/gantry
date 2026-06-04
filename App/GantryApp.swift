import SwiftUI
import AppCore

@main
struct GantryApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1180, height: 740)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
