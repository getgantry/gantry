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
            String(localized: "Disconnected", bundle: .module)
        case .connecting:
            String(localized: "Connecting…", bundle: .module)
        case .connected(let version):
            String(
                localized: "Connected (\(version.version), API \(version.apiVersion))",
                bundle: .module
            )
        case .failed(let message):
            String(localized: "Failed: \(message)", bundle: .module)
        }
    }
}
