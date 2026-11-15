import SwiftUI
import AppCore

/// The value part of an environment row: a text field for a plain value, or
/// the name of a Keychain secret. The key menu switches between them. A
/// secret value is never shown here.
struct EnvSecretField: View {
    @Binding var value: String
    @Binding var secret: String?
    /// The problem with this row as a secret row, shown as an icon.
    var issue: String?

    @State private var library = SecretsLibrary.shared
    @State private var newSecret: NewSecretRequest?

    var body: some View {
        HStack(spacing: 4) {
            if let secret {
                SecretToken(name: secret, missing: !library.contains(secret))
            } else {
                TextField("VALUE", text: $value)
            }
            if let issue {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(issue)
                    .accessibilityLabel(issue)
            }
            keyMenu
        }
        .sheet(item: $newSecret) { request in
            NewSecretSheet(initialValue: request.initialValue) { name in
                secret = name
                value = ""
            }
        }
    }

    private var keyMenu: some View {
        Menu {
            if !library.names.isEmpty {
                Section("Keychain Secrets") {
                    ForEach(library.names, id: \.self) { name in
                        Button(name) {
                            secret = name
                            value = ""
                        }
                    }
                }
            }
            Button("New Secret…") { newSecret = NewSecretRequest(initialValue: "") }
            if secret == nil, !value.isEmpty {
                Button("Save Value in Keychain…") { newSecret = NewSecretRequest(initialValue: value) }
            }
            if secret != nil {
                Divider()
                Button("Use Plain Value") { secret = nil }
            }
        } label: {
            Image(systemName: secret == nil ? "key" : "key.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Use a Keychain secret for this value")
        .accessibilityLabel("Keychain Secrets")
        .onAppear { library.reload() }
    }
}

private struct NewSecretRequest: Identifiable {
    let id = UUID()
    var initialValue: String
}

/// The name of a secret in place of a value.
struct SecretToken: View {
    let name: String
    var missing = false

    var body: some View {
        Label {
            Text(verbatim: EnvSecrets.referenceText(name))
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: missing ? "exclamationmark.triangle.fill" : "lock.fill")
                .foregroundStyle(missing ? .orange : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(description)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description)
    }

    private var description: String {
        missing
            ? String(localized: "The Keychain secret “\(name)” does not exist.")
            : String(localized: "The value comes from the Keychain secret “\(name)”.")
    }
}

/// Adds a secret: a name and a hidden value. `initialValue` moves a typed
/// value into the Keychain.
struct NewSecretSheet: View {
    var initialValue = ""
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var library = SecretsLibrary.shared
    @State private var name = ""
    @State private var value = ""

    private var nameIssue: String? { EnvSecrets.nameIssue(name, taken: library.names) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var canSave: Bool { !trimmedName.isEmpty && nameIssue == nil && !value.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Keychain Secret").font(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text(verbatim: "db-password"))
                SecureField("Value", text: $value)
                if let nameIssue {
                    Text(nameIssue).font(.caption).foregroundStyle(.red)
                }
                Text("Gantry keeps the value in your Keychain and never shows it again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.columns)
            if let error = library.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            value = initialValue
            library.clearError()
        }
    }

    private func save() {
        guard library.add(name: trimmedName, value: value) else { return }
        value = ""
        onSave(trimmedName)
        dismiss()
    }
}
