import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

// Fixtures follow the apple/container 1.7.1 source: ClusterList.swift,
// ClusterResource/ClusterStatus/ClusterConfiguration (JSON) and
// ClusterHelper.buildNodeRows (the `--nodes` table, memory from ByteCountFormatter).

struct AppleContainer17FeatureTests {
    @Test func clusterServiceStartsAt170() {
        #expect(!ContainerTooling.features(for: "1.6.1").clusterService)
        #expect(ContainerTooling.features(for: "1.7.0").clusterService)
        #expect(ContainerTooling.features(for: "1.7.1").clusterService)
        #expect(ContainerTooling.features(for: nil).clusterService)
    }

    @Test func loadImageOnlyBefore170() {
        #expect(!ContainerTooling.features(for: "1.4.1").clusterLoadImage)
        #expect(ContainerTooling.features(for: "1.5.0").clusterLoadImage)
        #expect(ContainerTooling.features(for: "1.6.1").clusterLoadImage)
        #expect(!ContainerTooling.features(for: "1.7.1").clusterLoadImage)
        // An unknown version is treated as the newest CLI.
        #expect(!ContainerTooling.features(for: "unknown").clusterLoadImage)
    }

    @Test func recommendsThePublishedRelease() {
        #expect(ContainerTooling.recommendedVersion == "1.7.1")
    }
}

struct ClusterList17Tests {
    private let json = """
    [{"configuration":{"cni":null,"creationDate":"2026-11-07T10:00:00Z","fqdn":"dev.test","kubernetesVersion":"v1.35.5",\
    "labels":{},"name":"dev","nodes":[{"kind":"linux","name":"dev","roles":["control-plane"]},\
    {"kind":"linux","name":"dev-worker-1","roles":["worker"]},{"kind":"linux","name":"dev-worker-2","roles":["worker"]}],\
    "remove":false,"sharedImageStore":true},"id":"dev",\
    "status":{"nodes":[{"addresses":["192.168.64.3"],"name":"dev","ports":["6445->6443"],"status":"running"},\
    {"addresses":["192.168.64.4"],"name":"dev-worker-1","status":"running"},{"name":"dev-worker-2","status":"stopped"}],\
    "state":"degraded"}},
    {"configuration":{"kubernetesVersion":"v1.34.11","name":"solo","nodes":[{"name":"solo","roles":["control-plane","worker"]}],\
    "remove":true,"sharedImageStore":false},"id":"solo","status":{"nodes":[],"state":"stopped"}}]
    """

    private let nodesTable = """
    CLUSTER  NODE          ROLE                  STATE    CPUS  MEMORY  ADDR          PORTS
    dev      dev           control-plane         running  2     4 GB    192.168.64.3  6445->6443
    dev      dev-worker-1  worker                running  4     1.5 GB  192.168.64.4
    dev      dev-worker-2  worker                stopped  4     1.5 GB
    solo     solo          control-plane,worker  stopped
    """

    @Test func parsesTheJSONList() throws {
        let clusters = try #require(ContainerCluster.parseJSON(Data(json.utf8)))
        #expect(clusters.map(\.name) == ["dev", "solo"])
        let dev = clusters[0]
        #expect(dev.kubernetesVersion == "v1.35.5")
        #expect(dev.sharedImageStore == true)
        #expect(dev.nodes.map(\.name) == ["dev", "dev-worker-1", "dev-worker-2"])
        #expect(dev.controlPlane?.address == "192.168.64.3")
        #expect(dev.apiServerPort == 6445)
        #expect(dev.nodes[2].state == "stopped")
        #expect(dev.state == "degraded")

        let solo = clusters[1]
        #expect(solo.sharedImageStore == false)
        #expect(solo.nodes.count == 1)
        #expect(solo.controlPlane?.name == "solo")
        // A node without a status entry is stopped.
        #expect(solo.nodes[0].state == "stopped")
    }

    @Test func rejectsOtherJSON() {
        #expect(ContainerCluster.parseJSON(Data("{}".utf8)) == nil)
        #expect(ContainerCluster.parseJSON(Data("not json".utf8)) == nil)
        #expect(ContainerCluster.parseJSON(Data("[]".utf8)) == [])
    }

    @Test func nodesTableParsesFormattedMemory() throws {
        let clusters = ContainerCluster.parseList(nodesTable)
        #expect(clusters.map(\.name) == ["dev", "solo"])
        let dev = try #require(clusters.first)
        #expect(dev.controlPlane?.memoryMB == 4096)
        #expect(dev.workers.first?.memoryMB == 1536)
        #expect(dev.workers.first?.cpus == 4)
        #expect(clusters[1].nodes.first?.roles == ["control-plane", "worker"])
    }

    @Test func mergesResourcesIntoTheJSONNodes() throws {
        let table = ContainerCluster.parseList(nodesTable)
        let merged = try #require(ContainerCluster.parseJSON(Data(json.utf8))).map { $0.mergingResources(from: table) }
        let dev = merged[0]
        #expect(dev.controlPlane?.cpus == 2)
        #expect(dev.controlPlane?.memoryMB == 4096)
        #expect(dev.workers.map(\.cpus) == [4, 4])
        #expect(dev.kubernetesVersion == "v1.35.5")
        #expect(merged[1].nodes[0].cpus == 0)
    }

