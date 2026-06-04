import SwiftUI
import AppCore

@main
struct GantryApp: App {
    @State private var model = AppModel()

    /// Whether the menu-bar panel is shown. Bound to the system menu bar item.
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1180, height: 740)
        .commands {
            // Gantry is not a document-based app; drop "New" from the File menu.
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Docker") {
                Button("Refresh All") {
                    NotificationCenter.default.post(name: .gantryRefreshAll, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("New Container…") {
                    NotificationCenter.default.post(name: .gantryNewContainer, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("Prune System…") {}
                    .disabled(true)
            }
        }

        MenuBarExtra("Gantry", systemImage: "shippingbox.fill", isInserted: $showMenuBarExtra) {
            MenuBarView()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
