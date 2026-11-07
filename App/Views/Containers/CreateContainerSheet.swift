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
    /// apple/container DNS domain to launch on ("" = none), and the domains
    /// available locally to pick from.
    @State private var domain = ""
    @State private var availableDomains: [String] = []
    /// apple/container custom kernel binary ("" = the CLI's default kernel) and
    /// the raw boot arguments appended to its command line.
    @State private var kernelPath = ""
    @State private var kernelArgs: [KernelArgRow] = []
    /// nil until the CLI version is known; gates the socket-mount hint and the
    /// kernel-argument editor.
    @State private var appleFeatures: ContainerTooling.Features?

    @State private var isWorking = false
    @State private var errorText: String?
    /// Set when create failed with a 404; offers a pull-and-retry button.
    @State private var imageMissing = false
    @State private var pullStatus: String?
    /// Which button started the create, so a pull-and-retry repeats it.
    @State private var startAfterCreate = true
    /// Set when the daemon refused the name; shown under the Name field.
    @State private var nameError: String?
    /// Set when the new container stopped right after it started.
    @State private var earlyExit: StartedContainerExit?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// The command split like a POSIX shell does it, or the parse error.
    private var parsedCommand: Result<[String], Error> {
        Result { try ShellWords.split(command) }
    }

    private var commandError: String? {
        if case .failure(let error) = parsedCommand { return error.localizedDescription }
        return nil
    }

    private var portEntries: [ContainerForm.PortEntry] {
        ports.map { ContainerForm.PortEntry(host: $0.host, container: $0.container, proto: $0.proto) }
    }

    /// Port problems keyed by row id, so each row can show its own.
    private var portIssues: [UUID: ContainerForm.PortIssue] {
        let byIndex = ContainerForm.portIssues(portEntries)
        return Dictionary(byIndex.map { (ports[$0.key].id, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    /// An invalid name, or one that another container on this host uses.
    private var nameIssue: String? {
        ContainerForm.nameIssue(name, taken: ContainerForm.takenNames(session.containers))
    }

    private var canCreate: Bool {
        !image.trimmingCharacters(in: .whitespaces).isEmpty && !isWorking
            && commandError == nil && portIssues.isEmpty && nameIssue == nil
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
                Section("General") {
                    TextField("Image", text: $image, prompt: Text("Repository and tag"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Name (optional)", text: $name, prompt: Text("Generated if empty"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: name) { nameError = nil }
                    FieldError(message: nameIssue ?? nameError)
                    TextField("Command (optional)", text: $command, prompt: Text("The image's default command"))
                        .textFieldStyle(.roundedBorder)
                    FieldError(message: commandError)
                }

                Section {
                    editorRows(
                        $ports,
                        addLabel: "Add Port",
                        empty: { PortRow() }
                    ) { $row in
                        TextField("Host", text: $row.host, prompt: Text("Host port"))
                            .frame(width: 90)
                        Text(verbatim: ":").foregroundStyle(.secondary)
                        TextField("Container", text: $row.container, prompt: Text("Container port"))
                            .frame(width: 110)
                        Picker("Protocol", selection: $row.proto) {
                            Text(verbatim: "tcp").tag("tcp")
                            Text(verbatim: "udp").tag("udp")
                        }
                        .labelsHidden()
                        .frame(width: 70)
                        PortIssueIcon(issue: portIssues[row.id])
                    }
                } header: {
                    Text("Ports")
                } footer: {
                    FieldError(message: portIssues.values.first?.message)
                }

                Section("Environment") {
                    editorRows(
                        $env,
                        addLabel: "Add Variable",
                        empty: { EnvRow() }
                    ) { $row in
                        TextField("KEY", text: $row.key)
                        Text(verbatim: "=").foregroundStyle(.secondary)
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
                        .help("Choose a host folder")
                        .accessibilityLabel("Choose a host folder")
                        Text(verbatim: ":").foregroundStyle(.secondary)
                        TextField("Container path", text: $row.container)
                        Toggle("ro", isOn: $row.readOnly)
                            .toggleStyle(.checkbox)
                    }
                    if let note = socketMountNote {
                        Label(note, systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if session.host.isAppleContainer {
                    networkingSection
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

                if session.host.isAppleContainer {
                    kernelSection
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

            footer
        }
        .frame(width: 560, height: 640)
        .startedContainerExitAlert($earlyExit, session: session) { dismiss() }
        .task {
            if session.host.isAppleContainer {
                appleFeatures = await ContainerTooling.currentFeatures(cliOverride: session.appleCLIOverride)
                availableDomains = (try? await AppleContainerControl.listDomains(
                    cliOverride: session.host.socketPathOverride
                )) ?? []
                // Assign a DNS domain by default so the container resolves by name.
                if domain.isEmpty {
                    domain = DefaultDNSDomain.preferred(in: availableDomains)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if isWorking { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create") {
                Task { await create(run: false) }
            }
            .disabled(!canCreate)
            .help("Create the container without starting it")
            Button("Create and Run") {
                Task { await create(run: true) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canCreate)
        }
        .padding()
    }

    /// DNS-domain picker for apple/container hosts: launch a container on a local
    /// domain so it resolves as `name.domain` across the Mac. Mirrors Quick Run.
    private var networkingSection: some View {
        Section {
            if availableDomains.isEmpty {
                NoLocalDomainsRow()
            } else {
                Picker("DNS domain", selection: $domain) {
                    Text("None").tag("")
                    ForEach(availableDomains, id: \.self) { Text($0).tag($0) }
                }
                let trimmedName = name.trimmingCharacters(in: .whitespaces)
                if !domain.isEmpty, !trimmedName.isEmpty {
                    Text("Reachable as \(trimmedName).\(domain)")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("Networking")
        }
    }

    /// apple/container boot options. Both are power-user knobs and both are
    /// optional: left alone, the container boots the CLI's own kernel with its
    /// default command line, which is what every other sheet does.
    private var kernelSection: some View {
        Section {
            HStack(spacing: 6) {
                TextField("Kernel", text: $kernelPath, prompt: Text("Default kernel"))
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") { pickKernelPath() }
                    .buttonStyle(.borderless)
            }
            if appleFeatures?.kernelArguments ?? true {
                editorRows(
                    $kernelArgs,
                    addLabel: "Add Boot Argument",
                    empty: { KernelArgRow() }
                ) { $row in
                    TextField("Argument", text: $row.value, prompt: Text("key=value"))
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                Label(
                    "Kernel boot arguments need apple/container \(ContainerTooling.kernelArgumentsVersion) or newer.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("Kernel")
        } footer: {
            Text("Boot arguments are appended to the kernel command line. The CLI's own defaults still apply unless an argument overrides the same key.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Reusable editor list

    @ViewBuilder
    private func editorRows<Element: Identifiable, RowContent: View>(
        _ rows: Binding<[Element]>,
        addLabel: LocalizedStringKey,
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
                .help("Remove row")
                .accessibilityLabel("Remove row")
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

    /// A note shown once a Unix socket is bound in: apple/container only mounts
    /// sockets with the right permissions for non-root containers from 1.1 on,
    /// so an older CLI is worth calling out before the container fails to talk
    /// through it.
    private var socketMountNote: String? {
        guard session.host.isAppleContainer,
              binds.contains(where: { MachineCapabilities.isUnixSocket($0.host) }) else { return nil }
        if appleFeatures?.nonRootSocketMounts ?? true {
            return String(localized: "Unix socket mount — permissions are propagated into the container, including when it runs as a non-root user.")
        }
        return String(localized: "Unix socket mount — containers that run as a non-root user need apple/container \(ContainerTooling.socketMountVersion) or newer to use it.")
    }

    private func pickHostPath(for id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        // Sockets commonly live under hidden or system paths (/var/run, ~/.),
        // so let the panel reach them.
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let idx = binds.firstIndex(where: { $0.id == id }) {
            binds[idx].host = url.path
        }
    }

    /// Picks the custom kernel binary. A kernel is a plain file (an uncompressed
    /// `bzImage` or similar), and they are usually kept out of the way, so the
    /// panel allows hidden paths but not directories.
    private func pickKernelPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        kernelPath = url.path
    }

    private func buildRequest() -> ContainerCreateRequest {
        // `canCreate` blocks a command that does not parse.
        let cmd: [String] = (try? parsedCommand.get()) ?? []

        let envList: [String] = env
            .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "\($0.key)=\($0.value)" }

        let portMap = ContainerForm.portMap(portEntries)

        let bindList: [String] = binds
            .filter { !$0.host.isEmpty && !$0.container.isEmpty }
            .map { $0.readOnly ? "\($0.host):\($0.container):ro" : "\($0.host):\($0.container)" }

        let trimmedImage = image.trimmingCharacters(in: .whitespaces)
        let trimmedDomain = domain.trimmingCharacters(in: .whitespaces)
        // Record the domain as a label so the container's address view can show
        // the resolvable hostname reliably later (matches Quick Run).
        var labels = trimmedDomain.isEmpty ? [:] : [AppleAddressSection.domainLabelKey: trimmedDomain]

        // A DNS name needs a container name; auto-derive a unique one from the
        // image when a domain is assigned and the user left the name blank.
        let resolvedName: String?
        if !trimmedName.isEmpty {
            resolvedName = trimmedName
        } else if !trimmedDomain.isEmpty {
            resolvedName = session.uniqueContainerName(forImage: trimmedImage)
        } else {
            resolvedName = nil
        }

        // Kernel options only exist on apple/container, and boot arguments only
        // from 1.2 on — drop them rather than send a flag the CLI would reject.
        let trimmedKernel = kernelPath.trimmingCharacters(in: .whitespaces)
        let argList: [String] = (appleFeatures?.kernelArguments ?? true)
            ? kernelArgs.map { $0.value.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : []
        let appleOptions: ContainerCreateRequest.AppleOptions? = session.host.isAppleContainer
            ? ContainerCreateRequest.AppleOptions(
                kernel: trimmedKernel.isEmpty ? nil : trimmedKernel,
                kernelArgs: argList
            )
            : nil
        // Stamp the kernel options as labels too: inspect doesn't report them,
        // so this is what lets a later recreate boot the same way.
        labels.merge(appleOptions?.labels ?? [:]) { _, new in new }

        return ContainerCreateRequest(
            image: trimmedImage,
            cmd: cmd.isEmpty ? nil : cmd,
            env: envList,
            ports: portMap,
            binds: bindList,
            restartPolicy: restartPolicy,
            tty: tty,
            labels: labels,
            autoRemove: autoRemove,
            domainname: trimmedDomain.isEmpty ? nil : trimmedDomain,
            appleOptions: appleOptions,
            name: resolvedName
        )
    }

    private func create(run: Bool) async {
        errorText = nil
        nameError = nil
        imageMissing = false
        startAfterCreate = run
        isWorking = true
        defer { isWorking = false }
        do {
            try await createAndMaybeRun()
        } catch {
            show(error)
        }
    }

    /// "Create" makes the container and closes; "Create and Run" also starts
    /// it and watches for an early exit.
    private func createAndMaybeRun() async throws {
        if startAfterCreate {
            try await runAndWatch()
        } else {
            _ = try await session.createContainer(buildRequest())
            dismiss()
        }
    }

    /// Creates and starts the container, then watches it for a few seconds:
    /// a container that stops at once gets the exit alert, not a silent close.
    private func runAndWatch() async throws {
        let request = buildRequest()
        let id = try await session.createAndRun(request)
        pullStatus = String(localized: "Starting…")
        defer { pullStatus = nil }
        if let exit = await session.earlyExit(containerID: id) {
            earlyExit = StartedContainerExit(
                hostID: session.host.id,
                containerID: id,
                name: request.name ?? String(id.prefix(12)),
                exitCode: exit.exitCode
            )
        } else {
            dismiss()
        }
    }

    /// Routes a create failure to the right inline place.
    private func show(_ error: Error) {
        if !trimmedName.isEmpty, ContainerForm.isNameConflict(error) {
            nameError = ContainerForm.nameInUseMessage(trimmedName)
        } else if case let DockerError.apiError(status, message) = error {
            errorText = message
            imageMissing = (status == 404)
        } else {
            errorText = error.localizedDescription
        }
    }

    private func pullAndRetry() async {
        errorText = nil
        imageMissing = false
        isWorking = true
        let reference = image.trimmingCharacters(in: .whitespaces)
        pullStatus = String(localized: "Pulling \(reference)…")
        defer { isWorking = false; pullStatus = nil }
        do {
            let stream = try await session.pullImage(reference: reference)
            for try await progress in stream {
                pullStatus = PullStatusText.line(reference: reference, progress: progress)
            }
            // Retry the create now that the image should be present.
            pullStatus = nil
            try await createAndMaybeRun()
        } catch {
            show(error)
            imageMissing = false
        }
    }
}

/// One readable status line for a pull in progress.
enum PullStatusText {
    static func line(reference: String, progress: PullProgress) -> String {
        if let current = progress.current, let total = progress.total, total > 0 {
            let done = Formatters.bytes(current, style: .file)
            let all = Formatters.bytes(total, style: .file)
            return String(localized: "Pulling \(reference)… \(progress.status) \(done) of \(all)")
        }
        if progress.status.isEmpty { return String(localized: "Pulling \(reference)…") }
        return String(localized: "Pulling \(reference)… \(progress.status)")
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

private struct KernelArgRow: Identifiable {
    let id = UUID()
    var value = ""
}
