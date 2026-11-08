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
        let local = model.sessions.filter(\.usesLocalPaths)
        let hasApple = model.sessions.contains { $0.host.isAppleContainer }
        guard let warning = EjectWarning.make(
            mountPoint: path,
            containers: local.flatMap(\.containers),
            dataRoot: hasApple ? AppleDataRootStore.shared.load().effectivePath : nil
        ) else { return }
        ContainerNotifier.shared.presentFailure(title: warning.title, body: warning.body)
    }
}
