import Foundation
import DockerKit

/// Lifecycle of a single host's connection to its Docker daemon.
public enum ConnectionStatus: Sendable, Equatable {
    case disconnected
    case connecting
    case connected(SystemVersion)
    case failed(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var shortDescription: String {
        switch self {
        case .disconnected:
            "Disconnected"
        case .connecting:
            "Connecting…"
        case .connected(let version):
            "Connected (\(version.version), API \(version.apiVersion))"
        case .failed(let message):
            "Failed: \(message)"
        }
    }
}
