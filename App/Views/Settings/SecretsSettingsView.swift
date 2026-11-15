import SwiftUI
import AppCore

/// Settings ▸ Secrets: the Keychain secrets that environment variables can
/// use. Names and dates only; values are typed in secure fields and never
/// shown.
struct SecretsSettingsView: View {
    @State private var library = SecretsLibrary.shared
    @State private var selection: String?
    @State private var showNew = false
    @State private var editing: SecretEdit?
    @State private var deleteAction: DestructiveAction?
    @AppStorage(SecretGate.preferenceKey) private var requireTouchID = false

    var body: some View {
        Form {
            Section {
                SecretsList(library: library, selection: $selection)
                SecretsListButtons(
                    selection: selection,
                    onAdd: { showNew = true },
                    onRemove: confirmDelete,
                    onEdit: { editing = $0 }
                )
            } header: {
                Text("Keychain Secrets")
            } footer: {
                Text("An environment variable in New Container and Quick Run can take its value from one of these secrets. Recipes and copied commands keep only the name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Require Touch ID to use secrets", isOn: $requireTouchID)
            } footer: {
                if let error = library.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { library.reload() }
        .sheet(isPresented: $showNew) {
            NewSecretSheet { selection = $0 }
        }
        .sheet(item: $editing) { edit in
            EditSecretSheet(edit: edit) { selection = $0 }
        }
        .destructiveConfirmation($deleteAction) { action, _ in
            if library.delete(action.targets) { selection = nil }
        }
    }

    private func confirmDelete() {
        guard let selection else { return }
        deleteAction = DestructiveAction(kind: .deleteSecret, targets: [selection], names: [selection])
    }
}

/// What the edit sheet changes.
struct SecretEdit: Identifiable {
    enum Mode { case rename, replace }
    let name: String
    let mode: Mode
    var id: String { "\(name)-\(mode)" }
}

private struct SecretsList: View {
    let library: SecretsLibrary
    @Binding var selection: String?

    var body: some View {
        if library.secrets.isEmpty {
            ContentUnavailableView {
                Label("No Secrets", systemImage: "key")
            } description: {
                Text("Add a secret, then choose it for an environment variable.")
            }
            .frame(minHeight: 140)
        } else {
            List(library.secrets, selection: $selection) { secret in
                SecretRow(secret: secret).tag(secret.name)
            }
            .frame(minHeight: 160)
        }
    }
}

private struct SecretRow: View {
    let secret: SecretInfo

    var body: some View {
        HStack {
            Label(secret.name, systemImage: "lock.fill")
            Spacer()
            if let date = secret.modified ?? secret.created {
                Text(date, format: .dateTime.year().month().day().hour().minute())
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }
}

private struct SecretsListButtons: View {
    let selection: String?
    let onAdd: () -> Void
    let onRemove: () -> Void
    let onEdit: (SecretEdit) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onAdd) { Image(systemName: "plus") }
                .help("Add Secret")
                .accessibilityLabel("Add Secret")
            Button(action: onRemove) { Image(systemName: "minus") }
                .help("Delete Secret")
                .accessibilityLabel("Delete Secret")
                .disabled(selection == nil)
            Spacer()
            Button("Rename…") {
                if let selection { onEdit(SecretEdit(name: selection, mode: .rename)) }
            }
            .disabled(selection == nil)
            Button("Replace Value…") {
                if let selection { onEdit(SecretEdit(name: selection, mode: .replace)) }
            }
            .disabled(selection == nil)
        }
        .buttonStyle(.borderless)
    }
}

/// Renames a secret, or replaces its value through a secure field.
private struct EditSecretSheet: View {
    let edit: SecretEdit
    let onDone: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var library = SecretsLibrary.shared
    @State private var text = ""

    private var nameIssue: String? {
        EnvSecrets.nameIssue(text, taken: library.names, current: edit.name)
    }

    private var title: String {
        edit.mode == .rename
            ? String(localized: "Rename “\(edit.name)”")
            : String(localized: "Replace the Value of “\(edit.name)”")
    }

    private var canSave: Bool {
        switch edit.mode {
        case .rename:
            let name = text.trimmingCharacters(in: .whitespaces)
            return !name.isEmpty && name != edit.name && nameIssue == nil
        case .replace:
            return !text.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            Form {
                if edit.mode == .rename {
                    TextField("Name", text: $text)
                    if let nameIssue { Text(nameIssue).font(.caption).foregroundStyle(.red) }
                    Text("Recipes that use the old name must be changed by hand.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    SecureField("New value", text: $text)
                }
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
            library.clearError()
            text = edit.mode == .rename ? edit.name : ""
        }
    }

    private func save() {
        switch edit.mode {
        case .rename:
            let name = text.trimmingCharacters(in: .whitespaces)
            guard library.rename(edit.name, to: name) else { return }
            onDone(name)
        case .replace:
            guard library.save(name: edit.name, value: text) else { return }
            text = ""
            onDone(edit.name)
        }
        dismiss()
    }
}
