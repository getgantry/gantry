import SwiftUI
import AppCore
import DockerKit

/// Changes the CPU, memory and restart policy of a container. Docker updates
/// it in place; an Apple host recreates it after a confirmation.
struct EditResourcesSheet: View {
    let session: HostSession
    let container: ContainerSummary
    @Environment(\.dismiss) private var dismiss

    @State private var form: ContainerResourceForm?
    @State private var loadFailed = false
    @State private var isWorking = false
    @State private var errorText: String?
    @State private var confirm: DestructiveAction?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Resources").font(.title2.weight(.semibold))
                Spacer()
            }
            .padding()
            Divider()
            content
            Divider()
            footer.padding()
        }
        .frame(width: 480)
        .task { await load() }
        .destructiveConfirmation($confirm) { _, _ in await apply() }
    }

    @ViewBuilder
    private var content: some View {
        if let binding = Binding($form) {
            ResourceFormFields(form: binding, containerName: container.displayName, errorText: errorText)
        } else if loadFailed {
            ContentUnavailableView(
                "Details Unavailable", systemImage: "exclamationmark.triangle",
                description: Text("Could not load container details.")
            )
            .frame(height: 200)
        } else {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    private var isApple: Bool { form?.engine == .apple }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                if isApple { confirm = .recreateContainer(container) } else { Task { await apply() } }
            } label: {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Text(isApple ? "Apply and Recreate…" : "Apply")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!(form?.isValid ?? false) || !(form?.hasChanges ?? false) || isWorking)
        }
    }

    private func load() async {
        form = await session.resourceForm(for: container)
        loadFailed = form == nil
    }

    private func apply() async {
        guard let form else { return }
        errorText = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await session.applyResources(form, to: container)
            dismiss()
        } catch {
            errorText = HostSession.resourceErrorText(error)
        }
    }
}

/// The fields of the sheet. Each field shows its own problem below it.
private struct ResourceFormFields: View {
    @Binding var form: ContainerResourceForm
    let containerName: String
    let errorText: String?

    var body: some View {
        Form {
            Section {
                if form.fields.contains(.cpus) { cpusRow }
                if form.fields.contains(.memory) {
                    sizeRow("Memory Limit", text: $form.memory, field: .memory, prompt: "512m")
                }
                if form.fields.contains(.memoryReservation) {
                    sizeRow("Memory Reservation", text: $form.memoryReservation, field: .memoryReservation, prompt: "256m")
                }
                if form.fields.contains(.memorySwap) {
                    sizeRow("Memory + Swap", text: $form.memorySwap, field: .memorySwap, prompt: "1g")
                }
            } header: {
                Text("Limits of \(containerName)")
            } footer: {
                Text(footerText).font(.caption).foregroundStyle(.secondary)
            }
            if form.fields.contains(.restartPolicy) { restartSection }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private var footerText: String {
        form.engine == .apple
            ? String(localized: "Sizes take the units k, m, g and t. apple/container recreates the container to change these values.")
            : String(localized: "Sizes take the units k, m, g and t. Enter -1 in Memory + Swap for no swap limit. The container does not restart.")
    }

    private var cpusRow: some View {
        FieldRow(error: form.error(for: .cpus)) {
            TextField("CPUs", text: $form.cpus, prompt: Text(verbatim: form.engine == .apple ? "2" : "1.5"))
        }
    }

    private func sizeRow(
        _ title: LocalizedStringKey, text: Binding<String>, field: ContainerResourceForm.Field, prompt: String
    ) -> some View {
        FieldRow(error: form.error(for: field)) {
            TextField(title, text: text, prompt: Text(verbatim: prompt))
        }
    }

    private var restartSection: some View {
        Section {
            Picker("Restart Policy", selection: $form.restartPolicy) {
                ForEach(ContainerResourceForm.restartPolicies, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            if form.restartPolicy == "on-failure" {
                FieldRow(error: form.error(for: .restartPolicy)) {
                    TextField("Maximum Retries", text: $form.maxRetries, prompt: Text(verbatim: "0"))
                }
            }
        }
    }
}

/// A form row with the problem of its value under it.
private struct FieldRow<Content: View>: View {
    let error: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
