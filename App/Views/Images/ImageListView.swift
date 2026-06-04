import SwiftUI
import AppKit
import AppCore
import DockerKit

struct ImageListView: View {
    @Bindable var session: HostSession

    @State private var selectedID: String?
    @State private var searchText = ""
    @State private var removeTarget: ImageSummary?

    private var filtered: [ImageSummary] {
        guard !searchText.isEmpty else { return session.images }
        let needle = searchText.lowercased()
        return session.images.filter {
            $0.displayName.lowercased().contains(needle)
                || $0.id.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            List(selection: $selectedID) {
                ForEach(filtered) { image in
                    ImageRow(image: image)
                        .tag(image.id)
                        .contextMenu {
                            Button {
                                copy(image.id)
                            } label: {
                                Label("Copy ID", systemImage: "doc.on.doc")
                            }
                            Divider()
                            Button(role: .destructive) {
                                removeTarget = image
                            } label: {
                                Label("Remove…", systemImage: "trash")
                            }
                        }
                }
            }
            .navigationTitle("Images")
            .navigationDestination(item: $selectedID) { id in
                if let image = session.images.first(where: { $0.id == id }) {
                    ImageDetailView(image: image, session: session)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Filter by tag or ID")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await session.refreshImages() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .confirmationDialog(
            "Remove \(removeTarget?.displayName ?? "image")?",
            isPresented: Binding(
                get: { removeTarget != nil },
                set: { if !$0 { removeTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: removeTarget
        ) { image in
            Button("Remove", role: .destructive) {
                Task { await session.refreshImages() }
                removeTarget = nil
            }
            Button("Cancel", role: .cancel) { removeTarget = nil }
        } message: { _ in
            Text("Image removal will be wired through the engine in a later milestone.")
        }
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

private struct ImageRow: View {
    let image: ImageSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(image.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(image.sizeDisplay) · \(image.createdDate.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if image.containers > 0 {
                Text("\(image.containers) in use")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ImageDetailView: View {
    let image: ImageSummary
    let session: HostSession

    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(image.displayName)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(2)
            }
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
                            Fact("ID", image.shortID)
                            Fact("Size", image.sizeDisplay)
                            Fact("Created", image.createdDate.formatted(date: .abbreviated, time: .shortened))
                            Fact("Containers", image.containers >= 0 ? "\(image.containers)" : "—")
                        }
                        if !image.repoTags.isEmpty {
                            SectionTitle("Tags")
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(image.repoTags, id: \.self) { tag in
                                    Text(tag)
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
                    await session.rawInspectImage(id: image.id)
                }
            }
        }
        .navigationTitle(image.displayName)
    }
}
