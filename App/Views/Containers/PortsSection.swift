import SwiftUI
import AppKit
import AppCore
import DockerKit

/// The container Overview's "Ports" block. Beyond listing the port mappings it
/// lets you open a published port in the browser and — for SSH hosts, where the
/// port lives on the remote daemon — establish a local forward (auto-picking a
/// free local port, editable) so the remote service opens at `localhost`.
struct PortsSection: View {
    let session: HostSession
    let container: ContainerSummary

    /// The public port currently being acted on, for the inline spinner.
    @State private var busyPort: Int?
    /// Forward whose local port is being edited, plus the field text.
    @State private var editingForward: PortForward?
    @State private var editPortText = ""
    /// The port currently being shared via Cloudflare (drives the sheet).
    @State private var sharingPort: SharablePort?

    /// Identifiable wrapper so a `PortBinding` can drive `.sheet(item:)`.
    private struct SharablePort: Identifiable {
        let id = UUID()
        let port: PortBinding
    }

    private var forwards: [PortForward] {
        session.portForwards.filter { $0.containerID == container.id }
    }

    private var tunnels: [CloudflareTunnel] {
        session.cloudflareTunnels.filter { $0.containerID == container.id }
    }

    var body: some View {
        if !container.ports.isEmpty {
            DetailSection("Ports") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(container.ports, id: \.self) { port in
                        portRow(port)
                    }
                    if !forwards.isEmpty {
                        Divider().padding(.vertical, 2)
                        forwardsList
                    }
                    if !tunnels.isEmpty {
                        Divider().padding(.vertical, 2)
                        CloudflareTunnelsList(session: session, tunnels: tunnels)
                    }
                }
            }
            .alert("Local Port", isPresented: editAlertBinding) {
                TextField("Port", text: $editPortText)
                Button("Apply") { applyEditedPort() }
                Button("Cancel", role: .cancel) { editingForward = nil }
            } message: {
                Text("Forward to a different local port on 127.0.0.1.")
            }
            .sheet(item: $sharingPort) { item in
                CloudflareShareSheet(
                    session: session,
                    containerID: container.id,
                    label: container.displayName,
                    source: .port(item.port)
                )
            }
        }
    }

    // MARK: - Port row

    @ViewBuilder
    private func portRow(_ port: PortBinding) -> some View {
        HStack(spacing: 8) {
            Text(port.display)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            if let publicPort = port.publicPort {
                if busyPort == publicPort {
                    ProgressView().controlSize(.small)
                }
                if session.host.isSSH {
                    Button {
                        forward(publicPort: publicPort, openAfter: false)
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.borderless)
                    .help("Forward this port to localhost")
                }
                Button {
                    open(port)
                } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(.borderless)
                .help("Open in browser")
                Button {
                    sharingPort = SharablePort(port: port)
                } label: {
                    Image(systemName: "cloud")
                }
                .buttonStyle(.borderless)
                .help("Share publicly via Cloudflare")
            }
        }
    }

    // MARK: - Active forwards

    private var forwardsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Forwards")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(forwards) { forward in
                HStack(spacing: 8) {
                    statusDot(forward.status)
                    Text("localhost:\(String(forward.localPort)) → \(String(forward.remotePort))")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    if case .failed(let message) = forward.status {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(message)
                    }
                    Spacer()
                    if forward.status == .active {
                        Button {
                            if let url = forward.localURL { NSWorkspace.shared.open(url) }
                        } label: {
                            Image(systemName: "safari")
                        }
                        .buttonStyle(.borderless)
                        .help("Open in browser")
                        Button {
                            if let url = forward.localURL { copyToPasteboard(url.absoluteString) }
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy URL")
                        Button {
                            editPortText = String(forward.localPort)
                            editingForward = forward
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Change local port")
                    }
                    Button {
                        let id = forward.id
                        Task { await session.stopPortForward(id) }
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Stop forward")
                }
            }
        }
    }

    @ViewBuilder
    private func statusDot(_ status: PortForward.Status) -> some View {
        switch status {
        case .starting:
            ProgressView().controlSize(.mini)
        case .active:
            Circle().fill(.green).frame(width: 8, height: 8)
        case .failed:
            Circle().fill(.red).frame(width: 8, height: 8)
        }
    }

    // MARK: - Actions

    /// Opens a published port. Local/apple hosts publish onto the Mac so they
    /// open directly; SSH hosts forward first, then open `localhost`.
    private func open(_ port: PortBinding) {
        if let url = session.directBrowserURL(for: port) {
            NSWorkspace.shared.open(url)
            return
        }
        if let publicPort = port.publicPort {
            forward(publicPort: publicPort, openAfter: true)
        }
    }

    private func forward(publicPort: Int, openAfter: Bool) {
        Task {
            busyPort = publicPort
            defer { busyPort = nil }
            let result = await session.startPortForward(
                containerID: container.id,
                label: container.displayName,
                remotePort: publicPort
            )
            if openAfter, let result, result.status == .active, let url = result.localURL {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private var editAlertBinding: Binding<Bool> {
        Binding(presence: $editingForward)
    }

    private func applyEditedPort() {
        guard let forward = editingForward, let port = Int(editPortText) else {
            editingForward = nil
            return
        }
        editingForward = nil
        let id = forward.id
        Task { await session.rebindPortForward(id, toLocalPort: port) }
    }
}
