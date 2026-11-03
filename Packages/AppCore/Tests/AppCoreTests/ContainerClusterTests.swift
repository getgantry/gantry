import Foundation
import Testing
@testable import AppCore

// Fixtures captured from `container cluster list` (apple/container 1.6.1).

struct ContainerClusterTests {
    private let twoNodes = """
    CLUSTER       NODE                   ROLE           STATE    CPUS  MEMORY   ADDR           PORTS
    gantry-probe  gantry-probe           control-plane  running  2     2048 MB  192.168.64.13  6445->6443
    gantry-probe  gantry-probe-worker-1  worker         running  2     2048 MB  192.168.64.14
    """

    @Test func parsesClusterWithWorker() throws {
        let clusters = ContainerCluster.parseList(twoNodes)
        let cluster = try #require(clusters.first)
        #expect(clusters.count == 1)
        #expect(cluster.name == "gantry-probe")
        #expect(cluster.nodes.count == 2)
        #expect(cluster.isRunning)
        #expect(cluster.state == "running")

        let cp = try #require(cluster.controlPlane)
        #expect(cp.name == "gantry-probe")
        #expect(cp.cpus == 2)
        #expect(cp.memoryMB == 2048)
        #expect(cp.memoryBytes == 2_147_483_648)
        #expect(cp.address == "192.168.64.13")
        #expect(cp.ports == "6445->6443")

        let worker = try #require(cluster.workers.first)
        #expect(worker.name == "gantry-probe-worker-1")
        #expect(worker.role == "worker")
        #expect(worker.ports.isEmpty)
        #expect(cluster.apiServerPort == 6445)
        #expect(cluster.apiServerURL == "https://127.0.0.1:6445")
        #expect(cluster.kubectlContext == "gantry-probe")
    }

    @Test func emptyListHasOnlyTheHeader() {
        let output = "CLUSTER  NODE  ROLE  STATE  CPUS  MEMORY  ADDR  PORTS\n"
        #expect(ContainerCluster.parseList(output).isEmpty)
        #expect(ContainerCluster.parseList("").isEmpty)
    }

    @Test func stoppedNodeKeepsEmptyAddressInItsColumn() throws {
        let output = """
        CLUSTER  NODE           ROLE           STATE    CPUS  MEMORY   ADDR          PORTS
        dev      dev            control-plane  running  4     8192 MB  192.168.64.3  6443->6443
        dev      dev-worker-1   worker         stopped  4     8192 MB
        dev      dev-worker-2   worker         running  4     8192 MB  192.168.64.5
        """
        let cluster = try #require(ContainerCluster.parseList(output).first)
        #expect(cluster.nodes.map(\.name) == ["dev", "dev-worker-1", "dev-worker-2"])
        #expect(cluster.nodes[1].state == "stopped")
        #expect(cluster.nodes[1].address.isEmpty)
        #expect(cluster.nodes[2].address == "192.168.64.5")
        #expect(cluster.state == "degraded")
        #expect(!cluster.isRunning)
    }

    @Test func groupsSeveralClustersAndKeepsControlPlaneFirst() {
        let output = """
        CLUSTER  NODE        ROLE                  STATE    CPUS  MEMORY   ADDR          PORTS
        a        a-worker-1  worker                running  2     2048 MB  192.168.64.4
        a        a           control-plane         running  2     2048 MB  192.168.64.3  6443->6443
        b        b           control-plane,worker  running  2     4096 MB  192.168.64.6  6444->6443
        """
        let clusters = ContainerCluster.parseList(output)
        #expect(clusters.map(\.name) == ["a", "b"])
        #expect(clusters[0].nodes.first?.name == "a")
        #expect(clusters[1].nodes.first?.roles == ["control-plane", "worker"])
        #expect(clusters[1].nodes.first?.isControlPlane == true)
        #expect(clusters[1].workers.isEmpty)
        #expect(clusters[1].apiServerPort == 6444)
    }

    @Test func fallsBackToWordSplitWithoutHeader() throws {
        let output = "dev  dev  control-plane  running  2  2048 MB  192.168.64.3  6443->6443"
        let node = try #require(ContainerCluster.parseList(output).first?.nodes.first)
        #expect(node.name == "dev")
        #expect(node.memoryMB == 2048)
        #expect(node.address == "192.168.64.3")
        #expect(node.ports == "6443->6443")
    }

    @Test func misalignedRowFallsBackToWordSplit() throws {
        let output = """
        CLUSTER  NODE  ROLE  STATE  CPUS  MEMORY  ADDR  PORTS
        dev  dev  control-plane  running  2  2048 MB  192.168.64.3  6443->6443
        """
        let node = try #require(ContainerCluster.parseList(output).first?.nodes.first)
        #expect(node.state == "running")
        #expect(node.cpus == 2)
        #expect(node.ports == "6443->6443")
    }

