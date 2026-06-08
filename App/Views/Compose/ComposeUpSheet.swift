import SwiftUI
import AppCore
import DockerKit

/// Sheet that brings a `docker-compose` file up on an apple/container host.
///
/// Presented when a Compose file is opened from Finder (Open With / Quick
/// Action) or the File menu. Parses the file, lets the user pick the target
/// Apple Container host, and streams the `up` progress.
struct ComposeUpSheet: View {
    let fileURL: URL

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var project: ComposeProject?
    @State private var parseError: String?
    @State private var selectedHostID: UUID?
    @State private var recreate = true
    @State private var noCache = false

    @State private var running = false
    @State private var finished = false
    @State private var runError: String?
    @State private var log: [LogLine] = []

    private struct LogLine: Identifiable {
        let id = UUID()
        let text: String
        let kind: Kind
        enum Kind { case info, warning, success, error, step }
    }

    /// Apple Container hosts are the only valid targets for now.
    private var appleHosts: [HostSession] {
        model.sessions.filter { $0.host.isAppleContainer }
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
        if let parseError {
            errorState(parseError)
        } else if let project {
            if running || finished || runError != nil {
                runLog
            } else {
                configForm(project)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    if appleHosts.isEmpty {
                        Text("Add an Apple Container host first")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("", selection: $selectedHostID) {
                            ForEach(appleHosts) { session in
                                Text(session.host.name).tag(Optional(session.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 240)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Services").font(.headline)
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

    private func labeled<V: View>(_ title: String, @ViewBuilder _ value: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline).frame(width: 70, alignment: .leading)
            value()
            Spacer()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if running { ProgressView().controlSize(.small) }
            Spacer()
            Button(finished || runError != nil ? "Close" : "Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if !finished && runError == nil {
                Button("Up") { Task { await runUp() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(project == nil || parseError != nil || appleHosts.isEmpty || running)
            }
        }
        .padding(16)
    }

    // MARK: - Logic

    private func load() {
        do {
            let parsed = try ComposeParser().parse(fileURL: fileURL)
            project = parsed
            if selectedHostID == nil { selectedHostID = appleHosts.first?.id }
        } catch {
            parseError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func runUp() async {
        guard let project, let hostID = selectedHostID,
              let session = model.session(id: hostID) else { return }
        running = true
        runError = nil
        log.removeAll()

        if !session.status.isConnected {
            append("Connecting to \(session.host.name)…", .info)
            await session.connect()
        }
        guard session.status.isConnected else {
            running = false
            runError = "Could not connect to \(session.host.name)."
            append(runError!, .error)
            return
        }
        await session.refreshAll()

        let runner = ComposeRunner(
            session: session,
            project: project,
            options: .init(recreate: recreate, noCache: noCache)
        )
        do {
            _ = try await runner.up { event in record(event) }
            finished = true
            NotificationCenter.default.post(name: .gantrySelectHostContainers, object: hostID)
        } catch {
            runError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            append("Failed: \(runError!)", .error)
        }
        running = false
    }

    private func record(_ event: ComposeUpEvent) {
        switch event {
        case .info(let m): append(m, .info)
        case .warning(let m): append(m, .warning)
        case .buildingImage(let s): append("Building image for \(s)…", .step)
        case .pullingImage(let s, let ref): append("Pulling \(ref) for \(s)…", .step)
        case .creatingNetwork(let n): append("Creating network \(n)", .step)
        case .creatingVolume(let v): append("Creating volume \(v)", .step)
        case .startingService(let s): append("Starting \(s)…", .step)
        case .startedService(let s, _): append("Started \(s)", .success)
        case .finished(let p, let n): append("\(p) is up — \(n) service(s) running.", .success)
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
