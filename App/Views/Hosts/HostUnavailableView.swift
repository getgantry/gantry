import SwiftUI
import AppCore

/// Stands in for a host section while the host is not connected. It replaces
/// the section (not an overlay), so the section's toolbar actions and its
/// background loads are gone until the connection is back.
struct HostUnavailableView: View {
    let session: HostSession
    let section: HostSection

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(section.title)
    }

    @ViewBuilder
    private var content: some View {
        switch session.status {
        case .connecting:
            ProgressView("Connecting to \(session.host.name)…")
                .controlSize(.large)
        case .failed(let message):
            // A missing disk is the reason, not a broken host.
            unavailable(reason: session.dataRootBlock()?.hostMessage ?? message)
        default:
            if session.dockerNotInstalled {
                dockerMissing
            } else {
                unavailable(reason: String(localized: "Gantry is not connected to this host."))
            }
        }
    }

    private func unavailable(reason: String) -> some View {
        ContentUnavailableView {
            Label("Host Unavailable", systemImage: "bolt.horizontal.circle")
        } description: {
            Text(reason)
        } actions: {
            Button("Retry") {
                Task { await session.connect() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// No Docker socket on this Mac: a neutral state with the next steps.
    private var dockerMissing: some View {
        ContentUnavailableView {
            Label("Docker Not Installed", systemImage: "shippingbox")
        } description: {
            Text("Gantry found no Docker socket (Docker Desktop, OrbStack, Colima, Rancher Desktop or Podman). Install one of them, or remove this host from the sidebar if you only use apple/container.")
        } actions: {
            Button("Check Again") {
                Task { await session.connect() }
            }
        }
    }
}

/// The detail column while the selected item's host is not connected.
struct HostUnavailableDetailView: View {
    var body: some View {
        ContentUnavailableView(
            "Host Unavailable",
            systemImage: "bolt.horizontal.circle",
            description: Text("Connect to the host to see this item.")
        )
    }
}
