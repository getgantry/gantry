import SwiftUI
import AppCore
import DockerKit

/// Sheet that brings a `docker-compose` file up on any connected host.
///
/// Presented when a Compose file is opened from Finder (Open With / Quick
/// Action) or the File menu. Parses the file, lets the user pick the target host
/// (local Docker, SSH or apple/container), optionally edit the YAML inline, and
/// streams the `up` progress.
struct ComposeUpSheet: View {
    let fileURL: URL

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var project: ComposeProject?
    @State private var parseError: String?
    @State private var selectedHostID: UUID?
    @State private var recreate = true
    @State private var noCache = false

    @State private var editingYAML = false
    @State private var yamlText = ""
    @State private var yamlError: String?

    @State private var running = false
    @State private var finished = false
    @State private var runError: String?
    @State private var log: [LogLine] = []
    /// The deploy in the operation center: Stop cancels it, and closing
    /// the sheet lets it go on in the background.
    @State private var operation: LongOperation?

    private struct LogLine: Identifiable {
        let id = UUID()
        let text: String
        let kind: Kind
        enum Kind { case info, warning, success, error, step }
    }

    /// Every connected host is a valid target; Compose adapts per engine.
    private var eligibleHosts: [HostSession] {
        model.sessions
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
        .frame(width: 560, height: 560)
        .onAppear(perform: load)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Run Compose Project")
                    .font(.title2.weight(.semibold))
                Text(fileURL.lastPathComponent)
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
        if running || finished || runError != nil {
            runLog
        } else if editingYAML {
            yamlEditor
        } else if let parseError {
            errorState(parseError)
        } else if let project {
            configForm(project)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var yamlEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: $yamlText)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
            if let yamlError {
                Divider()
                Label(yamlError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                // No Esc shortcut here: a stray Esc must not drop the edits.
                Button("Discard Changes") {
                    yamlError = nil
                    yamlText = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? yamlText
                    editingYAML = false
                }
                Button("Save and Apply") { applyYAMLEdits() }
                    .buttonStyle(.borderedProminent)
                    .help("Writes the YAML to the file, then uses it for Up.")
            }
            .padding(12)
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle).foregroundStyle(.orange)
            Text("Can't read this Compose file").font(.headline)
            Text(message)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func configForm(_ project: ComposeProject) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                labeled("Project") { Text(project.name).fontWeight(.medium) }

                labeled("Host") {
                    if eligibleHosts.isEmpty {
                        Text("Add a host first")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Host", selection: $selectedHostID) {
                            ForEach(eligibleHosts) { session in
                                Text(session.host.name).tag(Optional(session.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 240)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Services").font(.headline)
                        Spacer()
                        Button {
                            yamlError = nil
                            editingYAML = true
                        } label: {
                            Label("Edit YAML", systemImage: "pencil")
                        }
                        .controlSize(.small)
                    }
                    ForEach(project.services) { service in
                        serviceRow(service)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Recreate existing containers", isOn: $recreate)
                    Toggle("Build without cache", isOn: $noCache)
                }
                .toggleStyle(.checkbox)
            }
            .padding(16)
        }
    }

    private func serviceRow(_ service: ComposeService) -> some View {
        HStack(spacing: 10) {
            Image(systemName: service.build != nil ? "hammer.fill" : "shippingbox.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.name).fontWeight(.medium)
                Text(serviceDetail(service))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !service.ports.isEmpty {
                Text(service.ports.map { ($0.hostPort ?? $0.containerPort) + ":" + $0.containerPort }
                    .joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func serviceDetail(_ service: ComposeService) -> String {
        if let build = service.build { return "build: \(build.context)" }
        return service.image ?? ""
    }

    private var runLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(log) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: icon(line.kind))
                                .foregroundStyle(color(line.kind))
                                .frame(width: 16)
                            Text(line.text)
                                .font(.callout)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .id(line.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: log.count) {
                if let last = log.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private func labeled<V: View>(_ title: LocalizedStringKey, @ViewBuilder _ value: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline).frame(minWidth: 70, alignment: .leading).fixedSize()
            value()
            Spacer()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if running { ProgressView().controlSize(.small) }
            Spacer()
            if running {
                runningButtons
            } else if !editingYAML {
                idleButtons
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var runningButtons: some View {
        Button("Stop", role: .destructive) {
            if let operation { model.operations.cancel(operation) }
        }
        .disabled(operation?.canCancel != true)
        Button("Continue in Background") { dismiss() }
            .keyboardShortcut(.cancelAction)
            .help("The deploy keeps running. Follow it in Activity.")
    }

    @ViewBuilder
    private var idleButtons: some View {
        Button(finished || runError != nil ? "Close" : "Cancel") { dismiss() }
            .keyboardShortcut(.cancelAction)
        if !finished && runError == nil {
            Button("Up") { startUp() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(project == nil || parseError != nil || eligibleHosts.isEmpty)
        }
    }

    // MARK: - Logic

    private func load() {
        yamlText = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        do {
            let parsed = try ComposeParser().parse(fileURL: fileURL)
            project = parsed
            if selectedHostID == nil {
                // Prefer a connected host, else the first available.
                selectedHostID = eligibleHosts.first(where: { $0.status.isConnected })?.id
                    ?? eligibleHosts.first?.id
            }
        } catch {
            parseError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Re-parses the edited YAML; on success replaces the project, writes the
    /// edits back to the file so build contexts and env files stay consistent,
    /// and leaves the editor.
    private func applyYAMLEdits() {
        do {
            let parsed = try ComposeParser().parse(text: yamlText, fileURL: fileURL)
            try yamlText.write(to: fileURL, atomically: true, encoding: .utf8)
            project = parsed
            parseError = nil
            yamlError = nil
            editingYAML = false
        } catch {
            yamlError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func startUp() {
        guard let project, let hostID = selectedHostID,
              let session = model.session(id: hostID) else { return }
        running = true
        runError = nil
        log.removeAll()
        let title = String(localized: "Compose up \(project.name)")
        operation = LongOperationRunner.run(.composeUp, title: title, session: session, center: model.operations) { op in
            try await runUp(project: project, hostID: hostID, session: session, operation: op)
        }
    }

    private func runUp(
        project: ComposeProject, hostID: UUID, session: HostSession, operation: LongOperation
    ) async throws -> String? {
        defer { running = false }

        if !session.status.isConnected {
            append(String(localized: "Connecting to \(session.host.name)…"), .info)
            await session.connect()
        }
        guard session.status.isConnected else {
            let message = String(localized: "Could not connect to \(session.host.name).")
            runError = message
            append(message, .error)
            throw OperationFailure(message)
        }
        await session.refreshAll()

        let runner = ComposeRunner(
            session: session,
            project: project,
            options: .init(recreate: recreate, noCache: noCache)
        )
        do {
            // Errors of the steps (a remove of an old container) stay in
            // this sheet's log instead of the banner behind it.
            let (outcome, _) = await session.attempt { () async -> Result<Int, Error> in
                do {
                    return .success(try await runner.up { event in
                        record(event)
                        operation.append(log: log.last?.text ?? "")
                        operation.update(progress: log.last?.text)
                    })
                } catch {
                    return .failure(error)
                }
            }
            let started = try outcome.get()
            finished = true
            NotificationCenter.default.post(name: .gantrySelectHostContainers, object: hostID)
            return String(localized: "\(started) services running")
        } catch {
            let message = error is CancellationError
                ? String(localized: "Cancelled.")
                : (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            runError = message
            append(String(localized: "Failed: \(message)"), .error)
            throw error
        }
    }

    private func record(_ event: ComposeUpEvent) {
        switch event {
        case .info(let m): append(m, .info)
        case .warning(let m): append(m, .warning)
        case .buildingImage(let s): append(String(localized: "Building image for \(s)…"), .step)
        case .pullingImage(let s, let ref): append(String(localized: "Pulling \(ref) for \(s)…"), .step)
        case .creatingNetwork(let n): append(String(localized: "Creating network \(n)"), .step)
        case .creatingVolume(let v): append(String(localized: "Creating volume \(v)"), .step)
        case .startingService(let s): append(String(localized: "Starting \(s)…"), .step)
        case .startedService(let s, _): append(String(localized: "Started \(s)"), .success)
        case .finished(let p, let n): append(String(localized: "\(p) is up — \(n) services running."), .success)
        }
    }

    private func append(_ text: String, _ kind: LogLine.Kind) {
        log.append(LogLine(text: text, kind: kind))
    }

    private func icon(_ kind: LogLine.Kind) -> String {
        switch kind {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "xmark.octagon.fill"
        case .step: "arrow.right.circle"
        }
    }

    private func color(_ kind: LogLine.Kind) -> Color {
        switch kind {
        case .info: .secondary
        case .warning: .orange
        case .success: .green
        case .error: .red
        case .step: .accentColor
        }
    }
}