    @Test func memoryUnits() {
        #expect(ContainerCluster.parseMemoryMB("2048 MB") == 2048)
        #expect(ContainerCluster.parseMemoryMB("2 GB") == 2048)
        #expect(ContainerCluster.parseMemoryMB("512") == 512)
        #expect(ContainerCluster.parseMemoryMB("") == 0)
    }

    @Test func defaultKubeconfigPath() {
        #expect(ContainerCluster.defaultKubeconfigPath(for: "dev", home: "/Users/me") == "/Users/me/.kube/dev.kubeconfig")
    }

    @Test func networkNamesFromInspect() {
        let data = Data("""
        [{"configuration":{"id":"dev","networks":[{"network":"default"}]},"status":{"networks":[{"network":"k8s-net","ipv4Address":"192.168.65.2/24"}]}},
         {"configuration":{"id":"dev-worker-1","networks":[{"network":"k8s-net"}]}}]
        """.utf8)
        #expect(ContainerCluster.networkNames(fromInspectJSON: data) == ["k8s-net"])
        #expect(ContainerCluster.networkNames(fromInspectJSON: Data("oops".utf8)).isEmpty)
    }

    // MARK: - Create progress

    @Test func parsesStatusLines() throws {
        let joining = try #require(ClusterCreateProgress.parse("[3/5] Joining worker dev-worker-1 [1m 2s]"))
        #expect(joining.step == 3)
        #expect(joining.total == 5)
        #expect(joining.message == "Joining worker dev-worker-1")
        #expect(joining.elapsed == "1m 2s")
        #expect(joining.fraction == 0.6)

        let first = try #require(ClusterCreateProgress.parse("[0/5] [0s]"))
        #expect(first.message.isEmpty)
        #expect(first.elapsed == "0s")

        #expect(ClusterCreateProgress.parse("Waiting for API server to become available") == nil)
        #expect(ClusterCreateProgress.parse("Pulling cluster node image: [\"ref\": x]") == nil)
    }

    // MARK: - Arguments

    @Test func createArgumentsLeaveDefaultsOut() {
        let options = AppleContainerControl.ClusterCreateOptions(name: "dev")
        #expect(options.arguments() == ["cluster", "create", "--name", "dev"])
        #expect(options.arguments(command: "k8s") == ["k8s", "create", "--name", "dev"])
    }

    @Test func createArgumentsWithEveryOption() {
        let options = AppleContainerControl.ClusterCreateOptions(
            name: "dev",
            workers: 2,
            cpus: 4,
            memory: "8G",
            nodeImage: " kindest/node:v1.35.5 ",
            cni: .manifest("/tmp/calico.yaml"),
            removeOnStop: true,
            scheme: "http",
            maxConcurrentDownloads: 5
        )
        #expect(options.arguments() == [
            "cluster", "create", "--name", "dev", "--rm",
            "--cpus", "4", "--memory", "8G", "--scheme", "http",
            "--max-concurrent-downloads", "5",
            "--node-image", "kindest/node:v1.35.5",
            "--cni", "/tmp/calico.yaml",
            "--workers", "2"
        ])
    }

    @Test func createArgumentsForNoCNIAndZeroWorkers() {
        let none = AppleContainerControl.ClusterCreateOptions(name: "dev", workers: 0, cni: .none)
        #expect(none.arguments() == ["cluster", "create", "--name", "dev", "--cni", "NONE"])
        let emptyManifest = AppleContainerControl.ClusterCreateOptions(name: "dev", cni: .manifest("  "))
        #expect(emptyManifest.arguments() == ["cluster", "create", "--name", "dev"])
    }

    @Test func writeConfigAndLoadImageArguments() {
        #expect(AppleContainerControl.writeConfigArguments("dev", kubeconfigPath: "/tmp/k") ==
            ["cluster", "write-config", "--name", "dev", "--kubeconfig", "/tmp/k"])
        #expect(AppleContainerControl.loadImageArguments("app:1", cluster: "dev", command: "k8s") ==
            ["k8s", "load-image", "--name", "dev", "app:1"])
        #expect(AppleContainerControl.loadImageArguments(
            "app:1", cluster: "dev", platform: "linux/amd64", nodes: ["dev-worker-1"]
        ) == ["cluster", "load-image", "--name", "dev", "app:1", "--platform", "linux/amd64", "--node", "dev-worker-1"])
    }

    @Test func kubectlContextCommand() {
        #expect(AppleContainerControl.kubectlUseContextCommand(for: "dev") == "kubectl config use-context dev")
        #expect(AppleContainerControl.kubectlUseContextCommand(for: "dev", kubeconfigPath: "/Users/me/.kube/dev.kubeconfig")
            == "KUBECONFIG=/Users/me/.kube/dev.kubeconfig kubectl config use-context dev")
        #expect(AppleContainerControl.kubectlUseContextCommand(for: "dev", kubeconfigPath: "/Users/me/My Configs/k")
            == "KUBECONFIG='/Users/me/My Configs/k' kubectl config use-context dev")
    }
}
