import AppKit
import AppCore
import DockerKit

/// Keeps ``StorageMonitor`` up to date with the connected disks, and warns
/// before a disk with running containers is ejected.
@MainActor
final class DiskMountWatcher {
    static let shared = DiskMountWatcher()

    private var observers: [NSObjectProtocol] = []
    private weak var model: AppModel?

    func start(model: AppModel) {
        self.model = model
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DiskMountWatcher.shared.refresh() }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { note in
            let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
            MainActor.assumeIsolated { DiskMountWatcher.shared.willUnmount(path) }
        })
        refresh()
    }

    func refresh() {
        StorageMonitor.shared.presence = .current()
    }

    /// Posts a notification when containers still run from the disk.
    private func willUnmount(_ path: String?) {
        guard let path, let model else { return }
        let name = (path as NSString).lastPathComponent
        var running: [String] = []
        for session in model.sessions where session.usesLocalPaths {
            running += DiskPresence.runningContainers(on: path, in: session.containers).map(\.displayName)
        }
        if model.sessions.contains(where: { $0.host.isAppleContainer }),
           StoragePaths.isInside(AppleDataRootStore.shared.load().effectivePath, path) {
            running.insert(String(localized: "container services"), at: 0)
        }
        guard !running.isEmpty else { return }
        ContainerNotifier.shared.presentFailure(
            title: String(localized: "Stop the containers before you eject “\(name)”"),
            body: String(localized: "These still use the disk: \(running.joined(separator: ", ")).")
        )
    }
}
