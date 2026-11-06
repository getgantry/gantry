import Foundation

/// Helps the Machines and Clusters sections explain a failed listing.
public enum MachineAvailability {
    /// True when the `container` binary comes from Homebrew. The Homebrew
    /// bottle has no machine API server, so `container machine` cannot work;
    /// the signed installer (``ContainerTooling/installerPageURL``) has it.
    public static func isHomebrewCLI(path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return [path, resolved].contains { candidate in
            candidate.contains("/Cellar/")
                || candidate.hasPrefix("/opt/homebrew/")
                || candidate.hasPrefix("/home/linuxbrew/")
        }
    }

    /// Whether the `container` CLI that a host uses is a Homebrew install.
    public static func isHomebrewCLI(cliOverride: String?) -> Bool {
        guard let path = AppleContainerControl.cliPath(override: cliOverride) else { return false }
        return isHomebrewCLI(path: path)
    }
}
