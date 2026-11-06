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
    /// A service stop/restart or a domain delete waiting for confirmation.
    @State private var pendingAction: DestructiveAction?
    /// True after changing the default domain until the services are restarted
    /// (name resolution for new containers only applies after a restart).
    @State private var needsRestart = false
    /// The domain new containers are assigned automatically (OrbStack-style).
    @AppStorage(DefaultDNSDomain.key) private var defaultDomain = ""

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
        .destructiveConfirmation($pendingAction) { action, _ in perform(action) }
    }

    private var content: some View {
        Form {
            servicesSection
            AppleSystemSettingsSection(cliOverride: cliOverride)
            domainsSection
            if needsRestart {
                restartSection
            }
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
                StatusSymbol(systemName: statusSymbol, tint: statusColor, size: 9)
                Text(statusText).font(.body)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                } else if status == .running {
                    Button("Stop…") {
                        pendingAction = .services(.stopServices, runningContainers: model.appleRunningContainerCount)
                    }
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
                    HStack(spacing: 8) {
                        Image(systemName: "globe").foregroundStyle(.secondary)
                        Text(domain).font(.system(.body, design: .monospaced))
                        if domain == defaultDomain {
                            Text("Default")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15), in: .capsule)
                                .foregroundStyle(Color.accentColor)
                        }
                        Spacer()
                        Button {
                            applyDefault(domain)
                        } label: {
                            Image(systemName: defaultDomain == domain ? "star.fill" : "star")
                        }
                        .buttonStyle(.borderless)
                        .disabled(busy)
                        .help(String(localized: "Use as the default domain — new containers resolve as name.\(domain)"))
                        .accessibilityLabel(String(localized: "Use \(domain) as the default domain"))
                        Button(role: .destructive) {
                            pendingAction = DestructiveAction(kind: .deleteDomain, targets: [domain])
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(busy)
                        .help("Delete domain (requires admin)")
                        .accessibilityLabel("Delete domain (requires admin)")
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
            Text("Star a domain to make it the default: new containers are assigned it automatically and resolve as name.domain across your Mac (after a services restart). Existing containers need to be recreated — use “Change DNS Name” on the container. Creating or removing a domain requires administrator approval.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var restartSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.tint)
                Text("Restart services to apply name resolution for new containers.")
                    .font(.callout)
                Spacer()
                Button("Restart Services…") {
                    pendingAction = .services(.restartServices, runningContainers: model.appleRunningContainerCount)
                }
                .disabled(busy)
            }
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
        case .running: String(localized: "Services running")
        case .stopped: String(localized: "Services stopped")
        case .unavailable: String(localized: "CLI not found")
        case .unknown: String(localized: "Checking…")
        }
    }

    private var statusSymbol: String {
        switch status {
        case .running: "circle.fill"
        case .stopped: "stop.circle"
        case .unavailable: "minus.circle"
        case .unknown: "circle.dotted"
        }
    }

    /// Runs a confirmed service or domain action.
    private func perform(_ action: DestructiveAction) {
        switch action.kind {
        case .stopServices:
            act { try await AppleContainerControl.stopServices(cliOverride: cliOverride) }
        case .restartServices:
            act {
                try await AppleContainerControl.restartServices(cliOverride: cliOverride)
            } onSuccess: {
                needsRestart = false
            }
        case .deleteDomain:
            guard let domain = action.targets.first else { return }
            act {
                try await AppleContainerControl.deleteDomain(domain, cliOverride: cliOverride)
            } onSuccess: {
                if defaultDomain == domain { defaultDomain = "" }
            }
        default:
            break
        }
    }

    private func addDomain() {
        let name = newDomain.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        act {
            try await AppleContainerControl.createDomain(name, cliOverride: cliOverride)
        } onSuccess: {
            newDomain = ""
            // The first domain becomes the automatic default for new containers.
            if defaultDomain.isEmpty { applyDefault(name) }
        }
    }

    /// Sets (or, when re-tapped, clears) the default DNS domain: records it for
    /// Gantry, writes it to apple/container's config, and flags that a services
    /// restart is needed for host name resolution to take effect.
    private func applyDefault(_ domain: String) {
        let next = (defaultDomain == domain) ? "" : domain
        defaultDomain = next
        do {
            try AppleContainerControl.setDefaultDNSDomain(next.isEmpty ? nil : next)
            needsRestart = true
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func reload() async {
        status = await AppleContainerControl.serviceStatus(cliOverride: cliOverride)
        // The config file is the source of truth for the default domain; mirror
        // it into Gantry's preference so the star and create sheets agree.
        let configured = AppleContainerControl.defaultDNSDomain()
        if configured != defaultDomain { defaultDomain = configured }
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
