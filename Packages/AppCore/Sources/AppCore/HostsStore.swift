import Foundation

/// Shared resolver for the persisted `hosts.json` location, used by both the
/// GUI (`AppModel`) and the headless path (`HeadlessDocker`) so they always
/// read and write the same file.
enum HostsStore {
    /// `~/Library/Application Support/Gantry/hosts.json`, or nil if Application
    /// Support cannot be resolved.
    static func fileURL() -> URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return nil
        }
        return appSupport
            .appendingPathComponent("Gantry", isDirectory: true)
            .appendingPathComponent("hosts.json", isDirectory: false)
    }
}
