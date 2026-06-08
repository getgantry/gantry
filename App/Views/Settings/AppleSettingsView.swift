import SwiftUI
import AppCore

/// Settings for the local apple/container engine: background-service control and
/// the local DNS domains that make containers resolvable by name (the
/// OrbStack-style `name.domain` flow). DNS create/delete prompt for admin.
struct AppleSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var status: AppleServiceStatus = .unknown
    @State private var domains: [String] = []
    @State private var loadingDomains = false
    @State private var newDomain = ""
    @State private var busy = false
    @State private var errorText: String?

    private var cliOverride: String? {
        model.sessions.first { $0.host.isAppleContainer }?.host.socketPathOverride
    }

    private var cliAvailable: Bool {
        AppleContainerControl.cliPath(override: cliOverride) != nil
    }

    var body: some View {
        Group {
            if cliAvailable {
                content
            } else {
                ContentUnavailableView {
                    Label("apple/container not found", systemImage: "apple.logo")
                } description: {
                    Text("Install Apple's container CLI to manage its services and local DNS domains here.")
                }
            }
        }
        .task { await reload() }
    }

    private var content: some View {
        Form {
            servicesSection
            domainsSection
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Services

    private var servicesSection: some View {
        Section {
            HStack(spacing: 10) {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                Text(statusText).font(.body)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                } else if status == .running {
                    Button("Stop") { act { try await AppleContainerControl.stopServices(cliOverride: cliOverride) } }
                } else {
                    Button("Start") { act { try await AppleContainerControl.startServices(cliOverride: cliOverride) } }
                        .buttonStyle(.borderedProminent)
                }
            }
        } header: {
            Text("Services")
        } footer: {
            Text("The apple/container background services must be running for local containers to work.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - DNS domains

    private var domainsSection: some View {
        Section {
            if loadingDomains {
                HStack { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
            } else if domains.isEmpty {
                Text("No local domains yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(domains, id: \.self) { domain in
                    HStack {
                        Image(systemName: "globe").foregroundStyle(.secondary)
                        Text(domain).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            act { try await AppleContainerControl.deleteDomain(domain, cliOverride: cliOverride) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(busy)
                        .help("Delete domain (requires admin)")
                    }
                }
            }

            HStack {
                TextField("New domain", text: $newDomain, prompt: Text("test"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addDomain() }
                Button("Add") { addDomain() }
                    .disabled(busy || newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Local DNS Domains")
        } footer: {
            Text("Launch a container on a domain (Run sheet → DNS domain, or `--dns-domain`) and it resolves as name.domain across your Mac. Creating or removing a domain requires administrator approval.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch status {
        case .running: .green
        case .stopped: .orange
        case .unavailable: .gray
        case .unknown: .secondary
        }
    }

    private var statusText: String {
        switch status {
        case .running: "Services running"
        case .stopped: "Services stopped"
        case .unavailable: "CLI not found"
        case .unknown: "Checking…"
        }
    }

    private func addDomain() {
        let name = newDomain.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        act {
            try await AppleContainerControl.createDomain(name, cliOverride: cliOverride)
        } onSuccess: {
            newDomain = ""
        }
    }

    private func reload() async {
        status = await AppleContainerControl.serviceStatus(cliOverride: cliOverride)
        await reloadDomains()
    }

    private func reloadDomains() async {
        guard cliAvailable else { return }
        loadingDomains = true
        defer { loadingDomains = false }
        do {
            domains = try await AppleContainerControl.listDomains(cliOverride: cliOverride)
        } catch {
            // A stopped engine can't list domains; keep the list empty quietly.
            domains = []
        }
    }

    private func act(_ operation: @escaping () async throws -> Void, onSuccess: @escaping () -> Void = {}) {
        Task {
            busy = true
            errorText = nil
            defer { busy = false }
            do {
                try await operation()
                onSuccess()
            } catch {
                errorText = error.localizedDescription
            }
            await reload()
        }
    }
}
