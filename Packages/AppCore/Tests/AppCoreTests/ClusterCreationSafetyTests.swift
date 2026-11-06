import Foundation
import Testing
@testable import AppCore

/// Cancel of a cluster creation must never delete a cluster that Gantry
/// did not create. A fake `container` script records each create and
/// delete; the kubeconfig store goes to a temporary file.
@MainActor
@Suite(.serialized) struct ClusterCreationSafetyTests {
    private let folder: URL
    private let cli: URL
    private let store: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("gantry-cluster-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        cli = folder.appendingPathComponent("container")
        store = folder.appendingPathComponent("kubeconfigs.json")
        // Never touch the real store in Application Support.
        setenv("GANTRY_CLUSTER_KUBECONFIGS_PATH", store.path, 1)
        let row = "'%-14s%-23s%-15s%-9s%-6s%-9s%-15s%s\\n'"
        let script = """
        #!/bin/sh
        dir=$(dirname "$0")
        case "$1" in
        --version) echo "container CLI version 1.6.1 (build: release)" ;;
        cluster)
          case "$2" in
          list)
            printf \(row) CLUSTER NODE ROLE STATE CPUS MEMORY ADDR PORTS
            for n in $(cat "$dir/clusters" 2>/dev/null); do
              printf \(row) "$n" "$n" control-plane running 2 "2048 MB" 192.168.64.2 "6445->6443"
            done ;;
          create)
            echo "$4" >> "$dir/created"
            echo "$4" >> "$dir/clusters"
            echo "KUBECONFIG=$KUBECONFIG" >> "$dir/created"
            exec sleep 30 ;;
          delete) echo "$4 KUBECONFIG=$KUBECONFIG" >> "$dir/deleted" ;;
          esac ;;
        esac
        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
    }

    private func session() async -> HostSession {
        let session = HostSession(host: DockerHost(name: "Apple", kind: .appleContainer, socketPathOverride: cli.path))
        await session.loadClusterSupport()
        return session
    }

    private func log(_ name: String) -> String {
        (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func refusesANameThatExistsAlthoughTheListIsStale() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try "dev\n".write(to: folder.appendingPathComponent("clusters"), atomically: true, encoding: .utf8)
        let session = await session()
        #expect(session.supportsClusters)
        #expect(session.clusters.isEmpty)
        #expect(session.startClusterCreation(.init(name: "dev")))
        await waitFor { session.clusterCreations.first?.failure != nil }
        #expect(session.clusterCreations.first?.failure?.contains("already exists") == true)
        #expect(log("created").isEmpty)

        // Cancel right away: the existing cluster is not deleted.
        session.dismissClusterCreation("dev")
        #expect(session.startClusterCreation(.init(name: "dev")))
        await session.cancelClusterCreation("dev")
        #expect(log("created").isEmpty)
        #expect(log("deleted").isEmpty)
    }

    @Test func cancelBeforeLaunchStartsNothing() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = await session()
        #expect(session.startClusterCreation(.init(name: "fresh")))
        await session.cancelClusterCreation("fresh")
        #expect(log("created").isEmpty)
        #expect(log("deleted").isEmpty)
        #expect(session.clusterCreations.isEmpty)
    }

    @Test func cancelDeletesWhatThisRunCreatedWithItsKubeconfig() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = await session()
        let kubeconfig = folder.appendingPathComponent("kube.yaml").path
        #expect(session.startClusterCreation(.init(name: "mine", kubeconfigPath: kubeconfig)))
        await waitFor { log("created").contains("mine") }
        #expect(ClusterKubeconfigStore.path(host: session.host.id.uuidString, cluster: "mine") == kubeconfig)
        await session.cancelClusterCreation("mine")
        #expect(log("deleted") == "mine KUBECONFIG=\(kubeconfig)\n")
        #expect(ClusterKubeconfigStore.path(host: session.host.id.uuidString, cluster: "mine") == nil)
    }

    @Test func deleteUsesTheRecordedKubeconfig() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = await session()
        let hostID = session.host.id.uuidString
        let kubeconfig = folder.appendingPathComponent("other.yaml").path
        ClusterKubeconfigStore.record(kubeconfig, host: hostID, cluster: "kept", file: store)
        #expect(ClusterKubeconfigStore.path(host: hostID, cluster: "kept", file: store) == kubeconfig)
        #expect(ClusterKubeconfigStore.path(host: "other-host", cluster: "kept", file: store) == nil)
        #expect(await session.deleteCluster("kept"))
        #expect(await session.deleteCluster("plain"))
        #expect(log("deleted").hasPrefix("kept KUBECONFIG=\(kubeconfig)\nplain KUBECONFIG="))
        #expect(ClusterKubeconfigStore.path(host: hostID, cluster: "kept") == nil)
    }
}
