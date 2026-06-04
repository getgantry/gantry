import Foundation

/// Shared resolver for the persisted `hosts.json` location, used by both the
/// GUI (`AppModel`) and the headless path (`HeadlessDocker`) so they always
/// read and write the same file.
enum HostsStore {
    /// `~/Library/Application Support/Gantry/hosts.json`, or nil if Application
    /// Support cannot be resolved.
    ///
    /// TEST SEAM: when the `GANTRY_HOSTS_PATH` environment variable is set, that
    /// path is used verbatim instead of the real Application Support location.
    /// This lets the test suite point persistence at a temp file so it never
    /// reads or clobbers the machine's real `hosts.json`. In normal app runs the
    /// variable is unset and behaviour is unchanged.
    static func fileURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["GANTRY_HOSTS_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
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
