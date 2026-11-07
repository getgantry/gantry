import SwiftUI
import AppKit
import AppCore
import DockerKit

/// Sheet for creating and running a new container. Mirrors the common
/// `docker run` knobs and reads them from a pasted command or a saved
/// recipe (``ContainerRecipe``). On a 404 from create (image missing
/// locally) it offers to pull the image and retry.
struct CreateContainerSheet: View {
    @Bindable var session: HostSession
    @Environment(\.dismiss) private var dismiss

    @State private var image = ""
    @State private var name = ""
    @State private var command = ""
    @State private var entrypoint = ""
    @State private var ports: [PortRow] = []
    @State private var env: [EnvRow] = []
    /// `--env-file` paths from a pasted command; kept, not read.
    @State private var envFiles: [String] = []
    @State private var binds: [BindRow] = []
    @State private var labels: [EnvRow] = []
    @State private var network = ""
    @State private var restartPolicy = "no"
    @State private var cpus = ""
    @State private var memory = ""
    @State private var workdir = ""
    @State private var user = ""
    @State private var tty = false
    @State private var interactive = false
    @State private var autoRemove = false
    /// Only kept for "Copy as Command": Gantry always runs in the background.
    @State private var detach = true
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

    @State private var showPasteSheet = false
    /// The last pasted command, for its list of flags that were not used.
    @State private var pasted: RunCommandParser.Result?
    @State private var showSavePrompt = false
    @State private var recipeName = ""
    @State private var store = RecipeStore.shared

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
            && currentRecipe.cpusIssue == nil && currentRecipe.memoryIssue == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header

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
                    TextField("Entrypoint (optional)", text: $entrypoint, prompt: Text("The image's default entrypoint"))
                        .textFieldStyle(.roundedBorder)
                }

                if let pasted, !(pasted.unsupported.isEmpty && pasted.notes.isEmpty) {
                    pastedSection(pasted)
                }

                Section {
                    editorRows(
                        $ports,
                        addLabel: "Add Port",
                        empty: { PortRow() }
                    ) { $row in
                        TextField("Host IP", text: $row.hostIP, prompt: Text("All"))
                            .frame(width: 80)
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
                    envFileRows
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
                        BindSourceMenu(session: session) { row.host = $0 }
                        Text(verbatim: ":").foregroundStyle(.secondary)
                        TextField("Container path", text: $row.container)
                        Toggle("ro", isOn: $row.readOnly)
                            .toggleStyle(.checkbox)
                    }
                    BindMountWarnings(session: session, paths: binds.map(\.host))
                    if let note = socketMountNote {
                        Label(note, systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                labelsSection

                networkingSection

                optionsSection

                resourcesSection

                if session.host.isAppleContainer {
                    kernelSection
                }

                hostWarningsSection

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
        .frame(width: 600, height: 700)
        .startedContainerExitAlert($earlyExit, session: session) { dismiss() }
        .sheet(isPresented: $showPasteSheet) {
            PasteCommandSheet(isAppleHost: session.host.isAppleContainer) { result in
                apply(result.recipe)
                pasted = result
            }
        }
        .saveRecipePrompt(isPresented: $showSavePrompt, name: $recipeName, store: store) { currentRecipe }
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

    /// The network, and on apple/container hosts the DNS domain: a container on
    /// a local domain resolves as `name.domain` across the Mac.
    private var networkingSection: some View {
        Section {
            networkField
            if session.host.isAppleContainer {
                domainRows
            }
        } header: {
            Text("Networking")
        }
    }

    @ViewBuilder
    private var domainRows: some View {
        if availableDomains.isEmpty {
            NoLocalDomainsRow()
        } else {
            Picker("DNS domain", selection: $domain) {
                Text("None").tag("")
                ForEach(availableDomains, id: \.self) { Text($0).tag($0) }
            }
            if !domain.isEmpty, !trimmedName.isEmpty {
                Text("Reachable as \(trimmedName).\(domain)")
                    .font(.caption).foregroundStyle(.tertiary)
            }
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

    // MARK: - Header and recipes

    private var header: some View {
        HStack(spacing: 8) {
            Text("New Container")
                .font(.title2.weight(.semibold))
            Spacer()
            recipesMenu
            copyMenu
            Button {
                showPasteSheet = true
            } label: {
                Label("Paste Command…", systemImage: "doc.on.clipboard")
            }
            .help("Fill the form from a docker run or container run command")
        }
        .padding()
    }

    private var recipesMenu: some View {
        Menu {
            Button("Save as Recipe…") {
                recipeName = trimmedName.isEmpty ? ContainerForm.baseName(forImage: image) : trimmedName
                showSavePrompt = true
            }
            .disabled(image.trimmingCharacters(in: .whitespaces).isEmpty)
            if !store.recipes.isEmpty {
                Divider()
                Section("Fill from Recipe") {
                    ForEach(store.recipes) { saved in
                        Button(saved.name) {
                            apply(saved.recipe)
                            pasted = nil
                        }
                    }
                }
                Divider()
                deleteRecipeMenu
            }
        } label: {
            Label("Recipes", systemImage: "book.closed")
        }
        .fixedSize()
        .help("Save the form as a recipe, or fill it from a saved recipe")
    }

    private var deleteRecipeMenu: some View {
        Menu("Delete Recipe") {
            ForEach(store.recipes) { saved in
                Button(saved.name, role: .destructive) { store.delete(id: saved.id) }
            }
        }
    }

    private var copyMenu: some View {
        Menu {
            Button {
                copyToPasteboard(RunCommandFormatter.command(for: currentRecipe, dialect: .docker))
            } label: {
                Text(verbatim: "docker run")
            }
            Button {
                copyToPasteboard(RunCommandFormatter.command(for: currentRecipe, dialect: .appleContainer))
            } label: {
                Text(verbatim: "container run")
            }
        } label: {
            Label("Copy as Command", systemImage: "terminal")
        }
        .fixedSize()
        .disabled(image.trimmingCharacters(in: .whitespaces).isEmpty || commandError != nil)
        .help("Copy the form as a command")
    }

    private func pastedSection(_ result: RunCommandParser.Result) -> some View {
        Section {
            RunCommandIssuesList(result: result, hostWarnings: [])
        } header: {
            HStack {
                Text("From the Pasted Command")
                Spacer()
                Button {
                    pasted = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Hide this list")
                .accessibilityLabel("Hide this list")
            }
        }
    }

    // MARK: - More sections

    @ViewBuilder
    private var envFileRows: some View {
        ForEach(envFiles, id: \.self) { file in
            HStack(spacing: 6) {
                Label(file, systemImage: "doc.text")
                    .font(.callout)
                Spacer(minLength: 0)
                Button {
                    envFiles.removeAll { $0 == file }
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove row")
                .accessibilityLabel("Remove row")
            }
        }
        if !envFiles.isEmpty {
            Text("Gantry does not read env files. Add their variables by hand.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var labelsSection: some View {
        Section("Labels") {
            editorRows(
                $labels,
                addLabel: "Add Label",
                empty: { EnvRow() }
            ) { $row in
                TextField("Key", text: $row.key)
                Text(verbatim: "=").foregroundStyle(.secondary)
                TextField("Value", text: $row.value)
            }
        }
    }

    private var networkField: some View {
        HStack(spacing: 6) {
            TextField("Network", text: $network, prompt: Text("Default network"))
                .textFieldStyle(.roundedBorder)
            Menu {
                ForEach(session.networks.map(\.name).sorted(), id: \.self) { name in
                    Button(name) { network = name }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(session.networks.isEmpty)
            .help("Choose a network")
            .accessibilityLabel("Choose a network")
        }
    }

    private var optionsSection: some View {
        Section("Options") {
            if session.host.capabilities.restartPolicy {
                Picker("Restart Policy", selection: $restartPolicy) {
                    ForEach(RestartPolicyOption.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }
            Toggle("Allocate a TTY", isOn: $tty)
            Toggle("Keep stdin open (-i)", isOn: $interactive)
            Toggle("Remove on exit (--rm)", isOn: $autoRemove)
        }
    }

    private var resourcesSection: some View {
        Section("Process and Limits") {
            TextField("Working directory", text: $workdir, prompt: Text("The image's default"))
                .textFieldStyle(.roundedBorder)
            TextField("User", text: $user, prompt: Text("The image's default"))
                .textFieldStyle(.roundedBorder)
            TextField("CPUs", text: $cpus, prompt: Text("No limit"))
                .textFieldStyle(.roundedBorder)
            FieldError(message: currentRecipe.cpusIssue)
            TextField("Memory", text: $memory, prompt: Text("No limit, for example 512m"))
                .textFieldStyle(.roundedBorder)
            FieldError(message: currentRecipe.memoryIssue)
        }
    }

    @ViewBuilder
    private var hostWarningsSection: some View {
        let warnings = currentRecipe.hostWarnings(isAppleHost: session.host.isAppleContainer)
        if !warnings.isEmpty || store.lastError != nil {
            Section {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                }
                FieldError(message: store.lastError)
            }
        }
    }

    // MARK: - Recipe mapping

    /// The form as a recipe.
    private var currentRecipe: ContainerRecipe {
        var recipe = ContainerRecipe(image: image.trimmingCharacters(in: .whitespaces))
        recipe.name = trimmedName
        recipe.command = (try? parsedCommand.get()) ?? []
        recipe.entrypoint = entrypoint.trimmingCharacters(in: .whitespaces)
        recipe.ports = ports.map { .init(hostIP: $0.hostIP, host: $0.host, container: $0.container, proto: $0.proto) }
        recipe.env = env.map { .init(key: $0.key, value: $0.value) }
        recipe.envFiles = envFiles
        recipe.volumes = binds.map { .init(source: $0.host, target: $0.container, readOnly: $0.readOnly) }
        recipe.labels = labels.map { .init(key: $0.key, value: $0.value) }
        recipe.network = network.trimmingCharacters(in: .whitespaces)
        recipe.restartPolicy = restartPolicy
        recipe.cpus = cpus
        recipe.memory = memory
        recipe.workdir = workdir
        recipe.user = user
        recipe.tty = tty
        recipe.interactive = interactive
        recipe.autoRemove = autoRemove
        recipe.detach = detach
        if session.host.isAppleContainer {
            recipe.dnsDomain = domain.trimmingCharacters(in: .whitespaces)
            recipe.kernel = kernelPath.trimmingCharacters(in: .whitespaces)
            recipe.kernelArgs = kernelArgs.map(\.value)
        }
        return recipe
    }

    /// Fills every field from `recipe`. An empty DNS domain keeps the
    /// default domain the sheet picked.
    private func apply(_ recipe: ContainerRecipe) {
        image = recipe.image
        name = recipe.name
        command = ShellQuoting.join(recipe.command)
        entrypoint = recipe.entrypoint
        ports = recipe.ports.map { PortRow(hostIP: $0.hostIP, host: $0.host, container: $0.container, proto: $0.proto) }
        env = recipe.env.map { EnvRow(key: $0.key, value: $0.value) }
        envFiles = recipe.envFiles
        binds = recipe.volumes.map { BindRow(host: $0.source, container: $0.target, readOnly: $0.readOnly) }
        labels = recipe.labels.map { EnvRow(key: $0.key, value: $0.value) }
        network = recipe.network
        restartPolicy = ContainerRecipe.restartPolicies.contains(recipe.restartPolicy) ? recipe.restartPolicy : "no"
        cpus = recipe.cpus
        memory = recipe.memory
        workdir = recipe.workdir
        user = recipe.user
        tty = recipe.tty
        interactive = recipe.interactive
        autoRemove = recipe.autoRemove
        detach = recipe.detach
        if !recipe.dnsDomain.isEmpty {
            if !availableDomains.contains(recipe.dnsDomain) { availableDomains.append(recipe.dnsDomain) }
            domain = recipe.dnsDomain
        }
        kernelPath = recipe.kernel
        kernelArgs = recipe.kernelArgs.map { KernelArgRow(value: $0) }
        errorText = nil
        nameError = nil
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
        let recipe = currentRecipe
        // A DNS name needs a container name; auto-derive a unique one from the
        // image when a domain is assigned and the user left the name blank.
        let resolvedName: String?
        if !trimmedName.isEmpty {
            resolvedName = trimmedName
        } else if session.host.isAppleContainer, !recipe.dnsDomain.isEmpty {
            resolvedName = session.uniqueContainerName(forImage: recipe.image)
        } else {
            resolvedName = nil
        }
        // Boot arguments only exist from apple/container 1.2 on.
        return recipe.createRequest(
            name: resolvedName,
            isAppleHost: session.host.isAppleContainer,
            kernelArgsSupported: appleFeatures?.kernelArguments ?? true
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
    var hostIP = ""
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
