import SwiftUI
import AppCore

/// Edits a string-array property (`[container.dns]` nameservers, search
/// domains, options) as rows: add, change and remove items, then save.
struct AppleSystemListEditor: View {
    let property: AppleSystemProperty
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = []
    @State private var errorText: String?

    struct Row: Identifiable, Equatable {
        let id = UUID()
        var text: String
    }

    private var validation: Result<[String], Error> {
        Result { try AppleContainerControl.validatedPropertyList(rows.map(\.text), kind: property.kind) }
    }

    private var validationMessage: String? {
        guard case .failure(let error) = validation else { return nil }
        return error.localizedDescription
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                rowsSection
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .formStyle(.grouped)
            buttons
        }
        .frame(width: 460)
        .onAppear(perform: seed)
    }

    private var rowsSection: some View {
        Section {
            ForEach($rows) { $row in
                rowField($row)
            }
            Button {
                rows.append(Row(text: ""))
            } label: {
                Label(String(localized: "Add Item"), systemImage: "plus")
            }
            .buttonStyle(.borderless)
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            LabeledContent(String(localized: "Running value")) {
                Text(verbatim: property.effective?.display ?? String(localized: "not set"))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
        } header: {
            Text(verbatim: property.key)
                .font(.system(.headline, design: .monospaced))
        } footer: {
            Text("Gantry writes the list to ~/.config/container/config.toml. An empty list removes the key. Restart the services to apply it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func rowField(_ row: Binding<Row>) -> some View {
        HStack {
            TextField(String(localized: "Item"), text: row.text, prompt: Text(verbatim: placeholder))
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
            Button {
                rows.removeAll { $0.id == row.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Remove Item"))
            .accessibilityLabel(String(localized: "Remove Item"))
        }
    }

    private var placeholder: String {
        switch property.kind {
        case .nameserverList: "1.1.1.1"
        case .domainList: "example.com"
        default: "ndots:2"
        }
    }

    private var buttons: some View {
        HStack {
            if property.user != nil {
                Button(String(localized: "Use Default"), role: .destructive) { save([]) }
                    .help(String(localized: "Remove the value from config.toml"))
            }
            Spacer()
            Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Save")) { save(rows.map(\.text)) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled((try? validation.get()) == nil)
        }
        .padding()
    }

    private func seed() {
        let items = (property.user ?? property.effective)?.stringItems ?? []
        rows = items.map { Row(text: $0) }
        if rows.isEmpty { rows = [Row(text: "")] }
    }

    private func save(_ items: [String]) {
        do {
            try AppleContainerControl.setUserList(property.key, to: items, kind: property.kind)
            onChange()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
