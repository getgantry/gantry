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

    @State private var showAssign = false

    /// Label Gantry stamps at create time recording the `--dns-domain` used, so
    /// the resolvable hostname can be shown reliably here. Canonical definition
    /// lives in `HostSession` so the tray menu and create sheets share it.
    static let domainLabelKey = HostSession.dnsDomainLabelKey

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
                    assignButton
                }
            }
            .sheet(isPresented: $showAssign) {
                AssignDomainSheet(session: session, container: container, details: details)
            }
        }
    }

    /// Lets the user assign or change the container's DNS name after the fact.
    /// apple/container fixes the domain at create time, so this recreates the
    /// container — the sheet explains that before confirming.
    private var assignButton: some View {
        Button {
            showAssign = true
        } label: {
            Label(
                hostname == nil ? "Assign DNS Name…" : "Change DNS Name…",
                systemImage: "globe.badge.chevron.backward"
            )
            .font(.callout)
        }
        .buttonStyle(.link)
        .padding(.top, 2)
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

/// Assigns or changes a container's apple/container DNS name after creation.
/// The domain is immutable on a live container, so applying recreates it
/// (preserving image, command, env, ports, binds, restart policy and labels).
struct AssignDomainSheet: View {
    @Bindable var session: HostSession
    let container: ContainerSummary
    let details: ContainerDetails
    @Environment(\.dismiss) private var dismiss

    @State private var domain = ""
    @State private var availableDomains: [String] = []
    @State private var newDomain = ""
    @State private var addingDomain = false
    @State private var isWorking = false
    @State private var statusText: String?
    @State private var errorText: String?

    private var cliOverride: String? { session.host.socketPathOverride }

    /// The domain the container currently resolves on, if any.
    private var currentDomain: String {
        container.labels[HostSession.dnsDomainLabelKey] ?? details.config.domainname ?? ""
    }

    private var resolvedName: String {
        domain.isEmpty ? "" : "\(container.displayName).\(domain)"
    }

    private var hasChange: Bool {
        domain.trimmingCharacters(in: .whitespaces) != currentDomain
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("DNS Name").font(.title2.weight(.semibold))
                Spacer()
            }
            .padding()
            Divider()

            Form {
                Section {
                    if availableDomains.isEmpty {
                        Text("No local domains yet. Add one below to reach this container by name.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Picker("Domain", selection: $domain) {
                            Text("None").tag("")
                            ForEach(availableDomains, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    HStack(spacing: 6) {
                        TextField("Add a domain (e.g. test)", text: $newDomain)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await addDomain() } }
                        Button {
                            Task { await addDomain() }
                        } label: {
                            if addingDomain { ProgressView().controlSize(.small) }
                            else { Image(systemName: "plus.circle.fill") }
                        }
                        .buttonStyle(.borderless)
                        .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty || addingDomain)
                        .help("Create this local domain (requires admin)")
                    }
                } header: {
                    Text("Domain")
                } footer: {
                    if !resolvedName.isEmpty {
                        Text("Reachable as \(resolvedName)").font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Label(
                        "Applying recreates “\(container.displayName)”. Volumes and bind mounts are kept; the container's writable layer is reset.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let statusText {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(statusText).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { Task { await apply() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || !hasChange)
            }
            .padding()
        }
        .frame(width: 460, height: 420)
        .task { await loadDomains(selectCurrent: true) }
    }

    private func loadDomains(selectCurrent: Bool = false) async {
        availableDomains = (try? await AppleContainerControl.listDomains(cliOverride: cliOverride)) ?? []
        if selectCurrent { domain = currentDomain }
    }

    private func addDomain() async {
        let name = newDomain.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        addingDomain = true
        errorText = nil
        defer { addingDomain = false }
        do {
            try await AppleContainerControl.createDomain(name, cliOverride: cliOverride)
            DefaultDNSDomain.setIfUnset(name)
            newDomain = ""
            await loadDomains()
            domain = name
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func apply() async {
        isWorking = true
        errorText = nil
        statusText = "Recreating…"
        defer { isWorking = false; statusText = nil }
        do {
            let newID = try await session.recreateWithDomain(
                container: container,
                details: details,
                domain: domain.isEmpty ? nil : domain
            )
            // The old container id is gone; keep the user on the new one.
            NotificationCenter.default.post(
                name: .gantrySelectContainer,
                object: ContainerJump(hostID: session.host.id, containerID: newID)
            )
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// The user's preferred default apple/container DNS domain for new containers,
/// so Gantry can assign a resolvable name automatically (OrbStack-style) instead
/// of leaving every container nameless. Persisted in `UserDefaults`.
enum DefaultDNSDomain {
    static let key = "defaultDNSDomain"

    /// The domain to pre-select for a new container: the stored default when it
    /// still exists, otherwise the sole domain when there's exactly one, else
    /// none (the user must pick).
    static func preferred(in available: [String]) -> String {
        if let stored = UserDefaults.standard.string(forKey: key), available.contains(stored) {
            return stored
        }
        return available.count == 1 ? available[0] : ""
    }

    static var stored: String { UserDefaults.standard.string(forKey: key) ?? "" }

    static func set(_ domain: String) {
        UserDefaults.standard.set(domain, forKey: key)
    }

    /// Records `domain` as the default when none is set yet, so the first domain
    /// a user creates becomes the automatic one.
    static func setIfUnset(_ domain: String) {
        guard stored.isEmpty, !domain.isEmpty else { return }
        set(domain)
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
