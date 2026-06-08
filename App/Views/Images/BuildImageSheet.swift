import SwiftUI
import AppCore
import DockerKit
import UniformTypeIdentifiers

/// Sheet that builds an image from a dropped (or opened) Dockerfile on any host
/// — local Docker, a remote Docker over SSH, or apple/container — and streams
/// the build log live.
struct BuildImageSheet: View {
    let dockerfileURL: URL

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var contextURL: URL
    @State private var tag: String
    @State private var selectedHostID: UUID?
    @State private var target = ""
    @State private var noCache = false
    @State private var buildArgs: [LabelPair] = []

    @State private var phase: Phase = .idle
    @State private var logText = ""
    @State private var builtImageID: String?
    @State private var buildTask: Task<Void, Never>?

    private enum Phase: Equatable {
        case idle
        case building
        case done
        case failed(String)
    }

    init(dockerfileURL: URL) {
        self.dockerfileURL = dockerfileURL
        let context = dockerfileURL.deletingLastPathComponent()
        _contextURL = State(initialValue: context)
        _tag = State(initialValue: Self.defaultTag(forContext: context))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 580, height: 600)
        .onAppear {
            if selectedHostID == nil {
                selectedHostID = model.sessions.first { $0.status.isConnected }?.id
                    ?? model.sessions.first?.id
            }
        }
        .onDisappear { buildTask?.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Build Image")
                    .font(.title2.weight(.semibold))
                Text(dockerfileURL.lastPathComponent)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            configForm
        case .building, .done, .failed:
            buildLog
        }
    }

    private var configForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                labeled("Tag") {
                    TextField("name:tag", text: $tag)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }

                labeled("Host") {
                    if model.sessions.isEmpty {
                        Text("Add a host first").foregroundStyle(.secondary)
                    } else {
                        Picker("", selection: $selectedHostID) {
                            ForEach(model.sessions) { session in
                                Text(session.host.name).tag(Optional(session.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 240)
                    }
                }

                labeled("Context") {
                    HStack(spacing: 8) {
                        Text(contextURL.path)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(contextContainsDockerfile ? Color.primary : Color.red)
                        Button("Choose…", action: chooseContext)
                            .controlSize(.small)
                    }
                }

                if !contextContainsDockerfile {
                    Label(
                        "The Dockerfile must live inside the build context.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                DisclosureGroup("Options") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Target stage").frame(width: 90, alignment: .leading)
                            TextField("(final stage)", text: $target)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 200)
                        }
                        Toggle("Build without cache", isOn: $noCache)
                            .toggleStyle(.checkbox)
                        buildArgsEditor
                    }
                    .padding(.top, 6)
                }
                .font(.callout)
            }
            .padding(16)
        }
    }

    private var buildArgsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Build args").font(.callout)
                Spacer()
                Button {
                    buildArgs.append(LabelPair())
                } label: {
                    Label("Add", systemImage: "plus").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }
            if buildArgs.isEmpty {
                Text("None").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach($buildArgs) { $pair in
                    HStack(spacing: 6) {
                        TextField("ARG", text: $pair.key)
                            .textFieldStyle(.roundedBorder)
                        TextField("value", text: $pair.value)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            buildArgs.removeAll { $0.id == pair.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var buildLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(logText.isEmpty ? "Starting build…" : logText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("logBottom")
                }
                .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: logText) {
                withAnimation { proxy.scrollTo("logBottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if case .done = phase {
                    statusBadge("Build complete", "checkmark.circle.fill", .green)
                } else if case .failed = phase {
                    statusBadge("Build failed", "xmark.octagon.fill", .red)
                }
            }
        }
    }

    private func statusBadge(_ text: String, _ icon: String, _ color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(8)
            .background(.regularMaterial, in: Capsule())
            .padding(12)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if phase == .building { ProgressView().controlSize(.small) }
            if let builtImageID, phase == .done {
                Text("Image \(String(builtImageID.prefix(19)))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(closeButtonTitle) {
                buildTask?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            if phase != .done {
                Button("Build") { startBuild() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canBuild)
            }
        }
        .padding(16)
    }

    private var closeButtonTitle: String {
        switch phase {
        case .done: "Done"
        case .building: "Cancel"
        default: "Cancel"
        }
    }

    // MARK: - Derived state

    private var contextContainsDockerfile: Bool {
        relativeDockerfilePath != nil
    }

    /// The Dockerfile path relative to the chosen context, or nil when the
    /// Dockerfile is not inside the context directory.
    private var relativeDockerfilePath: String? {
        let contextComponents = contextURL.standardizedFileURL.pathComponents
        let fileComponents = dockerfileURL.standardizedFileURL.pathComponents
        guard fileComponents.count > contextComponents.count,
              Array(fileComponents.prefix(contextComponents.count)) == contextComponents else {
            return nil
        }
        return fileComponents.dropFirst(contextComponents.count).joined(separator: "/")
    }

    private var canBuild: Bool {
        phase != .building
            && !tag.trimmingCharacters(in: .whitespaces).isEmpty
            && selectedHostID != nil
            && contextContainsDockerfile
    }

    // MARK: - Actions

    private func chooseContext() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = contextURL
        panel.message = "Choose the build context directory (must contain the Dockerfile)"
        if panel.runModal() == .OK, let url = panel.url {
            contextURL = url
        }
    }

    private func startBuild() {
        guard canBuild, let hostID = selectedHostID,
              let session = model.session(id: hostID),
              let dockerfile = relativeDockerfilePath else { return }

        let spec = ImageBuildSpec(
            contextPath: contextURL.path,
            dockerfile: dockerfile,
            tag: tag.trimmingCharacters(in: .whitespaces),
            buildArgs: buildArgs.asDictionary,
            target: target.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            noCache: noCache
        )

        phase = .building
        logText = ""
        builtImageID = nil

        buildTask = Task {
            if !session.status.isConnected {
                append("Connecting to \(session.host.name)…\n")
                await session.connect()
            }
            guard session.status.isConnected else {
                phase = .failed("Not connected")
                append("Could not connect to \(session.host.name).\n")
                return
            }
            do {
                let stream = try session.buildImageStream(spec)
                for try await line in stream {
                    if let id = line.imageID { builtImageID = id }
                    if !line.text.isEmpty { append(line.text) }
                }
                phase = .done
                if logText.isEmpty { append("Build complete.\n") }
            } catch is CancellationError {
                // Sheet closing.
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                append("\nError: \(message)\n")
                phase = .failed(message)
            }
        }
    }

    private func append(_ text: String) {
        logText += text
    }

    private func labeled<V: View>(_ title: String, @ViewBuilder _ value: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline).frame(width: 70, alignment: .leading)
            value()
            Spacer()
        }
    }

    // MARK: - Defaults

    /// Derives a sane default tag from the context directory name, sanitized to
    /// the lowercase `[a-z0-9._-]` Docker repositories require.
    static func defaultTag(forContext context: URL) -> String {
        let raw = context.lastPathComponent.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        var name = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        if name.isEmpty { name = "image" }
        return "\(name):latest"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
