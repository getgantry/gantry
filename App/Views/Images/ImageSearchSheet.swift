import SwiftUI
import AppCore
import DockerKit

/// Searches Docker Hub (or lists the tags of a repository on another
/// registry) and pulls the selected tag for the platform of the host.
struct ImageSearchSheet: View {
    let session: HostSession

    @Environment(\.dismiss) private var dismiss
    @State private var model: ImageSearchModel
    @State private var selectedResult: ImageSearchResult.ID?
    @State private var selectedTag: ImageTag.ID?

    init(session: HostSession, model: ImageSearchModel? = nil) {
        self.session = session
        _model = State(initialValue: model ?? session.makeImageSearchModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search Images")
                .font(.title2.weight(.bold))
            ImageSearchInput(model: model)
            Divider()
            content
                .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
            footer
        }
        .padding(20)
        .frame(width: 720, height: 540)
        .onChange(of: selectedResult) { _, name in
            selectedTag = nil
            model.select(model.results.first { $0.name == name })
        }
        .onChange(of: model.selectedRepository) { _, _ in selectedTag = nil }
    }

    @ViewBuilder
    private var content: some View {
        switch model.source {
        case .dockerHub:
            HSplitView {
                ImageSearchResultsList(model: model, selection: $selectedResult)
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                ImageTagsList(model: model, selection: $selectedTag)
                    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            }
        case .registry:
            ImageTagsList(model: model, selection: $selectedTag)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var tag: ImageTag? {
        model.tags.first { $0.id == selectedTag }
    }

    private var reference: String? {
        tag.flatMap { model.pullReference(for: $0) }
    }

    private var canPull: Bool {
        guard let tag, reference != nil else { return false }
        return tag.supports(model.hostPlatform)
    }

    private var footer: some View {
        HStack {
            if let platform = model.hostPlatform {
                Text("Platform: \(platform)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Pull") { pull() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canPull)
        }
    }

    /// Starts the shared pull; its progress shows in Activity and the menu bar.
    private func pull() {
        guard canPull, let reference else { return }
        ImagePullOperation.start(reference: reference, platform: model.hostPlatform, session: session)
        dismiss()
    }
}

/// The source picker and the text field.
private struct ImageSearchInput: View {
    let model: ImageSearchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Registry", selection: sourceBinding) {
                Text("Docker Hub").tag(ImageSearchModel.Source.dockerHub)
                Text("Other Registry").tag(ImageSearchModel.Source.registry)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            TextField(prompt, text: queryBinding)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var prompt: LocalizedStringKey {
        model.source == .dockerHub ? "Search Docker Hub…" : "Repository (e.g. ghcr.io/owner/image)"
    }

    private var sourceBinding: Binding<ImageSearchModel.Source> {
        Binding(get: { model.source }, set: { model.setSource($0) })
    }

    private var queryBinding: Binding<String> {
        Binding(get: { model.query }, set: { model.setQuery($0) })
    }
}

/// Docker Hub results: name, description, stars and the official mark.
private struct ImageSearchResultsList: View {
    let model: ImageSearchModel
    @Binding var selection: ImageSearchResult.ID?

    var body: some View {
        switch model.phase {
        case .idle:
            ContentUnavailableView(
                "Search Docker Hub",
                systemImage: "magnifyingglass",
                description: Text("Type the name of an image.")
            )
        case .loading where model.results.isEmpty:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView.search(text: model.query)
        case .failed(let error):
            ImageSearchErrorView(error: error) { model.retry() }
        case .loading, .loaded:
            List(model.results, selection: $selection) { result in
                ImageSearchResultRow(result: result)
            }
        }
    }
}

private struct ImageSearchResultRow: View {
    let result: ImageSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(result.name)
                    .font(.body.weight(.semibold))
                if result.isOfficial {
                    Label("Official", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
                Spacer()
                Label {
                    Text(result.starCount, format: .number.notation(.compactName))
                } icon: {
                    Image(systemName: "star")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Stars"))
                .accessibilityValue(Text(result.starCount, format: .number))
            }
            if !result.description.isEmpty {
                Text(result.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The tags of the selected repository.
private struct ImageTagsList: View {
    let model: ImageSearchModel
    @Binding var selection: ImageTag.ID?

    var body: some View {
        switch model.tagsPhase {
        case .idle:
            idleView
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView(
                "No Tags",
                systemImage: "tag.slash",
                description: Text("This repository has no tags, or it does not exist.")
            )
        case .failed(let error):
            ImageSearchErrorView(error: error) { model.retry() }
        case .loaded:
            List(model.tags, selection: $selection) { tag in
                ImageTagRow(tag: tag, hostPlatform: model.hostPlatform)
            }
        }
    }

    @ViewBuilder
    private var idleView: some View {
        if model.source == .dockerHub {
            ContentUnavailableView(
                "Select an Image",
                systemImage: "tag",
                description: Text("Select a result to see its tags.")
            )
        } else {
            ContentUnavailableView(
                "List Tags",
                systemImage: "tag",
                description: Text("Enter a repository, for example ghcr.io/owner/image.")
            )
        }
    }
}

private struct ImageTagRow: View {
    let tag: ImageTag
    let hostPlatform: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(tag.name)
                    .font(.system(.body, design: .monospaced))
                Spacer()
                if let size = tag.size(for: hostPlatform) {
                    Text(size, format: .byteCount(style: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                if let date = tag.lastPushed {
                    Text(date, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let hostPlatform, !tag.supports(hostPlatform) {
                    Label("Not available for \(hostPlatform)", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 1)
    }
}

/// One message for each kind of failure: rate limit, no network, access, other.
private struct ImageSearchErrorView: View {
    let error: ImageSearchError
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
        }
    }

    private var title: LocalizedStringKey {
        switch error {
        case .rateLimited: "Rate Limit Reached"
        case .offline: "Registry Not Reachable"
        case .unauthorized: "Access Denied"
        case .notFound: "No Tags"
        case .failed: "Search Failed"
        }
    }

    private var symbol: String {
        switch error {
        case .rateLimited: "hourglass"
        case .offline: "wifi.slash"
        case .unauthorized: "lock"
        case .notFound: "tag.slash"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var message: String {
        switch error {
        case .rateLimited(let date?):
            String(localized: "The registry limits the number of requests. Try again at \(date.formatted(date: .omitted, time: .shortened)).")
        case .rateLimited(nil):
            String(localized: "The registry limits the number of requests. Try again later.")
        case .offline:
            String(localized: "Check the network connection, then try again.")
        case .unauthorized:
            String(localized: "Log in to this registry with “docker login”, then try again.")
        case .notFound:
            String(localized: "This repository has no tags, or it does not exist.")
        case .failed(let text):
            text
        }
    }
}
