import SwiftUI
import AppCore

/// The resources of the selected kind, with a filter and the last error.
struct KubeResourceList: View {
    let browser: KubernetesBrowser
    @Binding var selection: KubeResource.ID?
    @Binding var filter: String
    let actions: KubeResourceActions

    var body: some View {
        VStack(spacing: 0) {
            list
            Divider()
            footer
        }
    }

    private var visible: [KubeResource] {
        let text = filter.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return browser.resources }
        return browser.resources.filter { $0.name.localizedCaseInsensitiveContains(text) }
    }

    @ViewBuilder
    private var list: some View {
        if browser.resources.isEmpty {
            emptyState
        } else {
            List(visible, selection: $selection) { resource in
                KubeResourceRow(resource: resource, showNamespace: browser.namespace == nil)
                    .tag(resource.id)
                    .contextMenu { KubeResourceMenu(resource: resource, actions: actions) }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let error = browser.loadError {
            ContentUnavailableView {
                Label("Cannot Load the List", systemImage: "exclamationmark.triangle")
            } description: {
                Text(ErrorPresentation.split(error).summary)
            }
            .frame(maxHeight: .infinity)
        } else if browser.isLoading || browser.lastRefresh == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No Resources", systemImage: browser.kind.systemImage, description: Text(browser.kind.title))
                .frame(maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if browser.isLoading { ProgressView().controlSize(.mini) }
            if let error = browser.loadError, !browser.resources.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Refresh failed: \(ErrorPresentation.split(error).summary)")
                    .lineLimit(1)
                    .help(error)
            } else {
                Text("\(visible.count) items")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

struct KubeResourceRow: View {
    let resource: KubeResource
    let showNamespace: Bool

    var body: some View {
        HStack(spacing: 8) {
            KubeHealthIcon(health: resource.health)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: resource.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(resource.name)
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: resource.status)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if let date = resource.lastSeen ?? resource.createdAt {
                    Text(date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// The namespace (when all are listed) and the first summary fields.
    private var subtitle: String {
        var parts: [String] = []
        if showNamespace, let namespace = resource.namespace { parts.append(namespace) }
        if resource.kind == .events, let message = resource.field(KubeFieldLabel.message) {
            parts.append(message)
        } else {
            parts += resource.fields.prefix(2).map { "\($0.label) \($0.value)" }
        }
        return parts.joined(separator: " · ")
    }
}

/// The context menu of a resource row.
struct KubeResourceMenu: View {
    let resource: KubeResource
    let actions: KubeResourceActions

    var body: some View {
        if resource.kind.canScale {
            Button { actions.scale(resource) } label: { Label("Scale…", systemImage: "plusminus") }
        }
        if resource.kind.canRestart {
            Button { actions.restart(resource) } label: { Label("Restart", systemImage: "arrow.clockwise") }
        }
        if resource.kind.canPortForward {
            Button { actions.forward(resource) } label: { Label("Forward Port…", systemImage: "arrow.left.arrow.right") }
        }
        Button { copyToPasteboard(resource.name) } label: { Label("Copy Name", systemImage: "doc.on.doc") }
        if resource.kind.canDelete {
            Divider()
            Button(role: .destructive) { actions.delete(resource) } label: { Label("Delete…", systemImage: "trash") }
        }
    }
}
