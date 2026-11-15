import SwiftUI
import AppCore
import DockerKit

/// The Builds section: the builds that Gantry started on the host and, on a
/// Docker host with buildx, the BuildKit records of `docker buildx history`.
struct BuildHistoryView: View {
    let session: HostSession

    @Environment(AppModel.self) private var model
    @State private var buildx = BuildxState()
    @State private var selection: String?
    @State private var clear: DestructiveAction?

    private var gantryRecords: [BuildRecord] { model.buildHistory.records(for: session.host.id) }

    private var records: [BuildRecord] {
        (gantryRecords + buildx.records).sorted { $0.startedAt > $1.startedAt }
    }

    private var selected: BuildRecord? {
        guard let selection else { return nil }
        return buildx.details[selection] ?? records.first { $0.id == selection }
    }

    var body: some View {
        HSplitView {
            BuildListPane(records: records, note: buildx.note, selection: $selection, emptyText: emptyText)
                .frame(minWidth: 280, idealWidth: 360, maxWidth: 520)
            detail
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbarItems }
        .task(id: session.id) { await refresh() }
        .task(id: selection) { await loadDetail() }
        .onSectionCommand(.refresh, .builds) { Task { await refresh() } }
        .destructiveConfirmation($clear) { _, _ in
            let clearsSelection = selected?.source == .gantry
            model.buildHistory.clear(hostID: session.host.id)
            if clearsSelection { selection = nil }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selected {
            BuildDetailView(
                record: selected,
                loading: buildx.loadingDetail == selected.id,
                loadError: buildx.detailErrors[selected.id]
            )
        } else {
            ContentUnavailableView("No Build Selected", systemImage: "hammer",
                                   description: Text("Select a build to see its steps and log."))
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem {
            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh")
            .disabled(buildx.loading)
        }
        ToolbarItem {
            Button {
                clear = .clearBuildHistory(hostID: session.host.id, hostName: session.host.name)
            } label: {
                Label("Clear History…", systemImage: "trash")
            }
            .help("Remove the builds that Gantry recorded on this host")
            .disabled(gantryRecords.isEmpty)
        }
    }

    private var emptyText: Text {
        session.host.isAppleContainer
            ? Text("apple/container keeps no build history. Gantry shows the builds that it starts here.")
            : Text("Gantry shows the builds that it starts here, and BuildKit builds when buildx is available.")
    }

    // MARK: - Loading

    private func refresh() async {
        guard !session.host.isAppleContainer else { return }
        buildx.loading = true
        defer { buildx.loading = false }
        let runner = session.dockerCLIRunner()
        let availability = await session.buildxAvailability(runner: runner)
        guard availability.isAvailable, let runner else {
            buildx.records = []
            buildx.note = BuildxNote.text(for: availability, ssh: session.host.isSSH)
            return
        }
        do {
            buildx.records = try await BuildxHistoryService.records(runner: runner, hostID: session.host.id)
            buildx.note = nil
        } catch {
            buildx.records = []
            buildx.note = BuildxNote.failed(error.localizedDescription)
        }
    }

    private func loadDetail() async {
        guard let selection,
              let record = buildx.records.first(where: { $0.id == selection }),
              buildx.details[selection] == nil,
              let runner = session.dockerCLIRunner() else { return }
        buildx.loadingDetail = selection
        defer { if buildx.loadingDetail == selection { buildx.loadingDetail = nil } }
        do {
            buildx.details[selection] = try await BuildxHistoryService.detail(of: record, runner: runner)
            buildx.detailErrors[selection] = nil
        } catch {
            buildx.detailErrors[selection] = String(localized: "Could not load the log: \(error.localizedDescription)")
        }
    }
}

/// The buildx part of the section.
private struct BuildxState {
    var records: [BuildRecord] = []
    var details: [String: BuildRecord] = [:]
    var detailErrors: [String: String] = [:]
    var note: String?
    var loading = false
    var loadingDetail: String?
}

/// Why the BuildKit records do not show.
enum BuildxNote {
    static func text(for availability: BuildxAvailability, ssh: Bool) -> String? {
        switch availability {
        case .available, .notDockerHost:
            nil
        case .noDockerCLI:
            ssh
                ? String(localized: "BuildKit builds do not show: the host has no docker CLI.")
                : String(localized: "BuildKit builds do not show: Gantry did not find the docker CLI on this Mac.")
        case .noBuildx:
            String(localized: "BuildKit builds do not show: install the docker buildx plugin.")
        case .tooOld(let version):
            String(localized: "BuildKit builds do not show: buildx \(version) is too old. Install buildx \(BuildxHistoryParser.minimumVersion) or later.")
        case .failed(let message):
            failed(message)
        }
    }

    static func failed(_ message: String) -> String {
        String(localized: "Could not read the BuildKit history: \(message)")
    }
}

/// The list of builds with the buildx note above it.
private struct BuildListPane: View {
    let records: [BuildRecord]
    let note: String?
    @Binding var selection: String?
    let emptyText: Text

    var body: some View {
        List(selection: $selection) {
            if let note {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
            ForEach(records) { record in
                BuildRowView(record: record).tag(record.id)
            }
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView("No Builds", systemImage: "hammer", description: emptyText)
            }
        }
    }
}
