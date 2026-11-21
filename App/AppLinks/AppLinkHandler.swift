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
        case .activity(let path):
            #if DEBUG
            DebugActivity.writeSummary(to: URL(fileURLWithPath: path))
            #endif
        case .menuBarSnapshot(let path):
            #if DEBUG
            DebugActivity.snapshotMenuBar(to: URL(fileURLWithPath: path))
            #endif
        case .debugPull(let reference, let host):
            #if DEBUG
            DebugActivity.startPull(reference, host: host)
            #endif
        case .cancelNewestOperation:
            #if DEBUG
            if let model = LiveFleet.model, let newest = MenuBarActivity(center: model.operations).running.first {
                model.operations.cancel(newest)
            }
            #endif
        case .debugCompose(let action, let project, let host):
            #if DEBUG
            DebugActivity.runCompose(action, project: project, host: host)
            #endif
        case .debugImageSearch(let query, let source, let host, let path):
            #if DEBUG
            DebugActivity.snapshotImageSearch(query, source: source, host: host, to: URL(fileURLWithPath: path))
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

#if DEBUG
/// Debug links for checks of the menu bar activity without clicks.
@MainActor
enum DebugActivity {
    /// The menu bar summary as JSON: the running count and one object per row.
    static func writeSummary(to url: URL) {
        guard let model = LiveFleet.model else { return }
        let activity = MenuBarActivity(center: model.operations)
        func row(_ operation: LongOperation) -> [String: Any] {
            var row: [String: Any] = [
                "kind": operation.kind.rawValue,
                "title": operation.title,
                "state": stateName(operation.state),
                "canCancel": operation.canCancel,
            ]
            row["host"] = operation.hostName
            row["fraction"] = operation.fraction
            row["detail"] = OperationRowText.detail(operation)
            if case .failed(let message) = operation.state { row["error"] = message }
            return row
        }
        let body: [String: Any] = [
            "runningCount": activity.runningCount,
            "hiddenRunning": activity.hiddenRunning,
            "menuBarLabel": MenuBarActivity.menuBarLabel(runningCount: activity.runningCount),
            "running": activity.running.map(row),
            "recent": activity.recent.map(row),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url)
    }

    private static func stateName(_ state: OperationState) -> String {
        switch state {
        case .running: "running"
        case .succeeded: "succeeded"
        case .failed: "failed"
        case .cancelled: "cancelled"
        }
    }

    /// Draws the menu bar panel in a window off screen into a PNG, so the
    /// check needs no click on the menu bar.
    static func snapshotMenuBar(to url: URL) {
        guard let model = LiveFleet.model else { return }
        // The cached display has no window background: without one, the
        // light text of dark mode lands on a clear PNG and cannot be read.
        let hosting = NSHostingView(
            rootView: MenuBarView().environment(model).background(Color(nsColor: .windowBackgroundColor))
        )
        let size = hosting.fittingSize
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        // Let SwiftUI lay out and draw once before the capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            hosting.layoutSubtreeIfNeeded()
            window.display()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            window.orderOut(nil)
        }
    }

    /// Runs a search in a new sheet model, selects the first result, and
    /// draws the sheet off screen into a PNG when the tags are in.
    static func snapshotImageSearch(_ query: String, source: String, host: String?, to url: URL) {
        guard let model = LiveFleet.model,
              let hostID = AppLink.resolveHost(host, in: model.sessions.map { ($0.id, $0.host.name) }),
              let session = model.session(id: hostID) else { return }
        let search = session.makeImageSearchModel()
        search.setSource(source == "registry" ? .registry : .dockerHub)
        search.setQuery(query)
        Task {
            await search.settle()
            if let first = search.results.first { search.select(first) }
            await search.settle()
            let hosting = NSHostingView(
                rootView: ImageSearchSheet(session: session, model: search)
                    .background(Color(nsColor: .windowBackgroundColor))
            )
            let size = hosting.fittingSize
            let window = NSWindow(
                contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = hosting
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(500))
            hosting.layoutSubtreeIfNeeded()
            window.display()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            window.orderOut(nil)
        }
    }

    /// Runs Compose down or Compose pull as the group header buttons do,
    /// without the confirmation.
    static func runCompose(_ action: AppLink.ComposeDebugAction, project: String, host: String?) {
        guard let model = LiveFleet.model,
              let hostID = AppLink.resolveHost(host, in: model.sessions.map { ($0.id, $0.host.name) }),
              let session = model.session(id: hostID) else { return }
        switch action {
        case .down: session.composeDown(project: project)
        case .pull: session.composePull(project: project)
        }
    }

    /// Starts a pull operation as the pull sheet does, without the sheet.
    static func startPull(_ reference: String, host: String?) {
        guard let model = LiveFleet.model,
              let hostID = AppLink.resolveHost(host, in: model.sessions.map { ($0.id, $0.host.name) }),
              let session = model.session(id: hostID) else { return }
        // The same path as Pull in the Search Images sheet: host platform, Activity, menu bar.
        ImagePullOperation.start(reference: reference, platform: session.pullPlatform, session: session)
    }
}
#endif
