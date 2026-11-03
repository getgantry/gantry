import AppKit
import Foundation

/// Reopens the primary SwiftUI scene for app-wide callbacks that do not have
/// SwiftUI's `openWindow` environment (Finder and notification delegates).
@MainActor
enum MainWindowActivation {
    static func activate() {
        NSApp.activate(ignoringOtherApps: true)
        guard !NSApp.windows.contains(where: {
            $0.identifier?.rawValue.hasPrefix("main-AppWindow-") == true && $0.isVisible
        }) else { return }

        Task {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try? await NSWorkspace.shared.openApplication(
                at: Bundle.main.bundleURL, configuration: configuration
            )
        }
    }
}

/// Buffers Compose files opened before the main window is ready to receive the
/// `gantryOpenComposeFile` notification (cold launch via Finder). `ContentView`
/// drains it on first appear; live opens go straight through the notification.
@MainActor
enum PendingComposeOpens {
    private(set) static var urls: [URL] = []

    static func add(_ url: URL) { urls.append(url) }

    /// Returns and clears the buffered URLs.
    static func drain() -> [URL] {
        defer { urls.removeAll() }
        return urls
    }
}

/// App delegate handling file opens from Finder ("Open With → Gantry" and the
/// `compose.yml` document type) and the Services / Quick Action provider.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register the Services provider so the Finder Quick Action /
        // right-click → Services entry routes file URLs back to us.
        NSApp.servicesProvider = ComposeServiceProvider()
        NSUpdateDynamicServices()
    }

    /// "Open With → Gantry" / double-click on a registered file: a Dockerfile
    /// goes to the Build Image flow, anything else to Compose Up.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if DockerfileDetector.isDockerfile(url) {
                Self.openDockerfile(url)
            } else {
                Self.openCompose(url)
            }
        }
    }

    /// Routes a file to the Compose Up flow, buffering it for cold launch.
    @MainActor
    static func openCompose(_ url: URL) {
        PendingComposeOpens.add(url)
        NotificationCenter.default.post(name: .gantryOpenComposeFile, object: url)
        MainWindowActivation.activate()
    }

    /// Routes a Dockerfile to the Build Image flow, buffering it for cold launch.
    @MainActor
    static func openDockerfile(_ url: URL) {
        PendingDockerfileOpens.add(url)
        NotificationCenter.default.post(name: .gantryOpenDockerfile, object: url)
        MainWindowActivation.activate()
    }
}

/// Receives files from the Finder Services / Quick Action menu.
final class ComposeServiceProvider: NSObject {
    /// Bound to `NSMessage = "composeUp"` in Info.plist's `NSServices`.
    @objc func composeUp(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            error?.pointee = "No files were provided." as NSString
            return
        }
        Task { @MainActor in
            for url in urls { AppDelegate.openCompose(url) }
        }
    }
}
