import SwiftUI
import AppKit
import AppCore
import DockerKit

/// Sheet for creating and running a new container. Mirrors the common
/// `docker run` knobs: image, name, command, port mappings, environment,
/// volume binds, restart policy, TTY and auto-remove. On a 404 from create
/// (image missing locally) it offers to pull the image and retry.
struct CreateContainerSheet: View {
    @Bindable var session: HostSession
    @Environment(\.dismiss) private var dismiss

    @State private var image = ""
    @State private var name = ""
    @State private var command = ""
    @State private var ports: [PortRow] = []
    @State private var env: [EnvRow] = []
    @State private var binds: [BindRow] = []
    @State private var restartPolicy = "no"
    @State private var tty = false
    @State private var autoRemove = false

    @State private var isWorking = false
    @State private var errorText: String?
    /// Set when create failed with a 404; offers a pull-and-retry button.
    @State private var imageMissing = false
    @State private var pullStatus: String?

    private var canCreate: Bool {
        !image.trimmingCharacters(in: .whitespaces).isEmpty && !isWorking
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Container")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding()

            Divider()

            Form {
                Section("Image") {
                    TextField("Image", text: $image, prompt: Text("nginx:alpine"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Name (optional)", text: $name, prompt: Text("my-container"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Command (optional)", text: $command, prompt: Text("nginx -g 'daemon off;'"))
                        .textFieldStyle(.roundedBorder)
                }

                Section {
                    editorRows(
                        $ports,
                        addLabel: "Add Port",
                        empty: { PortRow() }
                    ) { $row in
                        TextField("Host", text: $row.host, prompt: Text("8080"))
                            .frame(width: 80)
                        Text(":").foregroundStyle(.secondary)
                        TextField("Container", text: $row.container, prompt: Text("80"))
                            .frame(width: 80)
                        Picker("", selection: $row.proto) {
                            Text("tcp").tag("tcp")
                            Text("udp").tag("udp")
                        }
                        .labelsHidden()
                        .frame(width: 70)
                    }
                } header: {
                    Text("Ports")
                }

                Section("Environment") {
                    editorRows(
                        $env,
                        addLabel: "Add Variable",
                        empty: { EnvRow() }
                    ) { $row in
                        TextField("KEY", text: $row.key)
                        Text("=").foregroundStyle(.secondary)
                        TextField("VALUE", text: $row.value)
                    }
                }

                Section("Volumes") {
                    editorRows(
                        $binds,
                        addLabel: "Add Volume",
                        empty: { BindRow() }
                    ) { $row in
                        TextField("Host path", text: $row.host)
                        Button {
                            pickHostPath(for: row.id)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        Text(":").foregroundStyle(.secondary)
                        TextField("Container path", text: $row.container)
                        Toggle("ro", isOn: $row.readOnly)
                            .toggleStyle(.checkbox)
                    }
                }

                Section("Options") {
                    if session.host.capabilities.restartPolicy {
                        Picker("Restart Policy", selection: $restartPolicy) {
                            ForEach(RestartPolicyOption.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                    }
                    Toggle("Allocate a TTY", isOn: $tty)
                    Toggle("Remove on exit (--rm)", isOn: $autoRemove)
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                        if imageMissing {
                            Button {
                                Task { await pullAndRetry() }
                            } label: {
                                Label("Pull image and retry", systemImage: "arrow.down.circle")
                            }
                            .disabled(isWorking)
                        }
                    }
                }

                if let pullStatus {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(pullStatus).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await create() }
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create & Run")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
            .padding()
        }
        .frame(width: 560, height: 640)
    }

    // MARK: - Reusable editor list

    @ViewBuilder
    private func editorRows<Element: Identifiable, RowContent: View>(
        _ rows: Binding<[Element]>,
        addLabel: String,
        empty: @escaping () -> Element,
        @ViewBuilder content: @escaping (Binding<Element>) -> RowContent
    ) -> some View {
        ForEach(rows) { $row in
            HStack(spacing: 6) {
                content($row)
                Spacer(minLength: 0)
                Button {
                    rows.wrappedValue.removeAll { $0.id == row.id }
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        Button {
            rows.wrappedValue.append(empty())
        } label: {
            Label(addLabel, systemImage: "plus.circle")
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Actions

    private func pickHostPath(for id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let idx = binds.firstIndex(where: { $0.id == id }) {
            binds[idx].host = url.path
        }
    }

    private func buildRequest() -> ContainerCreateRequest {
        let cmd: [String] = command
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }

        let envList: [String] = env
            .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "\($0.key)=\($0.value)" }

        let portMap: [String: String] = Dictionary(
            uniqueKeysWithValues: ports
                .filter { !$0.container.isEmpty }
                .map { ("\($0.container)/\($0.proto)", $0.host) }
        )

        let bindList: [String] = binds
            .filter { !$0.host.isEmpty && !$0.container.isEmpty }
            .map { $0.readOnly ? "\($0.host):\($0.container):ro" : "\($0.host):\($0.container)" }

        let trimmedName = name.trimmingCharacters(in: .whitespaces)

        return ContainerCreateRequest(
            image: image.trimmingCharacters(in: .whitespaces),
            cmd: cmd.isEmpty ? nil : cmd,
            env: envList,
            ports: portMap,
            binds: bindList,
            restartPolicy: restartPolicy,
            tty: tty,
            labels: [:],
            autoRemove: autoRemove,
            name: trimmedName.isEmpty ? nil : trimmedName
        )
    }

    private func create() async {
        errorText = nil
        imageMissing = false
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await session.createAndRun(buildRequest())
            dismiss()
        } catch let DockerError.apiError(status, message) {
            errorText = message
            imageMissing = (status == 404)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func pullAndRetry() async {
        errorText = nil
        imageMissing = false
        isWorking = true
        pullStatus = "Pulling \(image)…"
        defer { isWorking = false; pullStatus = nil }
        do {
            let stream = try await session.pullImage(reference: image.trimmingCharacters(in: .whitespaces))
            for try await progress in stream {
                // PullProgress shape is owned by the resources layer; render a
                // generic description so this stays decoupled from its fields.
                pullStatus = "Pulling \(image)… \(String(describing: progress))"
            }
            // Retry the create now that the image should be present.
            _ = try await session.createAndRun(buildRequest())
            dismiss()
        } catch let DockerError.apiError(_, message) {
            errorText = message
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Editor row models

private struct PortRow: Identifiable {
    let id = UUID()
    var host = ""
    var container = ""
    var proto = "tcp"
}

private struct EnvRow: Identifiable {
    let id = UUID()
    var key = ""
    var value = ""
}

private struct BindRow: Identifiable {
    let id = UUID()
    var host = ""
    var container = ""
    var readOnly = false
}