    @Test func memoryFormats() {
        #expect(ContainerCluster.parseMemoryMB("2048 MB") == 2048)
        #expect(ContainerCluster.parseMemoryMB("2 GB") == 2048)
        #expect(ContainerCluster.parseMemoryMB("1,5 GB") == 1536)
        #expect(ContainerCluster.parseMemoryMB("1 TB") == 1_048_576)
        #expect(ContainerCluster.parseMemoryMB("512 KB") == 1)
        #expect(ContainerCluster.parseMemoryMB("") == 0)
    }

    @Test func listArguments() {
        #expect(AppleContainerControl.listArguments(perClusterList: false) == ["cluster", "list"])
        #expect(AppleContainerControl.listArguments(perClusterList: true) == ["cluster", "list", "--nodes"])
        #expect(AppleContainerControl.listArguments(command: "k8s", perClusterList: false) == ["k8s", "list"])
        #expect(AppleContainerControl.listJSONArguments() == ["cluster", "list", "--format", "json"])
    }
}

struct ClusterCreate17Tests {
    @Test func sizedWorkersUseTheGroupSyntax() {
        let options = AppleContainerControl.ClusterCreateOptions(
            name: "dev", workers: 2, cpus: 2, memory: "4G", workerCPUs: 4, workerMemory: "8G"
        )
        let args = options.arguments()
        #expect(args.suffix(2) == ["--workers", "count=2,cpus=4,memory=8G"])
        #expect(args.contains("--cpus") && args.contains("4G"))
    }

    @Test func workersWithoutSizeStayANumber() {
        let options = AppleContainerControl.ClusterCreateOptions(name: "dev", workers: 3)
        #expect(options.arguments().suffix(2) == ["--workers", "3"])
        let memoryOnly = AppleContainerControl.ClusterCreateOptions(name: "dev", workers: 1, workerMemory: " 2G ")
        #expect(memoryOnly.arguments().suffix(2) == ["--workers", "count=1,memory=2G"])
    }

    @Test func noWorkersIgnoresTheWorkerSize() {
        let options = AppleContainerControl.ClusterCreateOptions(name: "dev", workers: 0, workerCPUs: 4)
        #expect(!options.arguments().contains("--workers"))
    }

    @Test func sharedImageStoreFlag() {
        let shared = AppleContainerControl.ClusterCreateOptions(name: "dev", sharedImageStore: true)
        #expect(shared.arguments().contains("--shared-image-store"))
        #expect(!AppleContainerControl.ClusterCreateOptions(name: "dev").arguments().contains("--shared-image-store"))
    }
}

struct AppleClusterNodeTests {
    private func summary(_ name: String, labels: [String: String]) throws -> ContainerSummary {
        let object: [String: Any] = ["Id": name, "Names": ["/" + name], "State": "running", "Labels": labels]
        return try JSONDecoder().decode(ContainerSummary.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func detectsNodesByThePluginLabel() throws {
        let node = try summary("dev-worker-2", labels: [
            "com.apple.container.plugin": "cluster",
            "com.apple.container.resource.role": "worker"
        ])
        #expect(AppleClusterNode.isClusterNode(node))
        #expect(AppleClusterNode.clusterName(of: node) == "dev")
        #expect(AppleClusterNode.isClusterNode(labels: ["com.apple.container.plugin": "k8s"]))
        let plain = try summary("web", labels: ["com.apple.container.plugin": "builder"])
        #expect(!AppleClusterNode.isClusterNode(plain))
        #expect(AppleClusterNode.clusterName(of: plain) == nil)
    }

    @Test func clusterNameOfANode() {
        #expect(AppleClusterNode.clusterName(forNode: "dev") == "dev")
        #expect(AppleClusterNode.clusterName(forNode: "my-cluster-worker-12") == "my-cluster")
        #expect(AppleClusterNode.clusterName(forNode: "dev-worker-x") == "dev-worker-x")
    }

    @Test func explanationNamesTheCluster() {
        #expect(AppleClusterNode.lifecycleExplanation(cluster: "dev").contains("dev"))
    }
}

@MainActor
struct ClusterNodeLifecycleTests {
    private let containers = """
    [{"Id":"dev","Names":["/dev"],"State":"running","Labels":{"com.apple.container.plugin":"cluster"}},
    {"Id":"web","Names":["/web"],"State":"running","Labels":{}}]
    """

    private func session(kind: DockerHost.Kind) async throws -> (HostSession, MockTransport) {
        let transport = MockTransport()
        transport.on(.get, "/version", json: Fixtures.version)
        transport.on(.get, "/containers/json", json: containers)
        transport.on(.post, "/containers/dev/stop", status: 204, json: "")
        transport.on(.post, "/containers/web/stop", status: 204, json: "")
        let client = DockerClient(transport: transport)
        let version = try await client.negotiate()
        let session = HostSession(host: DockerHost(name: "Host", kind: kind))
        session._setConnectedClientForTesting(client, version: version)
        await session.refreshContainers()
        return (session, transport)
    }

    @Test func refusesLifecycleActionsOnClusterNodes() async throws {
        let (session, transport) = try await session(kind: .appleContainer)
        #expect(session.clusterNodeCluster("dev") == "dev")
        #expect(session.clusterNodeCluster("web") == nil)
        let ok = await session.perform(.stop, on: "dev")
        #expect(!ok)
        #expect(session.lastError?.contains("dev") == true)
        #expect(!transport.executed.contains { $0.path.hasSuffix("/containers/dev/stop") })
    }

    @Test func dockerHostsIgnoreTheLabel() async throws {
        let (session, _) = try await session(kind: .local)
        #expect(session.clusterNodeCluster("dev") == nil)
    }
}
