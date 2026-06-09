import SwiftUI
import AppKit
import AppCore
import DockerKit

/// Compact menu-bar panel summarising every connected host: its running
/// containers (open in browser, copy their dns/ip:port, quick stop/restart),
/// a short list of recently exited containers (with start), and a footer to
/// open the main window.
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

    /// CLI path override from a configured apple host, if any.
    private var appleCLIOverride: String? {
        model.sessions.first { $0.host.isAppleContainer }?.host.socketPathOverride
    }

    /// Show the apple/container services strip when an apple host is configured
    /// or the CLI is installed locally.
    private var showsAppleServices: Bool {
        model.sessions.contains { $0.host.isAppleContainer }
            || AppleContainerControl.cliPath() != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if showsAppleServices {
                Divider()
                AppleServicesMenuSection(cliOverride: appleCLIOverride)
            }

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
            // A ScrollView has no intrinsic height, so in a self-sizing
            // MenuBarExtra window it collapses to zero and hides the whole
            // container list. Give it a concrete, content-estimated height
            // (capped, then scrollable) so the rows actually render.
            .frame(height: listHeight)

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
            Text(countsSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
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
        HStack(spacing: 8) {
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings…")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit Gantry")

            Spacer()

            Button("Open Gantry") {
                openMainWindow()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private var countsSummary: String {
        guard totalHosts > 0 else { return "No hosts connected" }
        let hostWord = totalHosts == 1 ? "host" : "hosts"
        return "\(totalRunning) running · \(totalHosts) \(hostWord)"
    }

    /// Estimated height for the host/container list, so the ScrollView never
    /// collapses to zero in the self-sizing menu-bar window. Mirrors HostBlock's
    /// row limits; the result is clamped and the area scrolls past the cap.
    private var listHeight: CGFloat {
        guard !connectedSessions.isEmpty else { return 64 }
        var h: CGFloat = 24 // inner VStack vertical padding (12 top + 12 bottom)
        for (index, session) in connectedSessions.enumerated() {
            if index > 0 { h += 12 } // spacing between host blocks
            h += 24 // host header row
            let running = session.containers.filter { $0.state.isRunning }.count
            if running == 0 {
                h += 20 // "No running containers"
            } else {
                h += CGFloat(min(running, 8)) * 24
                if running > 8 { h += 18 } // "N more…"
            }
            let exited = session.containers.filter { $0.state == .exited }.count
            if exited > 0 {
                h += 20 // "Recently exited" label
                h += CGFloat(min(exited, 3)) * 22
            }
        }
        return min(h, 460)
    }
}

// MARK: - Per-host block

private struct HostBlock: View {
    var session: HostSession
    @Environment(\.openWindow) private var openWindow

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
                if let badge = session.host.badgeSystemImage {
                    Image(systemName: badge)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(verbatim: "\(running.count)/\(session.containers.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("\(running.count) running of \(session.containers.count) containers")
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

/// One running container: state dot, name (jumps to it in the app), its
/// reachable address (tap to copy dns/ip:port), an open-in-browser button when
/// it resolves a URL, and stop + restart buttons.
private struct RunningRow: View {
    let container: ContainerSummary
    var session: HostSession

    @Environment(\.openWindow) private var openWindow
    @State private var busy = false

    /// Best directly-reachable endpoint (apple DNS/IP, or a local published
    /// port). Nil for SSH hosts and not-yet-resolved apple containers.
    private var endpoint: ContainerEndpoint? {
        session.primaryEndpoint(for: container)
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(container.state.tint)
                .frame(width: 7, height: 7)
            Button {
                openContainer()
            } label: {
                Text(container.displayName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help("Open in Gantry")

            Spacer(minLength: 4)

            address

            if let url = endpoint?.url {
                ActionButton(systemImage: "safari", help: "Open in browser", busy: false) {
                    NSWorkspace.shared.open(url)
                }
            }
            ActionButton(systemImage: "stop.fill", help: "Stop", busy: busy) {
                await run(.stop)
            }
            ActionButton(systemImage: "arrow.clockwise", help: "Restart", busy: busy) {
                await run(.restart)
            }
        }
        .contextMenu {
            if let endpoint {
                if let url = endpoint.url {
                    Button("Open in Browser") { NSWorkspace.shared.open(url) }
                }
                Button("Copy Address — \(endpoint.hostPort)") {
                    copyToPasteboard(endpoint.hostPort)
                }
            }
            if let dns = session.dnsHostname(for: container) {
                Button("Copy DNS Name — \(dns)") { copyToPasteboard(dns) }
            }
            Button("Open in Gantry") { openContainer() }
            Divider()
            Button("Stop") { Task { await run(.stop) } }
            Button("Restart") { Task { await run(.restart) } }
            Button("Kill") { Task { await run(.kill) } }
            Divider()
            Button("Copy Container ID") { copyToPasteboard(container.id) }
            Button("Copy as Prompt") { ContainerPromptCopy.run(session: session, container: container) }
        }
        .task(id: container.id) {
            // apple/container exposes a routable IP/DNS only via inspect; fetch it
            // lazily so the address and open-in-browser light up in the menu.
            if session.host.isAppleContainer, session.cachedDetails(for: container.id) == nil {
                _ = await session.details(for: container.id)
            }
        }
    }

    /// A tappable address chip that copies `host:port`. Falls back to the first
    /// published port when no full endpoint resolved (e.g. SSH hosts).
    @ViewBuilder
    private var address: some View {
        if let endpoint {
            Button {
                copyToPasteboard(endpoint.hostPort)
            } label: {
                HStack(spacing: 3) {
                    if endpoint.isDNSName {
                        Image(systemName: "globe").font(.caption2)
                    }
                    // verbatim: avoid SwiftUI localizing the port as "5.002".
                    Text(verbatim: ":\(endpoint.port)")
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy \(endpoint.hostPort)")
        } else if let port = firstPublicPort {
            Text(verbatim: ":\(port)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var firstPublicPort: Int? {
        container.ports.compactMap(\.publicPort).min()
    }

    /// Opens the main window and selects this container in its detail view.
    private func openContainer() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        let jump = ContainerJump(hostID: session.host.id, containerID: container.id)
        // Give a freshly-opened window a beat to subscribe before posting.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            NotificationCenter.default.post(name: .gantrySelectContainer, object: jump)
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
