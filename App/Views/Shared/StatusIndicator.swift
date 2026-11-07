import SwiftUI
import AppCore
import DockerKit

/// A small status mark that differs in shape as well as colour, so the state
/// does not depend on colour alone.
struct StatusSymbol: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = 8

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: size + 1, height: size + 1)
            .accessibilityHidden(true)
    }
}

extension ConnectionStatus {
    /// Shape of the host status mark: filled, dotted, outlined or a cross.
    var symbolName: String {
        switch self {
        case .connected: "circle.fill"
        case .connecting: "circle.dotted"
        case .failed: "xmark.circle.fill"
        case .disconnected: "circle"
        }
    }
}

extension HostSession {
    /// Short state for VoiceOver and for tooltips, for example "connected".
    var accessibilityStatus: String {
        if dockerNotInstalled { return String(localized: "Docker not installed") }
        switch status {
        case .connected: return String(localized: "connected")
        case .connecting: return String(localized: "connecting")
        case .failed: return String(localized: "unreachable")
        case .disconnected: return String(localized: "disconnected")
        }
    }

    var statusSymbolName: String {
        dockerNotInstalled ? "minus.circle.fill" : status.symbolName
    }
}

/// The host status mark used in the sidebar, the menu bar and the dashboard.
struct HostStatusSymbol: View {
    let session: HostSession
    var size: CGFloat = 8

    var body: some View {
        StatusSymbol(systemName: session.statusSymbolName, tint: session.status.dotColor, size: size)
    }
}

extension ContainerState {
    /// Shape of the container state mark, so that state is not colour only.
    var symbolName: String {
        switch self {
        case .running: "circle.fill"
        case .paused: "pause.circle.fill"
        case .restarting: "arrow.clockwise.circle.fill"
        case .dead: "xmark.circle.fill"
        case .created, .removing, .exited, .unknown: "stop.circle"
        }
    }
}

/// Localized text for a state string that a CLI reports, such as "running".
/// An unknown state shows as the CLI wrote it, capitalized.
enum RuntimeStateText {
    static func label(_ state: String) -> String {
        switch state.lowercased() {
        case "running": String(localized: "Running")
        case "stopped": String(localized: "Stopped")
        case "degraded": String(localized: "Degraded")
        case "starting": String(localized: "Starting")
        case "stopping": String(localized: "Stopping")
        case "created": String(localized: "Created")
        case "exited": String(localized: "Exited")
        case "paused": String(localized: "Paused")
        case "unknown": String(localized: "Unknown")
        default: state.capitalized
        }
    }
}
