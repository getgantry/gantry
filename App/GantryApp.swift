import SwiftUI
import AppKit
import AppCore

@main
struct GantryApp: App {
    @State private var model = AppModel()

    /// Whether the menu-bar panel is shown. Bound to the system menu bar item.
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    /// Preferred app appearance: "system", "light", or "dark".
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(model)
                .onAppear { applyAppearance(appearance) }
                .onChange(of: appearance) { _, newValue in
                    applyAppearance(newValue)
                }
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

    /// Applies the stored appearance preference to the running app. Passing
    /// `nil` lets macOS follow the system setting.
    private func applyAppearance(_ value: String) {
        switch value {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }
}
