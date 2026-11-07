import SwiftUI
import AppCore

/// Context and namespace in the toolbar, then kinds, resources and details.
struct KubernetesBrowserView: View {
    @Bindable var browser: KubernetesBrowser
    @Environment(AppModel.self) private var model

    @State private var selection: KubeResource.ID?
    @State private var filter = ""
    @State private var showingApply = false
    @State private var showingForwards = false
    @State private var deleteAction: DestructiveAction?
    @State private var scaleTarget: KubeResource?
    @State private var forwardTarget: KubeResource?

    var body: some View {
        content
            .toolbar { toolbarContent }
            .task(id: browser.selectionKey) { await browser.watch() }
            .onChange(of: browser.selectionKey) { selection = nil }
            .sheet(isPresented: $showingApply) { KubeApplySheet(browser: browser) }
            .sheet(item: $scaleTarget) { KubeScaleSheet(resource: $0, browser: browser) }
            .sheet(item: $forwardTarget) { KubePortForwardSheet(resource: $0, browser: browser) }
            .destructiveConfirmation($deleteAction, onDelete: deleteSelection) { action, _ in
                guard let resource = browser.resources.first(where: { action.targets.contains($0.id) }) else { return }
                browser.delete(resource, operations: model.operations)
            }
    }

    private var actions: KubeResourceActions {
        KubeResourceActions(
            scale: { scaleTarget = $0 },
            restart: { browser.restart($0, operations: model.operations) },
            forward: { forwardTarget = $0 },
            delete: { deleteAction = .deleteKubeResource($0) }
        )
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if let message = browser.actionError {
                ActionErrorBannerContent(title: String(localized: "Kubernetes"), message: message) {
                    browser.actionError = nil
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            clusterServiceNotice
            if browser.contexts.isEmpty {
                noContexts
            } else {
                split
            }
        }
    }

    /// The container tool's cluster services do not answer (see ClusterServiceDiagnosis).
    @ViewBuilder
    private var clusterServiceNotice: some View {
        if let session = model.sessions.first(where: { $0.host.isAppleContainer && $0.clusterServiceProblem != nil }),
           let problem = session.clusterServiceProblem,
           ClusterServiceDiagnosis.showsKubernetesNotice(contexts: browser.contexts, selectedContext: browser.selectedContext) {
            ClusterServiceProblemNotice(problem: problem, session: session)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
    }

    private var split: some View {
        HSplitView {
            KubeKindList(selection: $browser.kind)
                .frame(minWidth: 150, idealWidth: 180, maxWidth: 240)
            KubeResourceList(browser: browser, selection: $selection, filter: $filter, actions: actions)
                .frame(minWidth: 280, idealWidth: 380)
            detail
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let resource = browser.resources.first(where: { $0.id == selection }), let client = browser.client {
            KubeResourceDetailView(resource: resource, client: client, actions: actions)
                .id(resource.id)
        } else {
            ContentUnavailableView(
                "Nothing Selected",
                systemImage: "rectangle.righthalf.inset.filled",
                description: Text("Pick an item to see its details.")
            )
        }
    }

    private var noContexts: some View {
        ContentUnavailableView {
            Label("No Kubernetes Contexts", systemImage: "helm")
        } description: {
            if let error = browser.loadError {
                Text(error)
            } else {
                Text("Create a cluster in Clusters, or add a context to ~/.kube/config.")
            }
        } actions: {
            Button("Check Again") { Task { await browser.loadContexts() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func deleteSelection() -> DestructiveAction? {
        guard let resource = browser.resources.first(where: { $0.id == selection }), resource.kind.canDelete else { return nil }
        return .deleteKubeResource(resource)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            KubeContextPicker(browser: browser)
            KubeNamespacePicker(browser: browser)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { _ = await browser.reload() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Reload the list. The list also updates live.")
            Button {
                showingForwards.toggle()
            } label: {
                Label("Port Forwards", systemImage: "arrow.left.arrow.right")
            }
            .badge(browser.portForwards.activeCount)
            .help("Show the active port forwards.")
            .popover(isPresented: $showingForwards) {
                KubePortForwardsPopover(forwards: browser.portForwards)
            }
            Button {
                showingApply = true
            } label: {
                Label("Apply YAML…", systemImage: "square.and.arrow.up.on.square")
            }
            .help("Apply a manifest to the selected context.")
            .disabled(browser.selectedContext == nil)
        }
    }
}

/// The actions that the list and the detail share.
struct KubeResourceActions {
    let scale: (KubeResource) -> Void
    let restart: (KubeResource) -> Void
    let forward: (KubeResource) -> Void
    let delete: (KubeResource) -> Void
}

struct KubeContextPicker: View {
    @Bindable var browser: KubernetesBrowser

    var body: some View {
        Picker("Context", selection: $browser.selectedContext) {
            ForEach(browser.contexts) { context in
                Text(verbatim: context.isAppleCluster ? "\(context.name) (apple/container)" : context.name)
                    .tag(Optional(context.name))
            }
        }
        .pickerStyle(.menu)
        .frame(minWidth: 160)
        .help("The kubeconfig context")
    }
}

struct KubeNamespacePicker: View {
    @Bindable var browser: KubernetesBrowser

    var body: some View {
        Picker("Namespace", selection: $browser.namespace) {
            Text("All Namespaces").tag(String?.none)
            Divider()
            ForEach(names, id: \.self) { name in
                Text(verbatim: name).tag(Optional(name))
            }
        }
        .pickerStyle(.menu)
        .frame(minWidth: 140)
        .disabled(!browser.kind.isNamespaced)
        .help("The namespace to list")
    }

    /// The listed namespaces, plus the selected one when the list is not loaded.
    private var names: [String] {
        guard let current = browser.namespace, !browser.namespaces.contains(current) else { return browser.namespaces }
        return [current] + browser.namespaces
    }
}

struct KubeKindList: View {
    @Binding var selection: KubeResourceKind

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let kind = $0 { selection = kind } })) {
            ForEach(KubeResourceKind.allCases) { kind in
                Label(kind.title, systemImage: kind.systemImage)
                    .tag(kind)
            }
        }
        .listStyle(.sidebar)
    }
}

/// The health as an icon with a shape per state and a spoken label.
struct KubeHealthIcon: View {
    let health: KubeHealth

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(tint)
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch health {
        case .ok: "checkmark.circle.fill"
        case .progressing: "arrow.triangle.2.circlepath.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .neutral: "circle"
        }
    }

    var tint: Color {
        switch health {
        case .ok: .green
        case .progressing: .blue
        case .warning: .orange
        case .failed: .red
        case .neutral: .secondary
        }
    }

    private var label: String {
        switch health {
        case .ok: String(localized: "Healthy")
        case .progressing: String(localized: "In progress")
        case .warning: String(localized: "Warning")
        case .failed: String(localized: "Failed")
        case .neutral: String(localized: "No health status")
        }
    }
}
