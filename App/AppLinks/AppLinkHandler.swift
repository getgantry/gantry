import AppKit
import SwiftUI
import AppCore
import DockerKit

extension Notification.Name {
    /// Posted for a `gantry://` link that changes the main window. Object: `AppLink`.
    static let gantryOpenLink = Notification.Name("gantryOpenLink")
    /// Debug builds only: ContentView writes its state as JSON. Object: the file path.
    static let gantryDumpState = Notification.Name("gantryDumpState")
}

/// Runs `gantry://` links (see ``AppLink``). Window changes go to ContentView;
/// debug commands run here.
@MainActor
enum AppLinkHandler {
    static func handle(_ link: AppLink) {
        switch link {
        case .open, .palette, .settings:
            PendingAppLinks.add(link)
            // Cold launch: no window yet; ContentView drains the link on appear.
            NotificationCenter.default.post(name: .gantryOpenLink, object: link)
            MainWindowActivation.activate()
        case .snapshot(let path):
            #if DEBUG
            snapshot(to: URL(fileURLWithPath: path))
            #endif
        case .state(let path):
            #if DEBUG
            NotificationCenter.default.post(name: .gantryDumpState, object: path)
            #endif
        case .appearance(let mode):
            #if DEBUG
            NSApp.appearance = switch mode {
            case "light": NSAppearance(named: .aqua)
            case "dark": NSAppearance(named: .darkAqua)
            default: nil
            }
            #endif
        }
    }

    #if DEBUG
    /// Draws the main window, title bar included, into a PNG. It needs no
    /// screen recording permission, and other windows do not cover it.
    private static func snapshot(to url: URL) {
        guard let window = AppLinkTarget.window, let view = window.contentView?.superview ?? window.contentView else { return }
        // A locked screen or a covered window skips drawing; force it first.
        view.layoutSubtreeIfNeeded()
        window.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    #endif
}

/// Finds the detail item that a link names, by id or by name.
@MainActor
enum AppLinkItem {
    static func detail(_ item: String, section: HostSection, session: HostSession) -> DetailSelection? {
        let wanted = item.lowercased()
        func same(_ value: String) -> Bool { value.lowercased() == wanted }
        switch section {
        case .containers:
            return session.containers.first {
                same($0.id) || $0.id.hasPrefix(item) || same($0.displayName) || $0.names.contains { same($0) || same("/" + item) }
            }.map { .container($0.id) }
        case .images:
            return session.images.first {
                same($0.id) || $0.id.hasPrefix(item) || $0.repoTags.contains { same($0) || $0.lowercased().hasPrefix(wanted + ":") }
            }.map { .image($0.id) }
        case .volumes:
            return session.volumes.first { same($0.name) }.map { .volume($0.name) }
        case .networks:
            return session.networks.first { same($0.id) || same($0.name) }.map { .network($0.id) }
        case .machines:
            return session.machines.first { same($0.id) }.map { .machine($0.id) }
        case .clusters:
            return session.clusters.first { same($0.name) }.map { .cluster($0.name) }
        case .system:
            return .appleSystem(item)
        default:
            return nil
        }
    }
}

/// The main window that links act on: the key window, else the first visible
/// main window. Several main windows can be open; only one must react.
@MainActor
enum AppLinkTarget {
    static var window: NSWindow? {
        let mains = NSApp.windows.filter {
            $0.isVisible && $0.identifier?.rawValue.hasPrefix("main-AppWindow-") == true
        }
        if let key = NSApp.keyWindow, mains.contains(key) { return key }
        return mains.min { ($0.identifier?.rawValue ?? "") < ($1.identifier?.rawValue ?? "") }
    }
}

/// Gives a SwiftUI view its NSWindow. A new view (the split view changes its
/// columns) has no window yet, so report on move and never report nil.
struct WindowReader: NSViewRepresentable {
    let onChange: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
        view.report()
    }

    final class ReaderView: NSView {
        var onChange: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        func report() {
            guard let window else { return }
            let onChange = onChange
            DispatchQueue.main.async { onChange?(window) }
        }
    }
}
