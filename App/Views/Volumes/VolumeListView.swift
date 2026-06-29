import SwiftUI
import AppKit
import AppCore
import DockerKit

struct VolumeListView: View {
    @Bindable var session: HostSession
    @Binding var selection: String?

    @State private var searchText = ""
    @State private var removeTarget: Volume?
    @State private var showingNew = false
    @State private var pruneConfirm = false
    @State private var pruneOutcome: PruneOutcome?

    private var filtered: [Volume] {
        guard !searchText.isEmpty else { return session.volumes }
        let needle = searchText.lowercased()
        return session.volumes.filter {
            $0.name.lowercased().contains(needle) || $0.driver.lowercased().contains(needle)
        }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(filtered) { volume in
                VolumeRow(
                    volume: volume,
                    size: session.volumeSizes[volume.name],
                    sizesLoaded: session.volumeSizesLoaded
                )
                .tag(volume.name)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .contextMenu {
                        Button {
                            copyToPasteboard(volume.name)
                        } label: {
                            Label("Copy Name", systemImage: "doc.on.doc")
                        }
                        Divider()
                        Button(role: .destructive) {
                            removeTarget = volume
                        } label: {
                            Label("Remove…", systemImage: "trash")
                        }
                    }
            }
        }
        .animation(.snappy, value: filtered)
        .task(id: session.id) { await session.refreshVolumeSizes(force: false) }
        .navigationTitle("Volumes")
        .searchable(text: $searchText, prompt: "Filter by name or driver")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNew = true
                } label: {
                    Label("New Volume…", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await session.refreshVolumes()
                        await session.refreshVolumeSizes()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Prune Unused Volumes…") { pruneConfirm = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingNew) {
            NewVolumeSheet(session: session)
        }
        .confirmationDialog(
            "Prune Unused Volumes?",
            isPresented: $pruneConfirm,
            titleVisibility: .visible
        ) {
            Button("Prune", role: .destructive) {
                pruneConfirm = false
                Task {
                    if let result = await session.pruneVolumes() {
                        pruneOutcome = PruneOutcome(title: "Volumes Pruned", result: result)
                    }
                }
            }
            Button("Cancel", role: .cancel) { pruneConfirm = false }
        } message: {
            Text("Removes all volumes not used by at least one container. This permanently deletes their data.")
        }
        .pruneResultAlert($pruneOutcome)
        .confirmationDialog(
            "Remove \(removeTarget?.name ?? "volume")?",
            isPresented: Binding(presence: $removeTarget),
            titleVisibility: .visible,
            presenting: removeTarget
        ) { volume in
            Button("Remove", role: .destructive) {
                removeTarget = nil
                Task { await session.removeVolume(name: volume.name) }
            }
            Button("Cancel", role: .cancel) { removeTarget = nil }
        } message: { _ in
            Text("Removing a volume permanently deletes its data. Volumes in use by a container cannot be removed.")
        }
    }
}

private struct VolumeRow: View {
    let volume: Volume
    /// Per-volume size in bytes, or `nil` if not present in the measured map.
    let size: Int64?
    /// Whether the `df` measure has completed for this session.
    let sizesLoaded: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(volume.driver) · \(volume.scope)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            sizeLabel
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var sizeLabel: some View {
        if let size {
            Text(Formatters.bytes(size, style: .file))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        } else if sizesLoaded {
            // Measured, but this volume had no `df` entry (e.g. created after
            // the last measure, or a backend that doesn't size volumes).
            Text("—")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }
}

struct VolumeDetailView: View {
    let volume: Volume
    let session: HostSession

    @State private var tab = 0

    /// Size from the session's `df`-sourced map, falling back to any size the
    /// volume already carried from its inspect payload.
    private var volumeSize: Int64? {
        session.volumeSizes[volume.name] ?? volume.usageData?.size
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(volume.name)
                .font(.largeTitle.weight(.bold))
                .lineLimit(2)
                .padding([.horizontal, .top])

            Picker("Section", selection: $tab) {
                Text("Overview").tag(0)
                Text("Inspect").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            Divider()

            if tab == 0 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        FactGrid {
                            Fact("Driver", volume.driver)
                            Fact("Scope", volume.scope)
                            Fact("Mountpoint", volume.mountpoint)
                            if let size = volumeSize, size >= 0 {
                                Fact("Size", Formatters.bytes(size, style: .file))
                            }
                            if !volume.createdAt.isEmpty {
                                Fact("Created", Formatters.relative(fromRFC3339: volume.createdAt))
                            }
                        }
                        if !volume.labels.isEmpty {
                            SectionTitle("Labels")
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(volume.labels.keys.sorted(), id: \.self) { key in
                                    Text("\(key)=\(volume.labels[key] ?? "")")
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                InspectJSONView {
                    await session.rawInspectVolume(name: volume.name)
                }
            }
        }
        .navigationTitle(volume.name)
    }
}
