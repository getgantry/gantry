import Foundation
import Testing
import MCP
import AppCore
@testable import gantry_mcp

@Suite("Cluster tools")
struct ClusterToolTests {
    private let current = ContainerTooling.features(for: "1.6.1")
    private let k8sOnly = ContainerTooling.features(for: "1.5.0")

    @Test func catalogHasClusterTools() async {
        let tools = await GantryTools().toolDefinitions()
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        #expect(byName["list_clusters"]?.annotations.readOnlyHint == true)
        #expect(byName["create_cluster"]?.annotations.destructiveHint == false)
        #expect(byName["delete_cluster"]?.annotations.destructiveHint == true)
    }

    @Test func createOptionsMapEveryArgument() throws {
        let args = Arguments([
            "name": .string("dev"),
            "workers": .int(2),
            "cpus": .int(4),
            "memory": .string("8G"),
            "node_image": .string("kindest/node:v1.35.5"),
            "cni": .string("/tmp/calico.yaml"),
            "remove_on_stop": .bool(true),
            "kubeconfig": .string("/tmp/kube/config")
        ])
        let options = try clusterCreateOptions(args, features: current)
        #expect(options == AppleContainerControl.ClusterCreateOptions(
            name: "dev",
            workers: 2,
            cpus: 4,
            memory: "8G",
            nodeImage: "kindest/node:v1.35.5",
            cni: .manifest("/tmp/calico.yaml"),
            removeOnStop: true,
            kubeconfigPath: "/tmp/kube/config"
        ))
    }

    @Test func cniKeywords() throws {
        let none = try clusterCreateOptions(Arguments(["name": .string("a"), "cni": .string("NONE")]), features: current)
        #expect(none.cni == .none)
        let standard = try clusterCreateOptions(Arguments(["name": .string("a"), "cni": .string("default")]), features: current)
        #expect(standard.cni == .standard)
        let omitted = try clusterCreateOptions(Arguments(["name": .string("a")]), features: current)
        #expect(omitted.cni == .standard)
        #expect(omitted.arguments() == ["cluster", "create", "--name", "a"])
    }

    @Test func rejectsMissingNameAndNegativeWorkers() {
        #expect(throws: (any Error).self) { try clusterCreateOptions(Arguments([:]), features: current) }
        #expect(throws: (any Error).self) {
            try clusterCreateOptions(Arguments(["name": .string("a"), "workers": .int(-1)]), features: current)
        }
    }

    @Test func rejectsWorkersAndNoCNIOnOldCLI() throws {
        #expect(throws: (any Error).self) {
            try clusterCreateOptions(Arguments(["name": .string("a"), "workers": .int(1)]), features: k8sOnly)
        }
        #expect(throws: (any Error).self) {
            try clusterCreateOptions(Arguments(["name": .string("a"), "cni": .string("none")]), features: k8sOnly)
        }
        let plain = try clusterCreateOptions(Arguments(["name": .string("a"), "workers": .int(0)]), features: k8sOnly)
        #expect(plain.arguments(command: "k8s") == ["k8s", "create", "--name", "a"])
    }

    @Test func workerSizeAndSharedImagesOnCLI17() throws {
        let v17 = ContainerTooling.features(for: "1.7.1")
        let args = Arguments([
            "name": .string("dev"),
            "workers": .int(2),
            "worker_cpus": .int(4),
            "worker_memory": .string("8G"),
            "shared_image_store": .bool(true)
        ])
        let options = try clusterCreateOptions(args, features: v17)
        #expect(options.workerCPUs == 4)
        #expect(options.workerMemory == "8G")
        #expect(options.sharedImageStore)
        #expect(options.arguments().contains("--shared-image-store"))
        #expect(options.arguments().suffix(2) == ["--workers", "count=2,cpus=4,memory=8G"])
    }

    @Test func rejectsWorkerSizeAndSharedImagesBefore17() {
        #expect(throws: (any Error).self) {
            try clusterCreateOptions(Arguments(["name": .string("a"), "workers": .int(1), "worker_cpus": .int(2)]), features: current)
        }
        #expect(throws: (any Error).self) {
            try clusterCreateOptions(Arguments(["name": .string("a"), "shared_image_store": .bool(true)]), features: current)
        }
        // A worker size needs workers.
        #expect(throws: (any Error).self) {
            try clusterCreateOptions(
                Arguments(["name": .string("a"), "worker_memory": .string("2G")]),
                features: ContainerTooling.features(for: "1.7.1")
            )
        }
    }

    @Test func clusterToolsRejectUnknownHost() async {
        for name in ["list_clusters", "create_cluster", "delete_cluster"] {
            let result = await GantryTools().call(
                name: name,
                arguments: ["host_id": .string(UUID().uuidString), "name": .string("dev")]
            )
            #expect(result.isErrorResult, "\(name) should fail for an unknown host")
            #expect(result.text.contains("No host with id"))
        }
    }

    @Test func clusterDTOShape() throws {
        let cluster = try #require(ContainerCluster.parseList("""
        CLUSTER  NODE          ROLE           STATE    CPUS  MEMORY   ADDR          PORTS
        dev      dev           control-plane  running  2     2048 MB  192.168.64.3  6445->6443
        dev      dev-worker-1  worker         running  2     2048 MB  192.168.64.4
        """).first)
        let json = try jsonText(ClusterDTO(cluster))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["name"] as? String == "dev")
        #expect(object["kubectlContext"] as? String == "dev")
        #expect(object["apiServer"] as? String == "https://127.0.0.1:6445")
        let nodes = try #require(object["nodes"] as? [[String: Any]])
        #expect(nodes.count == 2)
        #expect(nodes[0]["roles"] as? [String] == ["control-plane"])
        #expect(nodes[1]["memoryBytes"] as? Int == 2_147_483_648)
    }
}
