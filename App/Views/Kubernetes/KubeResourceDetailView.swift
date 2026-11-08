import SwiftUI
import AppCore

/// The detail of one resource: overview, YAML and, for pods, logs and a shell.
struct KubeResourceDetailView: View {
    let resource: KubeResource
    let client: KubeAPIClient
    let actions: KubeResourceActions

    @State private var tab: Tab = .overview

    enum Tab: String, Identifiable {
        case overview, yaml, data, logs, terminal
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: String(localized: "Overview")
            case .yaml: "YAML"
            case .data: String(localized: "Data")
            case .logs: String(localized: "Logs")
            case .terminal: String(localized: "Terminal")
            }
        }
    }

    private var tabs: [Tab] {
        var result: [Tab] = [.overview, .yaml]
        if resource.kind == .secrets { result.insert(.data, at: 1) }
        if resource.kind.hasLogs { result.append(.logs) }
        if resource.kind.canExec { result.append(.terminal) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            KubeDetailHeader(resource: resource, actions: actions)
            Picker("Section", selection: $tab) {
                ForEach(tabs) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()
            Divider()
            tabContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .overview: KubeOverview(resource: resource)
        case .yaml: KubeYAMLView(resource: resource, client: client)
        case .data: KubeSecretDataView(resource: resource, client: client)
        case .logs: KubeLogsView(pod: resource, client: client)
        case .terminal: KubeTerminalView(pod: resource, client: client)
        }
    }
}

struct KubeDetailHeader: View {
    let resource: KubeResource
    let actions: KubeResourceActions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: resource.kind.systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: resource.name)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    KubeHealthIcon(health: resource.health)
                    BadgePill(text: resource.status, tint: KubeHealthIcon(health: resource.health).tint)
                    if let namespace = resource.namespace {
                        Text(verbatim: namespace).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            buttons
        }
        .padding([.horizontal, .top])
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 8) {
            if resource.kind.canScale {
                Button { actions.scale(resource) } label: { Label("Scale…", systemImage: "plusminus") }
            }
            if resource.kind.canRestart {
                Button { actions.restart(resource) } label: { Label("Restart", systemImage: "arrow.clockwise") }
            }
            if resource.kind.canPortForward {
                Button { actions.forward(resource) } label: { Label("Forward Port…", systemImage: "arrow.left.arrow.right") }
            }
            if resource.kind.canDelete {
                Button(role: .destructive) { actions.delete(resource) } label: { Label("Delete…", systemImage: "trash") }
            }
        }
        .labelStyle(.iconOnly)
        .help("Actions for \(resource.reference)")
    }
}

struct KubeOverview: View {
    let resource: KubeResource

    var body: some View {
        ScrollView {
            FactGrid {
                Fact(String(localized: "Kind"), resource.kind.title)
                if let namespace = resource.namespace { Fact(String(localized: "Namespace"), namespace) }
                Fact(String(localized: "Status"), resource.status)
                for field in resource.fields where !field.value.isEmpty {
                    Fact(field.label, field.value)
                }
                if !resource.containers.isEmpty {
                    Fact(String(localized: "Containers"), resource.containers.joined(separator: ", "))
                }
                if let created = resource.createdAt {
                    Fact(String(localized: "Created"), created.formatted(date: .abbreviated, time: .standard))
                }
                if !resource.uid.isEmpty { Fact("UID", resource.uid) }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The YAML of the resource, loaded when the tab opens. Secret values are hidden.
struct KubeYAMLView: View {
    let resource: KubeResource
    let client: KubeAPIClient

    @State private var text: String?
    @State private var error: String?

    var body: some View {
        Group {
            if let text {
                KubeMonospacedText(text: text)
            } else if let error {
                ContentUnavailableView("Cannot Load YAML", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { if let text { copyToPasteboard(text) } } label: { Label("Copy YAML", systemImage: "doc.on.doc") }
                    .help("Copy the YAML to the clipboard")
                    .disabled(text == nil)
            }
        }
        .task(id: resource.id) { await load() }
    }

    private func load() async {
        do {
            text = try await client.yaml(for: resource)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Selectable monospaced text that starts at the top-left corner.
struct KubeMonospacedText: View {
    let text: String

    var body: some View {
        GeometryReader { geo in
            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
            }
        }
    }
}
