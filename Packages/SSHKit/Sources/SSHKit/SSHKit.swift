import Citadel

/// SSHKit wraps Citadel to provide SSH connections, key loading,
/// ssh_config parsing, and known_hosts validation for Gantry.
public enum SSHKitInfo {
    public static let version = "0.1.0"
}

/// The underlying Citadel client, surfaced so SSHKit consumers can hold the
/// connection factories SSHKit APIs take, without importing Citadel.
public typealias SSHClient = Citadel.SSHClient
