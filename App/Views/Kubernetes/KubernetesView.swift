import SwiftUI
import AppCore

/// The Kubernetes section: finds kubectl, then shows the browser or an
/// install hint. It does not need Docker or a connected host.
struct KubernetesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let browser = model.kubernetes
        Group {
            switch browser.availability {
            case .unknown:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .missing:
                KubectlMissingView { await browser.prepare() }
            case .ready:
                KubernetesBrowserView(browser: browser)
            }
        }
        .navigationTitle(Text("Kubernetes"))
        .task {
            browser.appleClusters = appleClusterNames
            await browser.prepare()
        }
    }

    /// Clusters that apple/container made: their contexts come first.
    private var appleClusterNames: Set<String> {
        let listed = model.sessions.filter(\.host.isAppleContainer).flatMap { $0.clusters.map(\.kubectlContext) }
        return Set(listed + ClusterKubeconfigStore.entries().map(\.cluster))
    }
}

/// Shown when no kubectl binary is found.
struct KubectlMissingView: View {
    @Environment(AppModel.self) private var model
    let retry: () async -> Void
    @State private var installing = false

    var body: some View {
        ContentUnavailableView {
            Label("kubectl Is Not Installed", systemImage: "helm")
        } description: {
            Text("Gantry uses kubectl to read Kubernetes clusters. Install it, then select Check Again.")
        } actions: {
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var actions: some View {
        Text(verbatim: KubectlTooling.installCommand)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
        HStack {
            if ContainerTooling.brewPath() != nil {
                Button("Install with Homebrew") { install() }
                    .disabled(installing)
            }
            Button("Copy Command") { copyToPasteboard(KubectlTooling.installCommand) }
            Link("Install Guide", destination: KubectlTooling.installPageURL)
            Button("Check Again") { Task { await retry() } }
        }
        if installing { ProgressView().controlSize(.small) }
    }

    private func install() {
        installing = true
        let operation = model.operations.run(.brewInstall, title: KubectlTooling.installCommand) { operation in
            try await KubectlTooling.install { line in
                Task { @MainActor in
                    operation.append(log: line)
                    operation.update(progress: line)
                }
            }
            return nil
        }
        Task {
            await operation.wait()
            installing = false
            await retry()
        }
    }
}
