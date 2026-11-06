import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AppCore

/// `container system kernel set`: shows whether a default kernel is installed
/// and installs the recommended kernel, a kernel file or a kernel from a tar
/// archive. Without a default kernel, no container can start.
struct AppleKernelPane: View {
    let session: HostSession

    private enum SourceChoice: String, CaseIterable, Identifiable {
        case recommended, file, archive
        var id: String { rawValue }
    }

    @State private var kernel: AppleKernelInfo?
    @State private var properties: [AppleSystemProperty] = []
    @State private var features: ContainerTooling.Features?
    @State private var errorText: String?
    @State private var installRequest: AppleKernelRequest?

    @State private var choice: SourceChoice = .recommended
    @State private var architecture: AppleKernelArchitecture = hostKernelArchitecture
    @State private var binaryPath = ""
    @State private var archiveLocation = ""
    @State private var archiveMember = ""
    @State private var digest = ""
    @State private var force = true

    private var cli: String? { session.appleCLIOverride }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppleSystemPaneHeader(pane: .kernel, badge: badge) {
                Button {
                    Task { await reload() }
                } label: {
                    Label(String(localized: "Refresh"), systemImage: "arrow.clockwise")
                }
                .onSectionCommand(.refresh, .system) { Task { await reload() } }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let errorText {
                        AppleSystemErrorBanner(message: errorText) { self.errorText = nil }
                    }
                    if let kernel, !kernel.isInstalled {
                        AppleKernelMissingCard { installRequest = .recommended }
                    }
                    currentCard
                    installCard
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(AppleSystemPane.kernel.title)
        .task { await reload() }
        .sheet(item: $installRequest, onDismiss: { Task { await reload() } }) { request in
            AppleKernelInstallSheet(
                cliOverride: cli,
                request: request,
                supportsDigest: features?.kernelArchiveDigest ?? true
            )
        }
    }

    private var badge: (text: String, tint: Color)? {
        guard let kernel else { return nil }
        return kernel.isInstalled
            ? (String(localized: "Installed"), .green)
            : (String(localized: "Not installed"), .orange)
    }

    private func property(_ key: String) -> String? {
        properties.first { $0.key == key }?.effective?.display
    }

