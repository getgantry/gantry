import SwiftUI
import AppCore

/// The Kubernetes section. It reads the kubeconfig files and talks to the
/// API server itself, so it needs no kubectl, Docker or connected host.
struct KubernetesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let browser = model.kubernetes
        Group {
            if browser.isPrepared {
                KubernetesBrowserView(browser: browser)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(Text("Kubernetes"))
        .task {
            // Fresh cluster lists also find a cluster service that does not answer.
            for session in model.sessions where session.supportsClusters {
                await session.refreshClusters()
            }
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
