import SwiftUI
import AppCore

/// `container registry list|login|logout`: the registries apple/container
/// holds credentials for in the keychain.
struct AppleRegistriesPane: View {
    let session: HostSession

    @State private var logins: [AppleRegistryLogin] = []
    @State private var loaded = false
    @State private var busy = false
    @State private var errorText: String?
    @State private var selection: String?
    @State private var showLogin = false
    @State private var logoutTarget: AppleRegistryLogin?
    @State private var searchText = ""

    private var filteredLogins: [AppleRegistryLogin] {
        guard !searchText.isEmpty else { return logins }
        let needle = searchText.lowercased()
        return logins.filter {
            $0.hostname.lowercased().contains(needle) || $0.username.lowercased().contains(needle)
        }
    }

    private var cli: String? { session.appleCLIOverride }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppleSystemPaneHeader(pane: .registries, badge: nil) {
                HStack(spacing: 8) {
                    if busy { ProgressView().controlSize(.small) }
                    Button { showLogin = true } label: {
                        Label(String(localized: "Log In…"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        Task { await reload() }
                    } label: {
                        Label(String(localized: "Refresh"), systemImage: "arrow.clockwise")
                    }
                    .onSectionCommand(.refresh, .system) { Task { await reload() } }
                }
                .disabled(busy)
            }
            if let errorText {
                AppleSystemErrorBanner(message: errorText) { self.errorText = nil }
                    .padding([.horizontal, .bottom])
            }
            Divider()
            content
        }
        .navigationTitle(AppleSystemPane.registries.title)
        .searchable(text: $searchText, prompt: Text("Filter by registry or user"))
        .task { await reload() }
        .sheet(isPresented: $showLogin, onDismiss: { Task { await reload() } }) {
            AppleRegistryLoginSheet(cliOverride: cli)
        }
        .confirmationDialog(
            String(localized: "Log out of this registry?"),
            isPresented: Binding(presence: $logoutTarget),
            presenting: logoutTarget
        ) { login in
            Button(String(localized: "Log Out of \(login.hostname)"), role: .destructive) {
                logout(login)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { login in
            Text("apple/container removes the saved credentials for “\(login.hostname)” from the keychain.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if loaded, logins.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "No Registry Logins"), systemImage: "person.badge.key")
            } description: {
                Text("Log in to a registry to push images and pull private images with apple/container.")
            } actions: {
                Button(String(localized: "Log In…")) { showLogin = true }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredLogins.isEmpty {
            ListNoResultsView(search: searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(filteredLogins, selection: $selection) {
                TableColumn(String(localized: "Registry")) { login in
                    Text(login.hostname).font(.system(.body, design: .monospaced))
                }
                TableColumn(String(localized: "User")) { login in
                    Text(login.username)
                }
                TableColumn(String(localized: "Modified")) { login in
                    Text(login.modified.map(Formatters.relative) ?? "—")
                        .foregroundStyle(.secondary)
                }
                TableColumn(String()) { login in
                    Button {
                        logoutTarget = login
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Log Out"))
                    .accessibilityLabel(String(localized: "Log Out"))
                }
                .width(32)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let login = logins.first(where: { $0.id == id }) {
                    Button(String(localized: "Copy Registry")) { copyToPasteboard(login.hostname) }
                    Button(String(localized: "Log Out…"), role: .destructive) { logoutTarget = login }
                }
            }
        }
    }

    private func logout(_ login: AppleRegistryLogin) {
        Task {
            busy = true
            errorText = nil
            defer { busy = false }
            do {
                try await AppleContainerControl.logoutRegistry(login.hostname, cliOverride: cli)
            } catch {
                errorText = error.localizedDescription
            }
            await reload()
        }
    }

    private func reload() async {
        do {
            logins = try await AppleContainerControl.listRegistryLogins(cliOverride: cli)
        } catch {
            errorText = error.localizedDescription
        }
        loaded = true
    }
}

/// Logs in to a registry. The password lives only in this sheet's state and
/// goes to the CLI on stdin; it is cleared when the sheet closes.
struct AppleRegistryLoginSheet: View {
    let cliOverride: String?
    @Environment(\.dismiss) private var dismiss

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var scheme: AppleRegistryScheme = .https
    @State private var busy = false
    @State private var errorText: String?

    private var serverValid: Bool {
        AppleContainerControl.isValidRegistryServer(server.trimmingCharacters(in: .whitespaces))
    }

    private var canSubmit: Bool {
        serverValid && !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !busy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField(String(localized: "Registry"), text: $server, prompt: Text(verbatim: "ghcr.io"))
                    if !server.isEmpty, !serverValid {
                        Text("Enter a host name with an optional port, for example ghcr.io or localhost:5000. Do not include https:// or a path.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    TextField(String(localized: "User Name"), text: $username)
                        .textContentType(.username)
                    SecureField(String(localized: "Password or Token"), text: $password)
                        .textContentType(.password)
                    Picker(String(localized: "Connection"), selection: $scheme) {
                        Text("HTTPS").tag(AppleRegistryScheme.https)
                        Text("HTTP (insecure)").tag(AppleRegistryScheme.http)
                    }
                } header: {
                    Text("Log In to a Registry")
                } footer: {
                    Text("apple/container checks the credentials with the registry and keeps them in your keychain. Gantry does not save the password.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(busy)

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Log In")) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
            .padding()
        }
        .frame(width: 440)
        .onDisappear { password = "" }
    }

    private func close() {
        password = ""
        dismiss()
    }

    private func submit() {
        let secret = password
        Task {
            busy = true
            errorText = nil
            defer { busy = false }
            do {
                try await AppleContainerControl.loginRegistry(
                    server: server,
                    username: username,
                    password: secret,
                    scheme: scheme,
                    cliOverride: cliOverride
                )
                close()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
