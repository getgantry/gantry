import SwiftUI
import AppCore
import DockerKit

/// Exposes a container's published port to the internet through a Cloudflare
/// tunnel. Installs `cloudflared` via Homebrew if missing, lets the user pick a
/// quick tunnel (no account) or a named tunnel on their own hostname (requires
/// `cloudflared tunnel login`), then starts the tunnel and shows its public URL.
struct CloudflareShareSheet: View {
    let session: HostSession
    let containerID: String
    let label: String
    let port: PortBinding

    @Environment(\.dismiss) private var dismiss

    @State private var status: CloudflaredTooling.Status?
    @State private var mode: ModeChoice = .quick
    @State private var hostname = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var log: [String] = []
    /// The tunnel once we've kicked it off, so the body can track its status.
    @State private var startedTunnelID: UUID?

    private enum ModeChoice: String, CaseIterable, Identifiable {
        case quick, named
        var id: String { rawValue }
        var title: String { self == .quick ? "Quick" : "Named" }
    }

    private var startedTunnel: CloudflareTunnel? {
        guard let id = startedTunnelID else { return nil }
        return session.cloudflareTunnels.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 520, height: 460)
        .task {
            if status == nil { status = await CloudflaredTooling.check() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 26)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Share via Cloudflare").font(.title2.weight(.semibold))
                Text("Expose port \(String(port.publicPort ?? port.privatePort)) of \(label) to the internet")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if startedTunnelID != nil {
            tunnelProgress
        } else if let status {
            if status.isInstalled {
                configure(status)
            } else {
                installPrompt(status)
            }
        } else {
            ProgressView("Checking cloudflared…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Install prompt

    private func installPrompt(_ status: CloudflaredTooling.Status) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sharing uses Cloudflare's `cloudflared`, which isn't installed yet.")
            if status.brewAvailable {
                Text("Gantry will run `brew install \(CloudflaredTooling.formula)` for you.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Install [Homebrew](https://brew.sh) and run `brew install \(CloudflaredTooling.formula)`, or follow Cloudflare's [download guide](\(CloudflaredTooling.installPageURL.absoluteString)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !log.isEmpty { logView }
            if let failure {
                Label(failure, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.callout)
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: Configure

    private func configure(_ status: CloudflaredTooling.Status) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Tunnel", selection: $mode) {
                ForEach(ModeChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .quick:
                VStack(alignment: .leading, spacing: 6) {
                    Label("No Cloudflare account needed", systemImage: "bolt.fill")
                        .font(.callout.weight(.medium)).foregroundStyle(.tint)
                    Text("Cloudflare hands out a temporary `https://….trycloudflare.com` address. Anyone with the link can reach the port while the tunnel is up.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            case .named:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Route a hostname on a domain in your Cloudflare account to this port. Requires a one-time login.")
                        .font(.callout).foregroundStyle(.secondary)
                    TextField("app.example.com", text: $hostname)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    if status.loggedIn {
                        Label("Logged in to Cloudflare", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else {
                        HStack(spacing: 8) {
                            Label("Not logged in", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                            Button("Log in to Cloudflare…") { Task { await runLogin() } }
                                .controlSize(.small)
                                .disabled(busy)
                        }
                    }
                }
            }

            if !log.isEmpty { logView }
            if let failure {
                Label(failure, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.callout)
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: Tunnel progress

    @ViewBuilder
    private var tunnelProgress: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch startedTunnel?.status {
            case .active(let url):
                Label("Your tunnel is live", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout.weight(.medium))
                HStack(spacing: 8) {
                    Text(url.absoluteString)
                        .font(.callout.monospaced()).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "safari") }
                        .buttonStyle(.borderless).help("Open in browser")
                    Button { copyURL(url) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy URL")
                }
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.callout)
            default:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting tunnel…").foregroundStyle(.secondary)
                }
            }
            if !log.isEmpty { logView }
            Spacer()
        }
        .padding(16)
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(log.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 160)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: log.count) {
                withAnimation { proxy.scrollTo(log.count - 1, anchor: .bottom) }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if busy { ProgressView().controlSize(.small) }
            Spacer()
            Button(startedTunnelID == nil ? "Cancel" : "Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if let status, startedTunnelID == nil {
                if status.isInstalled {
                    Button("Start Sharing") { Task { await start() } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canStart)
                } else if status.brewAvailable {
                    Button("Install cloudflared") { Task { await runInstall() } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                }
            }
        }
        .padding(16)
    }

    private var canStart: Bool {
        guard !busy else { return false }
        switch mode {
        case .quick:
            return true
        case .named:
            return (status?.loggedIn ?? false) && !hostname.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // MARK: - Actions

    private var logSink: @Sendable (String) -> Void {
        { line in Task { @MainActor in log.append(line) } }
    }

    private func runInstall() async {
        busy = true; failure = nil; log.removeAll()
        do {
            try await CloudflaredTooling.install(progress: logSink)
            status = await CloudflaredTooling.check()
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        busy = false
    }

    private func runLogin() async {
        busy = true; failure = nil; log.removeAll()
        do {
            try await CloudflaredTooling.login(progress: logSink)
            status = await CloudflaredTooling.check()
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        busy = false
    }

    private func start() async {
        busy = true; failure = nil; log.removeAll()
        let tunnelMode: CloudflareTunnel.Mode = switch mode {
        case .quick: .quick
        case .named: .named(hostname: hostname.trimmingCharacters(in: .whitespaces))
        }
        let tunnel = await session.startCloudflareTunnel(
            containerID: containerID,
            label: label,
            port: port,
            mode: tunnelMode,
            onLine: logSink
        )
        busy = false
        if let tunnel {
            startedTunnelID = tunnel.id
        } else {
            failure = session.lastError ?? "Could not start the tunnel."
        }
    }

    private func copyURL(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}
