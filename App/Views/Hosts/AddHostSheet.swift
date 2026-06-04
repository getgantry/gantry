import SwiftUI
import AppCore
import SSHKit

/// SSH auth method selection, shared by the add- and edit-host forms.
enum AuthChoice: Hashable {
    case automatic
    case keyFile
    case password
}

/// Sheet for adding a new SSH Docker host. Resolves ssh_config live to show the
/// user what defaults will apply for the host they typed.
struct AddHostSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var user = ""
    @State private var authChoice: AuthChoice = .automatic
    @State private var keyFilePath = ""
    @State private var password = ""

    @State private var showingKeyImporter = false
    @State private var resolvedSummary: String?
    @State private var resolveTask: Task<Void, Never>?

    /// Concrete host aliases from ~/.ssh/config for one-click import.
    private let configHosts = SSHConfig.listHosts()
    @State private var selectedConfigHost: String?

    private var defaultUser: String { NSUserName() }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAdd: Bool {
        !trimmedHost.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "network")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Add SSH Host")
                    .font(.title2.weight(.semibold))
            }

            Form {
                if !configHosts.isEmpty {
                    Section {
                        Picker("Import from SSH config", selection: $selectedConfigHost) {
                            Text("Choose a host…").tag(String?.none)
                            ForEach(configHosts, id: \.self) { alias in
                                Text(alias).tag(String?.some(alias))
                            }
                        }
                        .onChange(of: selectedConfigHost) { _, alias in
                            if let alias { applyConfigHost(alias) }
                        }
                    } footer: {
                        Text("Hosts from ~/.ssh/config. Picking one fills the fields below.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("Name", text: $name)
                    TextField("Host", text: $host, prompt: Text("server.local or 192.168.1.10"))
                        .onChange(of: host) { scheduleResolve() }
                    TextField("Port", text: $port, prompt: Text("22"))
                    TextField("User", text: $user, prompt: Text(defaultUser))
                } footer: {
                    if let resolvedSummary {
                        Text(resolvedSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
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
                        SecureField("Password", text: $password)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") { add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdd)
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
        .onDisappear { resolveTask?.cancel() }
    }

    // MARK: - Actions

    private func add() {
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
        let dockerHost = DockerHost(name: resolvedName, kind: .ssh(endpoint))

        // Stash the password into the Keychain so the connection can find it.
        if authChoice == .password, !password.isEmpty {
            KeychainStore.set(
                password,
                account: KeychainStore.sshPasswordAccount(hostID: dockerHost.id)
            )
        }

        model.addHost(dockerHost)
        dismiss()
    }

    /// Fills the form from a picked ~/.ssh/config alias.
    private func applyConfigHost(_ alias: String) {
        let resolved = SSHConfig.resolve(host: alias)
        name = alias
        host = alias
        port = String(resolved.port)
        user = resolved.user ?? ""
        authChoice = .automatic
        scheduleResolve()
    }

    /// Debounced ssh_config resolution for the live footnote.
    private func scheduleResolve() {
        resolveTask?.cancel()
        let typed = trimmedHost
        guard !typed.isEmpty else {
            resolvedSummary = nil
            return
        }
        resolveTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let resolved = SSHConfig.resolve(host: typed)
            guard !Task.isCancelled else { return }

            var parts: [String] = []
            if resolved.hostName != typed { parts.append("host \(resolved.hostName)") }
            if let user = resolved.user, !user.isEmpty { parts.append("user \(user)") }
            parts.append("port \(resolved.port)")
            if let first = resolved.identityFiles.first {
                parts.append("key \((first as NSString).lastPathComponent)")
            }
            resolvedSummary = "SSH config: " + parts.joined(separator: ", ")
        }
    }
}
