import SwiftUI
import DockerKit
import AppCore
import SSHKit

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("Hosts", systemImage: "server.rack") {
                HostsSettings()
            }
            Tab("Apple", systemImage: "apple.logo") {
                AppleSettingsView()
            }
            Tab("Agents", systemImage: "sparkles") {
                AgentSettingsView()
            }
            Tab("About", systemImage: "info.circle") {
                AboutSettings()
            }
        }
        .frame(width: 560, height: 460)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    @AppStorage("refreshInterval") private var refreshInterval = 5.0
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("showDockIcon") private var showDockIcon = true
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(ContainerNotifier.preferenceKey) private var notifyContainerEvents = true
    @AppStorage(BiometricGate.preferenceKey) private var requireBiometrics = false
    @AppStorage(TerminalTheme.preferenceKey) private var terminalTheme = "system"

    /// Working copy of the local host's socket override, committed on Enter or
    /// via the Reconnect button. Seeded from the live host below.
    @State private var socketOverride = ""

    private let candidates = DockerSocketDiscovery.allCandidates()

    /// The persistent Local host's session (the one host that always exists).
    private var localSession: HostSession? {
        model.sessions.first { $0.host.isLocal }
    }

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)

                Picker("Terminal theme", selection: $terminalTheme) {
                    ForEach(TerminalTheme.all) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
            } header: {
                Text("Appearance")
            }

            Section {
                TextField(
                    "Socket Path",
                    text: $socketOverride,
                    prompt: Text("Auto-detect")
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitOverride() }

                HStack {
                    Spacer()
                    Button("Reconnect") {
                        commitOverride()
                        reconnectLocal()
                    }
                }
            } header: {
                Text("Local Docker Socket")
            } footer: {
                Text("Override the unix socket path for the local host. Leave empty to auto-detect. The override is stored on the Local host and applied on reconnect.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Discovered Sockets") {
                ForEach(candidates, id: \.self) { path in
                    Button {
                        socketOverride = path
                        commitOverride()
                        reconnectLocal()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: selectionImage(for: path))
                                .foregroundStyle(socketOverride == path ? Color.accentColor : .secondary)
                            Image(systemName: exists(path) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(exists(path) ? .green : .secondary)
                                .help(exists(path) ? "Socket exists" : "Not found")
                            Text(path)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                Slider(value: $refreshInterval, in: 2...30, step: 1) {
                    Text("Refresh Interval")
                } minimumValueLabel: {
                    Text("2s")
                } maximumValueLabel: {
                    Text("30s")
                }
                Text("Poll every \(Int(refreshInterval)) seconds when the live event stream is unavailable.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Refresh")
            }

            Section {
                Toggle("Notify when a container fails", isOn: $notifyContainerEvents)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Send a macOS notification when a container crashes, runs out of memory, or fails its health check on any host. Manual stops and restarts are not reported. Click a notification to jump to the container.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Confirm destructive actions with Touch ID", isOn: $requireBiometrics)
            } header: {
                Text("Security")
            } footer: {
                Text("Require Touch ID (or your login password) before removing a container or deleting a host.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show menu bar icon", isOn: $showMenuBarExtra)
                    .disabled(!showDockIcon)
                Toggle("Show Dock icon", isOn: $showDockIcon)
                    .disabled(!showMenuBarExtra)
            } header: {
                Text("Icons")
            } footer: {
                Text("Hide the Dock icon to run Gantry as a menu-bar-only app. One of the two icons always stays on so the app remains reachable.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { socketOverride = localSession?.host.socketPathOverride ?? "" }
    }

    /// The radio-style selection glyph: filled when this path is the current
    /// override (empty override means "none selected").
    private func selectionImage(for path: String) -> String {
        socketOverride == path ? "largecircle.fill.circle" : "circle"
    }

    /// Persists the current `socketOverride` onto the Local host via the model.
    /// An empty string clears the override (auto-detect).
    private func commitOverride() {
        guard let session = localSession else { return }
        let trimmed = socketOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let newOverride: String? = trimmed.isEmpty ? nil : trimmed
        guard newOverride != session.host.socketPathOverride else { return }

        var host = session.host
        host.socketPathOverride = newOverride
        model.updateHost(host)
    }

    private func reconnectLocal() {
        guard let session = model.sessions.first(where: { $0.host.isLocal }) else { return }
        Task {
            await session.disconnect()
            await session.connect()
        }
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

// MARK: - Hosts

private struct HostsSettings: View {
    @Environment(AppModel.self) private var model

    @State private var showingAddHost = false
    @State private var editingHost: DockerHost?
    @State private var confirmRemoval: UUID?

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(model.sessions) { session in
                    HostRow(
                        session: session,
                        onEdit: { editingHost = session.host },
                        onReconnect: { reconnect(session) },
                        onRemove: { confirmRemoval = session.host.id }
                    )
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Button {
                    showingAddHost = true
                } label: {
                    Label("Add Host…", systemImage: "plus")
                }
                Spacer()
            }
            .padding(10)
        }
        .sheet(isPresented: $showingAddHost) {
            AddHostSheet()
        }
        .sheet(item: $editingHost) { host in
            EditHostSheet(host: host)
        }
        .confirmationDialog(
            "Remove this host?",
            isPresented: removalDialogBinding,
            presenting: confirmRemoval
        ) { hostID in
            Button("Remove Host", role: .destructive) {
                let name = model.session(id: hostID)?.host.name ?? "host"
                Task {
                    guard await BiometricGate.confirm("remove host \(name)") else { return }
                    if let session = model.session(id: hostID) {
                        await session.disconnect()
                    }
                    model.removeHost(id: hostID)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { hostID in
            let label = model.session(id: hostID)?.host.name ?? "this host"
            Text("\(label) will be removed from Gantry. Stored credentials are not deleted.")
        }
    }

    private var removalDialogBinding: Binding<Bool> {
        Binding(presence: $confirmRemoval)
    }

    private func reconnect(_ session: HostSession) {
        Task {
            await session.disconnect()
            await session.connect()
        }
    }
}

/// One row in the Hosts list: name, kind, live status dot, and per-host actions.
private struct HostRow: View {
    var session: HostSession
    var onEdit: () -> Void
    var onReconnect: () -> Void
    var onRemove: () -> Void

    private var host: DockerHost { session.host }

    private var kindDescription: String {
        switch host.kind {
        case .local:
            return "Local"
        case .ssh(let endpoint):
            let user = endpoint.username.isEmpty ? "" : "\(endpoint.username)@"
            return "SSH \(user)\(endpoint.host):\(endpoint.port)"
        case .appleContainer:
            return "Apple Container (local)"
        }
    }

    /// Keychain hint: which secrets, if any, are stored for this SSH host.
    private var storedCredentialHint: String? {
        guard host.isSSH else { return nil }
        let hasPassword = KeychainStore.get(
            account: KeychainStore.sshPasswordAccount(hostID: host.id)
        ) != nil
        let hasPassphrase = KeychainStore.get(
            account: KeychainStore.keyPassphraseAccount(hostID: host.id)
        ) != nil
        switch (hasPassword, hasPassphrase) {
        case (true, true): return "Password and key passphrase stored in Keychain"
        case (true, false): return "Password stored in Keychain"
        case (false, true): return "Key passphrase stored in Keychain"
        case (false, false): return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(session.status.dotColor)
                    .frame(width: 8, height: 8)
                    .help(session.status.shortDescription)

                VStack(alignment: .leading, spacing: 1) {
                    Text(host.name)
                        .font(.body.weight(.medium))
                    Text(kindDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Reconnect", action: onReconnect)
                    .controlSize(.small)

                if host.isSSH {
                    Button("Edit…", action: onEdit)
                        .controlSize(.small)
                }

                if host.removable {
                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "trash")
                    }
                    .controlSize(.small)
                }
            }

            if let storedCredentialHint {
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(storedCredentialHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Forget…") { forgetCredentials() }
                        .controlSize(.mini)
                        .buttonStyle(.link)
                }
                .padding(.leading, 16)
            }
        }
        .padding(.vertical, 4)
        .opacity(forgotten ? 0.6 : 1)
    }

    /// Local UI flag so the hint hides immediately after forgetting, since the
    /// Keychain reads are not observed.
    @State private var forgotten = false

    private func forgetCredentials() {
        KeychainStore.delete(account: KeychainStore.sshPasswordAccount(hostID: host.id))
        KeychainStore.delete(account: KeychainStore.keyPassphraseAccount(hostID: host.id))
        forgotten = true
    }
}

/// Sheet for editing an existing SSH host: name, host, port, user, auth.
/// Commits through `model.updateHost` and reconnects the replaced session.
private struct EditHostSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let host: DockerHost

    @State private var name: String
    @State private var hostName: String
    @State private var port: String
    @State private var user: String
    @State private var authChoice: AuthChoice
    @State private var keyFilePath: String
    @State private var password: String

    @State private var showingKeyImporter = false

    init(host: DockerHost) {
        self.host = host
        _name = State(initialValue: host.name)

        guard case .ssh(let endpoint) = host.kind else {
            // Editing is offered only for SSH hosts; seed empty otherwise.
            _hostName = State(initialValue: "")
            _port = State(initialValue: "22")
            _user = State(initialValue: "")
            _authChoice = State(initialValue: .automatic)
            _keyFilePath = State(initialValue: "")
            _password = State(initialValue: "")
            return
        }

        _hostName = State(initialValue: endpoint.host)
        _port = State(initialValue: String(endpoint.port))
        _user = State(initialValue: endpoint.username)

        switch endpoint.auth {
        case .automatic:
            _authChoice = State(initialValue: .automatic)
            _keyFilePath = State(initialValue: endpoint.identityFile ?? "")
        case .keyFile(let path):
            _authChoice = State(initialValue: .keyFile)
            _keyFilePath = State(initialValue: path)
        case .password:
            _authChoice = State(initialValue: .password)
            _keyFilePath = State(initialValue: endpoint.identityFile ?? "")
        }
        _password = State(initialValue: "")
    }

    private var defaultUser: String { NSUserName() }

    private var trimmedHost: String {
        hostName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool { !trimmedHost.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "network")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Edit SSH Host")
                    .font(.title2.weight(.semibold))
            }

            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Host", text: $hostName, prompt: Text("server.local or 192.168.1.10"))
                    TextField("Port", text: $port, prompt: Text("22"))
                    TextField("User", text: $user, prompt: Text(defaultUser))
                }

                Section("Authentication") {
                    Picker("Method", selection: $authChoice) {
                        Text("SSH config & default keys").tag(AuthChoice.automatic)
                        Text("Private key file").tag(AuthChoice.keyFile)
                        Text("Password").tag(AuthChoice.password)
                    }

                    switch authChoice {
                    case .automatic:
                        Text("Gantry resolves keys from your SSH config and the usual default identities.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    case .keyFile:
                        HStack {
                            Text(keyFilePath.isEmpty ? "No key selected" : keyFilePath)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(keyFilePath.isEmpty ? .secondary : .primary)
                            Spacer()
                            Button("Choose…") { showingKeyImporter = true }
                        }
                    case .password:
                        SecureField("New password (leave blank to keep)", text: $password)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
        .fileImporter(
            isPresented: $showingKeyImporter,
            allowedContentTypes: [.data, .item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                keyFilePath = url.path
            }
        }
    }

    private func save() {
        let portValue = Int(port.trimmingCharacters(in: .whitespaces)) ?? 22
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)

        let auth: SSHAuthMode
        var identityFile: String?
        switch authChoice {
        case .automatic:
            auth = .automatic
        case .keyFile:
            auth = .keyFile(keyFilePath)
            identityFile = keyFilePath
        case .password:
            auth = .password
        }

        let endpoint = SSHEndpoint(
            host: trimmedHost,
            port: portValue,
            username: trimmedUser,
            identityFile: identityFile,
            auth: auth
        )

        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = displayName.isEmpty ? trimmedHost : displayName

        // Preserve the host id so the session keeps its identity & Keychain accounts.
        var updated = host
        updated.name = resolvedName
        updated.kind = .ssh(endpoint)

        // Update the stored password if a new one was entered.
        if authChoice == .password, !password.isEmpty {
            KeychainStore.set(
                password,
                account: KeychainStore.sshPasswordAccount(hostID: host.id)
            )
        }

        // Replace the session; tear down the old connection and reconnect the new.
        let oldSession = model.session(id: host.id)
        let newSession = model.updateHost(updated)
        Task {
            await oldSession?.disconnect()
            if let newSession, newSession !== oldSession {
                await newSession.connect()
            }
        }

        dismiss()
    }
}

// MARK: - About

private struct AboutSettings: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Gantry")
                .font(.largeTitle.weight(.bold))
            Text("Version \(version)")
                .foregroundStyle(.secondary)
            Text("A native macOS Docker management app.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Link("github.com/getgantry/gantry",
                 destination: URL(string: "https://github.com/getgantry/gantry")!)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }
}
