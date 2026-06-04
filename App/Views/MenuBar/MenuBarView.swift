import SwiftUI
import AppKit
import AppCore
import DockerKit

/// Compact menu-bar panel summarising every connected host: its running
/// containers (with quick stop/restart), a short list of recently exited
/// containers (with start), and a footer to open the main window.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var connectedSessions: [HostSession] {
        model.sessions.filter { $0.status.isConnected }
    }

    /// Total running containers across all connected hosts, for the footer line.
    private var totalRunning: Int {
        connectedSessions.reduce(0) { $0 + $1.containers.filter { $0.state.isRunning }.count }
    }

    private var totalHosts: Int { connectedSessions.count }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if connectedSessions.isEmpty {
                        emptyState
                    } else {
                        ForEach(connectedSessions) { session in
                            HostBlock(session: session)
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 420)

            Divider()

            footer
        }
        .frame(width: 320)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(.tint)
            Text("Gantry")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No connected hosts")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            Spacer()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(countsSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Open Gantry") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var countsSummary: String {
        guard totalHosts > 0 else { return "No hosts connected" }
        let hostWord = totalHosts == 1 ? "host" : "hosts"
        let runWord = totalRunning == 1 ? "container" : "containers"
        return "\(totalRunning) running \(runWord) · \(totalHosts) \(hostWord)"
    }
}

// MARK: - Per-host block

private struct HostBlock: View {
    var session: HostSession

    private static let runningLimit = 8
    private static let exitedLimit = 3

    private var running: [ContainerSummary] {
        session.containers
            .filter { $0.state.isRunning }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Recently exited containers, most recent first.
    private var recentlyExited: [ContainerSummary] {
        session.containers
            .filter { $0.state == .exited }
            .sorted { $0.created > $1.created }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Host header
            HStack(spacing: 6) {
                Circle()
                    .fill(session.status.dotColor)
                    .frame(width: 7, height: 7)
                Text(session.host.name)
                    .font(.subheadline.weight(.semibold))
                if !session.host.isLocal {
                    Image(systemName: "network")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if running.isEmpty {
                Text("No running containers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 13)
            } else {
                ForEach(running.prefix(Self.runningLimit)) { container in
                    RunningRow(container: container, session: session)
                }
                if running.count > Self.runningLimit {
                    Text("\(running.count - Self.runningLimit) more…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 13)
                }
            }

            if !recentlyExited.isEmpty {
                Text("Recently exited")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .padding(.leading, 13)
                ForEach(recentlyExited.prefix(Self.exitedLimit)) { container in
                    ExitedRow(container: container, session: session)
                }
            }
        }
    }
}

// MARK: - Rows

/// One running container: state dot, name, stop + restart buttons.
private struct RunningRow: View {
    let container: ContainerSummary
    var session: HostSession

    @State private var busy = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(container.state.tint)
                .frame(width: 7, height: 7)
            Text(container.displayName)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)

            ActionButton(systemImage: "stop.fill", help: "Stop", busy: busy) {
                await run(.stop)
            }
            ActionButton(systemImage: "arrow.clockwise", help: "Restart", busy: busy) {
                await run(.restart)
            }
        }
    }

    private func run(_ action: ContainerAction) async {
        busy = true
        _ = await session.perform(action, on: container.id)
        busy = false
    }
}

/// One recently-exited container: state dot, name, start button.
private struct ExitedRow: View {
    let container: ContainerSummary
    var session: HostSession

    @State private var busy = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(container.state.tint)
                .frame(width: 7, height: 7)
            Text(container.displayName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)

            ActionButton(systemImage: "play.fill", help: "Start", busy: busy) {
                busy = true
                _ = await session.perform(.start, on: container.id)
                busy = false
            }
        }
    }
}

/// Small square icon button that shows a spinner while its action runs.
private struct ActionButton: View {
    let systemImage: String
    let help: String
    let busy: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            if busy {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: systemImage)
                    .font(.caption)
                    .frame(width: 14, height: 14)
            }
        }
        .buttonStyle(.borderless)
        .disabled(busy)
        .help(help)
    }
}
