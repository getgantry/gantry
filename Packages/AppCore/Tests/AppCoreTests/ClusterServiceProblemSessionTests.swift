import Foundation
import Testing
@testable import AppCore

/// `HostSession.clusterServiceProblem` with a fake 1.7.1 `container` script.
/// The script prints the live 1.7.1 cluster list, or fails with the
/// "cluster service unavailable" error while the file `down` exists.
@MainActor
@Suite(.serialized) struct ClusterServiceProblemSessionTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("gantry-ac171-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Writes the fake CLI at `relativePath` under the temporary folder.
    private func makeCLI(at relativePath: String) throws -> URL {
        let cli = folder.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        let nodes = """
        CLUSTER  NODE            ROLE           STATE    CPUS  MEMORY  ADDR          PORTS
        gtest    gtest           control-plane  running  2     3 GB    192.168.64.2  6445->6443
        gtest    gtest-worker-1  worker         running  2     2 GB    192.168.64.3
        """
        let json = #"[{"configuration":{"cni":null,"creationDate":"2026-11-07T21:28:00Z","fqdn":null,"kubernetesVersion":"v1.35.5","labels":{},"name":"gtest","nodes":[{"kind":"linux","name":"gtest","roles":["control-plane"]},{"kind":"linux","name":"gtest-worker-1","roles":["worker"]}],"remove":false,"sharedImageStore":true},"id":"gtest","status":{"nodes":[{"addresses":["192.168.64.2"],"name":"gtest","ports":["6445->6443"],"status":"running"},{"addresses":["192.168.64.3"],"name":"gtest-worker-1","status":"running"}],"state":"running"}}]"#
        let script = """
        #!/bin/sh
        case "$1" in
        --version) echo "container CLI version 1.7.1 (build: release, commit: a15b460)" ;;
        cluster)
          if [ -e "\(folder.path)/down" ]; then
            echo "Error: cluster service unavailable (XPC connection error: Connection invalid); make sure the system is running ('container system start') and restart it after upgrading" >&2
            exit 1
          fi
          case "$*" in
          *--format*) echo '\(json)' ;;
          *) cat <<'EOF'
        \(nodes)
        EOF
          ;;
          esac ;;
        esac
        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return cli
    }

    private func session(_ cli: URL) async -> HostSession {
        let session = HostSession(host: DockerHost(name: "Apple", kind: .appleContainer, socketPathOverride: cli.path))
        await session.loadClusterSupport()
        return session
    }

    private func setDown(_ down: Bool) throws {
        let flag = folder.appendingPathComponent("down")
        if down {
            try Data().write(to: flag)
        } else {
            try? FileManager.default.removeItem(at: flag)
        }
    }

    @Test func noticeAppearsAndGoesAwayAfterAListThatWorks() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = await session(try makeCLI(at: "tools/container"))
        #expect(session.supportsClusters)
        try setDown(true)
        await session.refreshClusters()
        // An unknown layout: the fix is a restart of the services.
        #expect(session.clusterServiceProblem == .servicesNotRunning)
        #expect(session.clusterListError?.contains("cluster service unavailable") == true)
        try setDown(false)
        await session.refreshClusters()
        #expect(session.clusterServiceProblem == nil)
        #expect(session.clusters.map(\.name) == ["gtest"])
    }

    @Test func homebrewLayoutThroughASymbolicLink() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = try makeCLI(at: "Cellar/container/1.7.1_1/bin/container")
        // Only the image plugin is installed, as in the Homebrew 1.7.1 bottle.
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("Cellar/container/1.7.1_1/libexec/container-plugins/container-core-images"),
            withIntermediateDirectories: true
        )
        let link = folder.appendingPathComponent("bin/container")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let session = await session(link)
        try setDown(true)
        await session.refreshClusters()
        #expect(session.clusterServiceProblem == .homebrewMissingPlugin(version: "1.7.1"))
        // A cluster action that fails the same way keeps the notice.
        #expect(await session.deleteCluster("gtest") == false)
        #expect(session.clusterServiceProblem == .homebrewMissingPlugin(version: "1.7.1"))
    }

    @Test func kubernetesNoticeOnlyForClustersOfTheTool() {
        let contexts = [
            KubeContext(name: "kind-gtest", isAppleCluster: true),
            KubeContext(name: "prod")
        ]
        #expect(ClusterServiceDiagnosis.showsKubernetesNotice(contexts: contexts, selectedContext: "kind-gtest"))
        #expect(!ClusterServiceDiagnosis.showsKubernetesNotice(contexts: contexts, selectedContext: "prod"))
        #expect(!ClusterServiceDiagnosis.showsKubernetesNotice(contexts: contexts, selectedContext: nil))
        // No context at all: the clusters of the tool are not reachable.
        #expect(ClusterServiceDiagnosis.showsKubernetesNotice(contexts: [], selectedContext: nil))
    }

    @Test func otherErrorsSetNoNotice() {
        #expect(ClusterServiceDiagnosis.problem(forError: "Error: cluster gtest not found", cliPath: nil) == nil)
    }
}
