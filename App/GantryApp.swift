import SwiftUI
import AppKit
import AppCore
import Sparkle

@main
struct GantryApp: App {
    @State private var model = AppModel()

    /// Sparkle auto-updater; starts checking per Info.plist (SUFeedURL,
    /// SUEnableAutomaticChecks) as soon as the app launches.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// Whether the menu-bar panel is shown. Bound to the system menu bar item.
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    /// Whether the app appears in the Dock. Off switches the activation
    /// policy to `.accessory` (menu-bar-only app).
    @AppStorage("showDockIcon") private var showDockIcon = true

    /// Preferred app appearance: "system", "light", or "dark".
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(model)
                .onAppear {
                    applyAppearance(appearance)
                    applyActivationPolicy()
                }
                .onChange(of: appearance) { _, newValue in
                    applyAppearance(newValue)
                }
                .onChange(of: showDockIcon) {
                    // The app must stay reachable: no Dock icon requires the
                    // menu bar icon.
                    if !showDockIcon { showMenuBarExtra = true }
                    applyActivationPolicy()
                }
                .onChange(of: showMenuBarExtra) {
                    if !showMenuBarExtra { showDockIcon = true }
                }
        }
        .defaultSize(width: 1180, height: 740)
        .commands {
            // Gantry is not a document-based app; drop "New" from the File menu.
            CommandGroup(replacing: .newItem) {}

            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }

            CommandMenu("Docker") {
                Button("Refresh All") {
                    NotificationCenter.default.post(name: .gantryRefreshAll, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("New Container…") {
                    NotificationCenter.default.post(name: .gantryNewContainer, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        // Standalone host shell windows (one per open request).
        WindowGroup(id: "hostTerminal", for: UUID.self) { $hostID in
            HostTerminalWindow(hostID: hostID)
                .environment(model)
        }
        .defaultSize(width: 840, height: 520)

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

    /// Applies the Dock-visibility preference. `.accessory` removes the app
    /// from the Dock and the Cmd-Tab switcher while keeping its windows.
    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        // Switching to accessory deactivates the app; bring it back so an
        // open window does not vanish behind other apps.
        if !showDockIcon {
            NSApp.activate(ignoringOtherApps: true)
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

/// "Check for Updates…" menu item that stays enabled/disabled in sync with
/// the Sparkle updater state.
private struct CheckForUpdatesView: View {
    let updater: SPUUpdater
    @State private var canCheck = true

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!canCheck)
        .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
    }
}

