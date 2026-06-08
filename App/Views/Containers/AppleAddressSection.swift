import SwiftUI
import AppKit
import AppCore
import DockerKit

/// apple/container gives every container a routable IP on the Mac, so its
/// services are reachable directly — no port publishing or tunnel needed. This
/// section (shown only for apple hosts) surfaces that address, plus the DNS
/// hostname when the container was launched on a local domain, and makes both
/// one-click openable per exposed port — the OrbStack-style "just open it" flow.
struct AppleAddressSection: View {
    let session: HostSession
    let container: ContainerSummary
    let details: ContainerDetails

    /// Label Gantry stamps at create time recording the `--dns-domain` used, so
    /// the resolvable hostname can be shown reliably here.
    static let domainLabelKey = "com.gantry.dns-domain"

    private var ip: String? {
        let value = details.networkSettings.ipAddress?.trimmingCharacters(in: .whitespaces)
        return (value?.isEmpty == false) ? value : nil
    }

    private var hostname: String? {
        // Prefer the label Gantry stamped; fall back to the domain reported by
        // inspect so containers created outside Gantry resolve too.
        let domain = container.labels[Self.domainLabelKey]
            ?? details.config.domainname
        guard let domain, !domain.isEmpty else { return nil }
        return "\(container.displayName).\(domain)"
    }

    /// All exposed container ports we know about: published ports from the
    /// summary plus any in the inspect network settings, de-duplicated.
    private var ports: [Int] {
        var set = Set<Int>()
        for port in container.ports { set.insert(port.privatePort) }
        for key in details.networkSettings.ports?.keys ?? [:].keys {
            if let n = Int(key.split(separator: "/").first.map(String.init) ?? "") { set.insert(n) }
        }
        return set.sorted()
    }

    var body: some View {
        if session.host.isAppleContainer, ip != nil || hostname != nil {
            DetailSection("Address") {
                VStack(alignment: .leading, spacing: 10) {
                    if let ip {
                        addressRow(systemImage: "network", host: ip)
                    }
                    if let hostname {
                        addressRow(systemImage: "globe", host: hostname)
                    } else if ip != nil {
                        hostnameHint
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func addressRow(systemImage: String, host: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(host)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    copyToPasteboard(host)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
                Spacer()
            }
            if !ports.isEmpty {
                // One chip per exposed port: opens http://host:port directly.
                FlowChips(ports: ports) { port in
                    if let url = URL(string: "http://\(host):\(port)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private var hostnameHint: some View {
        Text("Tip: launch with a DNS domain to also reach it by name, e.g. \(container.displayName).test")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}

/// A wrapping row of tappable port chips ("open :8080").
private struct FlowChips: View {
    let ports: [Int]
    let onOpen: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ports, id: \.self) { port in
                Button {
                    onOpen(port)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "safari").font(.caption2)
                        Text(":\(String(port))").font(.caption.monospacedDigit())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.14), in: .capsule)
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Open http://…:\(String(port)) in your browser")
            }
        }
    }
}
