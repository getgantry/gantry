import SwiftUI
import AppCore

/// The Clusters section when `container cluster` cannot reach its service:
/// a Homebrew or package install without the cluster plugin, or services
/// that do not run. Offers the installer link or a services restart.
struct ClusterServiceProblemView: View {
    let problem: ClusterServiceProblem
    let session: HostSession

    var body: some View {
        ContentUnavailableView {
            Label(String(localized: "Clusters Unavailable"), systemImage: "steeringwheel")
        } description: {
            VStack(spacing: 8) {
                Text(problem.title)
                Text(problem.advice)
            }
        } actions: {
            ClusterServiceProblemActions(problem: problem, session: session)
        }
    }
}

/// A short notice for the cluster sheets and the list above existing rows.
struct ClusterServiceProblemNotice: View {
    let problem: ClusterServiceProblem
    let session: HostSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(problem.title, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text(problem.advice)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                ClusterServiceProblemActions(problem: problem, session: session)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

/// "Download Installer…" or "Restart Services…", plus "Try Again".
struct ClusterServiceProblemActions: View {
    let problem: ClusterServiceProblem
    let session: HostSession

    @State private var restartAction: DestructiveAction?
    @State private var restarting = false

    var body: some View {
        Group {
            if problem.needsInstaller {
                Link(destination: ClusterServiceProblem.releasesURL) {
                    Label(String(localized: "Download Installer…"), systemImage: "arrow.down.circle")
                }
            } else {
                Button(String(localized: "Restart Services…")) {
                    let running = session.containers.filter { $0.state.isRunning }.count
                    restartAction = .services(.restartServices, runningContainers: running)
                }
                .disabled(restarting)
            }
            Button(String(localized: "Try Again")) {
                Task { await session.refreshClusters() }
            }
            .disabled(restarting)
            if restarting { ProgressView().controlSize(.small) }
        }
        .destructiveConfirmation($restartAction) { _, _ in
            await restart()
        }
    }

    private func restart() async {
        restarting = true
        defer { restarting = false }
        do {
            try await AppleContainerControl.restartServices(cliOverride: session.appleCLIOverride)
        } catch {
            session.lastError = error.localizedDescription
        }
        await session.refreshClusters()
    }
}