    private var currentCard: some View {
        AppleSystemCard(title: String(localized: "Default Kernel"), systemImage: "cpu") {
            FactGrid {
                Fact(String(localized: "Architecture"), architectureLabel(kernel?.architecture ?? hostKernelArchitecture))
                Fact(String(localized: "Installed file"), kernel?.kernelFile ?? String(localized: "None"))
                if let url = property("kernel.url") { Fact(String(localized: "Recommended archive"), url) }
                if let member = property("kernel.binaryPath") { Fact(String(localized: "File in archive"), member) }
                if let digest = property("kernel.digest") { Fact(String(localized: "Digest"), digest) }
            }
            Text("The recommended kernel comes from the kernel.url system property. Containers that are running keep their kernel until they restart.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var installCard: some View {
        AppleSystemCard(title: String(localized: "Install a Kernel"), systemImage: "arrow.down.circle") {
            Picker(String(localized: "Source"), selection: $choice) {
                Text("Recommended").tag(SourceChoice.recommended)
                Text("Kernel file").tag(SourceChoice.file)
                Text("Tar archive").tag(SourceChoice.archive)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch choice {
            case .recommended:
                Text("Downloads the kernel that this apple/container version recommends and makes it the default.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .file:
                fileFields
            case .archive:
                archiveFields
            }

            if choice != .recommended {
                Picker(String(localized: "Architecture"), selection: $architecture) {
                    ForEach(AppleKernelArchitecture.allCases, id: \.self) { arch in
                        Text(architectureLabel(arch)).tag(arch)
                    }
                }
                .fixedSize()
            }
            Toggle(String(localized: "Replace a kernel with the same name"), isOn: $force)
                .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button(choice == .recommended
                       ? String(localized: "Install Recommended Kernel")
                       : String(localized: "Install Kernel")) {
                    install()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var fileFields: some View {
        HStack {
            TextField(String(localized: "Kernel file"), text: $binaryPath, prompt: Text(verbatim: "/path/to/vmlinux"))
                .textFieldStyle(.roundedBorder)
            Button(String(localized: "Choose…")) {
                if let path = choosePath(directoryAllowed: false) { binaryPath = path }
            }
        }
    }

    private var archiveFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(String(localized: "Archive"), text: $archiveLocation, prompt: Text(verbatim: "https://… or /path/to/kernel.tar"))
                    .textFieldStyle(.roundedBorder)
                Button(String(localized: "Choose…")) {
                    if let path = choosePath(directoryAllowed: false) { archiveLocation = path }
                }
            }
            TextField(String(localized: "Kernel file in the archive"), text: $archiveMember, prompt: Text(verbatim: "opt/kata/share/kata-containers/vmlinux"))
                .textFieldStyle(.roundedBorder)
            if features?.kernelArchiveDigest ?? true {
                TextField(String(localized: "Digest"), text: $digest, prompt: Text(verbatim: "sha256:…"))
                    .textFieldStyle(.roundedBorder)
                Text("A digest is required for a remote archive. apple/container checks the download against it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("This apple/container version cannot check an archive digest. Update to 1.2 or later to verify downloads.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func architectureLabel(_ arch: AppleKernelArchitecture) -> String {
        switch arch {
        case .arm64: String(localized: "arm64 (Apple silicon)")
        case .amd64: String(localized: "amd64 (Intel)")
        }
    }

    private func choosePath(directoryAllowed: Bool) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = directoryAllowed
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func install() {
        let source: AppleKernelSource
        switch choice {
        case .recommended: source = .recommended
        case .file: source = .binary(path: binaryPath)
        case .archive: source = .archive(location: archiveLocation, member: archiveMember, digest: digest)
        }
        let request = AppleKernelRequest(source: source, architecture: architecture, force: force)
        do {
            _ = try request.arguments(supportsDigest: features?.kernelArchiveDigest ?? true)
            errorText = nil
            installRequest = request
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func reload() async {
        features = await ContainerTooling.currentFeatures(cliOverride: cli)
        let status = try? await AppleContainerControl.systemStatus(cliOverride: cli)
        let root = status?.appRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
        kernel = AppleContainerControl.defaultKernel(appRoot: root, architecture: hostKernelArchitecture)
        properties = (try? await AppleContainerControl.listProperties(cliOverride: cli)) ?? []
    }
}

extension AppleKernelRequest: @retroactive Identifiable {
    public var id: String { (try? arguments()).map { $0.joined(separator: " ") } ?? "\(self)" }
}

/// A prominent notice that no default kernel is installed, with the fix.
struct AppleKernelMissingCard: View {
    let install: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("No default kernel is installed")
                    .font(.headline)
                Text("Containers cannot start until apple/container has a Linux kernel. Install the recommended kernel to fix this.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "Install Recommended Kernel")) { install() }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Runs one `container system kernel set` and shows its streamed output.
struct AppleKernelInstallSheet: View {
    let cliOverride: String?
    let request: AppleKernelRequest
    var supportsDigest = true

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    /// The install runs in the operation center, so closing the sheet does
    /// not stop it; Cancel does.
    @State private var operation: LongOperation?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            phaseView
            logView
            footer
        }
        .padding(20)
        .frame(width: 520)
        .task { if operation == nil { operation = start() } }
    }

    private var state: OperationState { operation?.state ?? .running }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu").font(.title).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(phaseColor)
            }
        }
    }

    private var title: String {
        request.source == .recommended
            ? String(localized: "Installing the Recommended Kernel")
            : String(localized: "Installing a Kernel")
    }

    @ViewBuilder
    private var phaseView: some View {
        switch state {
        case .running:
            if let fraction = operation?.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        case .succeeded:
            ProgressView(value: 1)
        case .failed(let message):
            AppleSystemErrorBanner(message: message)
        case .cancelled:
            AppleSystemErrorBanner(message: String(localized: "Cancelled."))
        }
    }

    private var logView: some View {
        let lines = operation?.log ?? []
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .frame(height: 160)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onChange(of: lines.count) {
                proxy.scrollTo(lines.count - 1, anchor: .bottom)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            if state == .running {
                Button(String(localized: "Cancel Install"), role: .destructive) {
                    if let operation { model.operations.cancel(operation) }
                }
                Button(String(localized: "Continue in Background")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help(String(localized: "The install keeps running. Follow it in Activity."))
            } else {
                Button(String(localized: "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var statusText: String {
        switch state {
        case .running: String(localized: "Downloading and installing. This can take a few minutes.")
        case .succeeded: String(localized: "The kernel is installed. New containers boot with it.")
        case .failed, .cancelled: String(localized: "The kernel could not be installed.")
        }
    }

    private var phaseColor: Color {
        switch state {
        case .running: .secondary
        case .succeeded: .green
        case .failed, .cancelled: .red
        }
    }

    private func start() -> LongOperation {
        let request = request, supportsDigest = supportsDigest, cliOverride = cliOverride
        return model.operations.run(.kernelInstall, title: title, host: String(localized: "apple/container")) { op in
            let stream = try AppleContainerControl.installKernel(
                request,
                supportsDigest: supportsDigest,
                cliOverride: cliOverride
            )
            for try await line in stream {
                op.append(log: line)
                if let value = AppleContainerControl.progressFraction(in: line) {
                    op.update(progress: nil, fraction: value)
                }
            }
            try Task.checkCancellation()
            return String(localized: "The kernel is installed.")
        }
    }
}

/// Puts the kernel fix next to an error that says the default kernel is
/// missing: the alert gets an "Install Recommended Kernel" action that opens
/// the install sheet.
struct AppleMissingKernelAlert: ViewModifier {
    let session: HostSession
    @State private var installing = false

    private var isPresented: Binding<Bool> {
        Binding(
            get: { session.host.isAppleContainer && Self.isKernelError(session.lastError) },
            set: { if !$0 { session.lastError = nil } }
        )
    }

    static func isKernelError(_ message: String?) -> Bool {
        guard let message else { return false }
        return AppleContainerControl.isMissingKernelError(message)
    }

    func body(content: Content) -> some View {
        content
            .alert(String(localized: "No Default Kernel"), isPresented: isPresented) {
                Button(String(localized: "Install Recommended Kernel")) {
                    session.lastError = nil
                    installing = true
                }
                Button(String(localized: "Cancel"), role: .cancel) { session.lastError = nil }
            } message: {
                Text("apple/container has no Linux kernel to boot the container with. Install the recommended kernel, then start the container again.\n\n\(session.lastError ?? "")")
            }
            .sheet(isPresented: $installing) {
                AppleKernelInstallSheet(cliOverride: session.appleCLIOverride, request: .recommended)
            }
    }
}

/// Shown on an apple host's overview only while no default kernel is
/// installed, so the reason containers cannot start is visible at once.
struct AppleKernelOverviewBanner: View {
    let session: HostSession

    @State private var missing = false
    @State private var installing = false

    var body: some View {
        Group {
            if missing {
                AppleKernelMissingCard { installing = true }
            }
        }
        .task(id: session.id) { await check() }
        .sheet(isPresented: $installing, onDismiss: { Task { await check() } }) {
            AppleKernelInstallSheet(cliOverride: session.appleCLIOverride, request: .recommended)
        }
    }

    private func check() async {
        guard session.host.isAppleContainer,
              let status = try? await AppleContainerControl.systemStatus(cliOverride: session.appleCLIOverride),
              status.isRunning else {
            missing = false
            return
        }
        let root = status.appRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
        missing = !AppleContainerControl.defaultKernel(appRoot: root, architecture: hostKernelArchitecture).isInstalled
    }
}
