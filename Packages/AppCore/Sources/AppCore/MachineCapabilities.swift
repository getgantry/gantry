import Foundation
#if canImport(Virtualization)
import Virtualization
#endif

/// Host-side pre-flight checks for `container machine` settings, mirroring the
/// checks apple/container 1.1 runs before it accepts `--virtualization`.
///
/// Gantry asks the same question the CLI does so the UI can disable an option
/// the machine can never boot with, instead of surfacing the failure only after
/// the image has been pulled.
public enum MachineCapabilities {
    /// Whether this Mac can run a VM with nested virtualization enabled.
    /// Apple silicon M3 or newer on macOS 15+.
    public static var supportsNestedVirtualization: Bool {
        #if canImport(Virtualization)
        return VZGenericPlatformConfiguration.isNestedVirtualizationSupported
        #else
        return false
        #endif
    }

    /// Why the nested-virtualization option is unavailable, or nil when it is.
    public static var nestedVirtualizationUnavailableReason: String? {
        supportsNestedVirtualization
            ? nil
            : "This Mac can't run nested virtualization (it needs Apple silicon M3 or newer on macOS 15+)."
    }

    /// Whether `path` points at a Unix domain socket. Bind-mounting one into a
    /// container works for non-root containers as of apple/container 1.1.
    public static func isUnixSocket(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var status = stat()
        guard stat(path, &status) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFSOCK
    }
}
