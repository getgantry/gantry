import SwiftUI
import AppCore

/// Shown when a CLI listing (machines, clusters) failed, so the section does
/// not claim "No Machines" and offer Create when it could not list at all.
struct ListingUnavailableView: View {
    let title: String
    let systemImage: String
    let reason: String
    /// True for a Homebrew `container`, which has no machine API server.
    let installerHint: Bool
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            description
        } actions: {
            actions
        }
    }

    private var description: some View {
        VStack(spacing: 8) {
            Text(reason)
                .textSelection(.enabled)
                .lineLimit(6)
            if installerHint {
                Text("The Homebrew build of apple/container has no machine API server. Install the signed package from Apple to use machines.")
            } else {
                Text("Make sure that the apple/container services are running (System ▸ Overview), then try again.")
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Try Again") {
            Task { await retry() }
        }
        .buttonStyle(.borderedProminent)
        if installerHint {
            Link(destination: ContainerTooling.installerPageURL) {
                Label("Download Installer…", systemImage: "arrow.down.circle")
            }
        }
    }
}
