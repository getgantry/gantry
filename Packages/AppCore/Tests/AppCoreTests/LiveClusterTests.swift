import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

// Live test against apple/container 1.5+ with running services. Gated:
//   GANTRY_APPLE_CLUSTER_LIVE=1 swift test --filter liveCluster
// Creates a cluster with no workers, lists it, writes a kubeconfig and deletes
// the cluster. KUBECONFIG points at a temp file to keep ~/.kube/config as is.

private let liveClusterEnabled =
    ProcessInfo.processInfo.environment["GANTRY_APPLE_CLUSTER_LIVE"] == "1"
    && AppleContainerCLIDiscovery.discover() != nil

private final class LineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

@Test(.enabled(if: liveClusterEnabled), .timeLimit(.minutes(15)))
func liveClusterLifecycle() async throws {
    let name = "gantry-live-cluster"
    let command = try await AppleContainerControl.clusterCommand()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gantry-live-cluster-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let mergedConfig = directory.appendingPathComponent("config").path
    let writtenConfig = directory.appendingPathComponent("kube/\(name).kubeconfig").path

    try? await AppleContainerControl.deleteCluster(name, kubeconfigPath: mergedConfig, command: command)

    let log = LineLog()
    do {
        try await AppleContainerControl.createCluster(
            .init(name: name, workers: 0, cpus: 2, memory: "2G", kubeconfigPath: mergedConfig),
            command: command,
            output: log.append
        )
        #expect(log.all.contains { ClusterCreateProgress.parse($0) != nil })

        let clusters = try await AppleContainerControl.listClusters(command: command)
        let cluster = try #require(clusters.first { $0.name == name })
        #expect(cluster.nodes.count == 1)
        #expect(cluster.controlPlane?.name == name)
        #expect(cluster.isRunning)
        #expect(cluster.apiServerPort != nil)

        try await AppleContainerControl.writeClusterConfig(name, kubeconfigPath: writtenConfig, command: command)
        let written = try String(contentsOfFile: writtenConfig, encoding: .utf8)
        #expect(written.contains("name: \(name)"))
        if let url = cluster.apiServerURL { #expect(written.contains(url)) }
        let merged = try String(contentsOfFile: mergedConfig, encoding: .utf8)
        #expect(merged.contains("name: \(name)"))
    } catch {
        try? await AppleContainerControl.deleteCluster(name, kubeconfigPath: mergedConfig, command: command)
        try? FileManager.default.removeItem(at: directory)
        throw error
    }

    try await AppleContainerControl.deleteCluster(name, kubeconfigPath: mergedConfig, command: command)
    let after = try await AppleContainerControl.listClusters(command: command)
    #expect(!after.contains { $0.name == name })
    try? FileManager.default.removeItem(at: directory)
}
