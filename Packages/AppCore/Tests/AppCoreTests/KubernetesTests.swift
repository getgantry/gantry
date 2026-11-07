import Foundation
import Testing
import DockerKit
@testable import AppCore

// Fixtures follow the shape of API list responses (Kubernetes 1.31),
// trimmed to the fields the browser reads.

private func json(_ text: String) -> Data { Data(text.utf8) }

struct KubeConfigTests {
    private let config = """
    apiVersion: v1
    kind: Config
    current-context: docker-desktop
    clusters:
    - name: docker-desktop
      cluster: {server: "https://127.0.0.1:6443"}
    - name: dev
      cluster: {server: "https://127.0.0.1:6445"}
    contexts:
    - name: docker-desktop
      context: {cluster: docker-desktop, user: docker-desktop}
    - name: staging
      context: {cluster: staging, user: admin, namespace: web}
    - name: dev
      context: {cluster: dev, user: dev}
    """

    @Test func parsesContextsAppleFirst() throws {
        let contexts = try KubeConfigFile(yaml: config, directory: "/k").contextList(appleClusters: ["dev"])
        #expect(contexts.map(\.name) == ["dev", "docker-desktop", "staging"])
        #expect(contexts[0].isAppleCluster)
        #expect(contexts[0].server == "https://127.0.0.1:6445")
        #expect(contexts[1].isCurrent)
        #expect(contexts[2].namespace == "web")
        #expect(contexts[2].server == nil)
    }

    @Test func preferredContextOrder() throws {
        let contexts = try KubeConfigFile(yaml: config, directory: "/k").contextList(appleClusters: ["dev"])
        #expect(KubeConfig.preferredContext(contexts, remembered: "staging") == "staging")
        #expect(KubeConfig.preferredContext(contexts, remembered: "gone") == "docker-desktop")
        #expect(KubeConfig.preferredContext([], remembered: nil) == nil)
    }

    @Test func pathsUseEnvironmentAndClusterFiles() {
        let existing: Set = ["/h/.kube/config", "/h/.kube/dev.kubeconfig", "/a", "/b"]
        let defaults = KubeConfig.paths(
            environment: [:], home: "/h",
            clusterFiles: ["~/.kube/dev.kubeconfig", "/missing", "/h/.kube/config"],
            fileExists: existing.contains
        )
        #expect(defaults == ["/h/.kube/config", "/h/.kube/dev.kubeconfig"])

        let fromEnvironment = KubeConfig.paths(
            environment: ["KUBECONFIG": "/a:/b"], home: "/h", clusterFiles: [], fileExists: existing.contains
        )
        #expect(fromEnvironment == ["/a", "/b"])
    }

    @Test func clusterStoreListsEntries() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kube-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        ClusterKubeconfigStore.record("/k/dev.yaml", host: "Local", cluster: "dev", file: file)
        ClusterKubeconfigStore.record("/k/b.yaml", host: "Local", cluster: "b", file: file)
        let entries = ClusterKubeconfigStore.entries(file: file)
        #expect(entries.map(\.cluster) == ["b", "dev"])
        #expect(entries.map(\.path) == ["/k/b.yaml", "/k/dev.yaml"])
    }
}

struct KubeResourceParserTests {
    private let pods = json("""
    {"kind": "List", "items": [
      {"metadata": {"name": "web-1", "namespace": "default", "uid": "u1", "creationTimestamp": "2026-11-01T10:00:00Z"},
       "spec": {"nodeName": "dev", "containers": [
         {"name": "app", "image": "nginx:1.27", "ports": [{"containerPort": 80, "name": "http", "protocol": "TCP"}]},
         {"name": "sidecar", "image": "busybox"}]},
       "status": {"phase": "Running", "podIP": "10.244.0.5", "containerStatuses": [
         {"name": "app", "ready": true, "restartCount": 2, "state": {"running": {}}},
         {"name": "sidecar", "ready": true, "restartCount": 1, "state": {"running": {}}}]}},
      {"metadata": {"name": "crash", "namespace": "default", "uid": "u2"},
       "spec": {"containers": [{"name": "app", "image": "bad"}]},
       "status": {"phase": "Running", "containerStatuses": [
         {"name": "app", "ready": false, "restartCount": 7, "state": {"waiting": {"reason": "CrashLoopBackOff"}}}]}},
      {"metadata": {"name": "init", "namespace": "default", "uid": "u3"},
       "spec": {"containers": [{"name": "app", "image": "x"}]},
       "status": {"phase": "Pending", "initContainerStatuses": [{"name": "setup", "state": {"running": {}}}]}},
      {"metadata": {"name": "job", "namespace": "default", "uid": "u4"},
       "spec": {"containers": [{"name": "app", "image": "x"}]},
       "status": {"phase": "Succeeded", "containerStatuses": [
         {"name": "app", "ready": false, "restartCount": 0, "state": {"terminated": {"reason": "Completed", "exitCode": 0}}}]}},
      {"metadata": {"name": "old", "namespace": "default", "uid": "u5", "deletionTimestamp": "2026-11-01T10:00:00Z"},
       "spec": {"containers": [{"name": "app", "image": "x"}]}, "status": {"phase": "Running"}},
      {"metadata": {"name": "evicted", "namespace": "default", "uid": "u6"},
       "spec": {"containers": [{"name": "app", "image": "x"}]}, "status": {"phase": "Failed", "reason": "Evicted"}}
    ]}
    """)

    @Test func parsesPods() throws {
        let items = try KubeResourceParser.parse(pods, kind: .pods)
        #expect(items.count == 6)
        let web = items[0]
        #expect(web.name == "web-1")
        #expect(web.namespace == "default")
        #expect(web.status == "Running")
        #expect(web.health == .ok)
        #expect(web.containers == ["app", "sidecar"])
        #expect(web.ports == [KubePort(port: 80, name: "http")])
        #expect(web.field(KubeFieldLabel.ready) == "2/2")
        #expect(web.field(KubeFieldLabel.restarts) == "3")
        #expect(web.field(KubeFieldLabel.node) == "dev")
        #expect(web.createdAt == ISO8601DateFormatter().date(from: "2026-11-01T10:00:00Z"))
        #expect(web.reference == "pod/web-1")

        #expect(items[1].status == "CrashLoopBackOff")
        #expect(items[1].health == .failed)
        #expect(items[1].field(KubeFieldLabel.ready) == "0/1")
        #expect(items[2].status == "Init:Running")
        #expect(items[2].health == .progressing)
        #expect(items[3].status == "Completed")
        #expect(items[3].health == .neutral)
        #expect(items[4].status == "Terminating")
        #expect(items[5].status == "Evicted")
        #expect(items[5].health == .failed)
    }

    @Test func parsesDeploymentsAndStatefulSets() throws {
        let data = json("""
        {"items": [
          {"metadata": {"name": "api", "namespace": "web", "uid": "d1"},
           "spec": {"replicas": 3, "template": {"spec": {"containers": [{"name": "api", "image": "api:2"}]}}},
           "status": {"readyReplicas": 2, "updatedReplicas": 3, "availableReplicas": 2}},
          {"metadata": {"name": "idle", "namespace": "web", "uid": "d2"},
           "spec": {"replicas": 0}, "status": {}},
          {"metadata": {"name": "ok", "namespace": "web", "uid": "d3"},
           "spec": {"replicas": 1}, "status": {"readyReplicas": 1, "updatedReplicas": 1, "availableReplicas": 1}}
        ]}
        """)
        let items = try KubeResourceParser.parse(data, kind: .deployments)
        #expect(items[0].status == "2/3")
        #expect(items[0].replicas == 3)
        #expect(items[0].health == .progressing)
        #expect(items[0].field(KubeFieldLabel.images) == "api:2")
        #expect(items[0].field(KubeFieldLabel.available) == "2")
        #expect(items[1].health == .neutral)
        #expect(items[2].health == .ok)

        let sets = try KubeResourceParser.parse(data, kind: .statefulSets)
        #expect(sets[0].field(KubeFieldLabel.available) == nil)
        #expect(sets[0].reference == "statefulset/api")
    }

    @Test func parsesDaemonSets() throws {
        let data = json("""
        {"items": [{"metadata": {"name": "kindnet", "namespace": "kube-system", "uid": "ds"},
          "status": {"desiredNumberScheduled": 2, "numberReady": 2, "updatedNumberScheduled": 2, "numberAvailable": 2}}]}
        """)
        let item = try #require(try KubeResourceParser.parse(data, kind: .daemonSets).first)
        #expect(item.status == "2/2")
        #expect(item.health == .ok)
    }

    @Test func parsesServicesAndIngresses() throws {
        let services = json("""
        {"items": [{"metadata": {"name": "web", "namespace": "default", "uid": "s1"},
          "spec": {"type": "LoadBalancer", "clusterIP": "10.96.0.10",
                   "ports": [{"port": 80, "protocol": "TCP", "nodePort": 30080}, {"port": 443, "name": "https"}]},
          "status": {"loadBalancer": {"ingress": [{"ip": "192.168.64.20"}]}}}]}
        """)
        let service = try #require(try KubeResourceParser.parse(services, kind: .services).first)
        #expect(service.status == "LoadBalancer")
        #expect(service.field(KubeFieldLabel.ports) == "80:30080/TCP, 443/TCP")
        #expect(service.field(KubeFieldLabel.externalIP) == "192.168.64.20")
        #expect(service.ports.map(\.port) == [80, 443])

        let ingresses = json("""
        {"items": [{"metadata": {"name": "site", "namespace": "default", "uid": "i1"},
          "spec": {"ingressClassName": "nginx", "rules": [{"host": "a.test"}, {"host": "b.test"}]},
          "status": {"loadBalancer": {"ingress": [{"hostname": "lb.local"}]}}}]}
        """)
        let ingress = try #require(try KubeResourceParser.parse(ingresses, kind: .ingresses).first)
        #expect(ingress.field(KubeFieldLabel.hosts) == "a.test, b.test")
        #expect(ingress.field(KubeFieldLabel.address) == "lb.local")
        #expect(ingress.status == "nginx")
    }

    @Test func parsesConfigMapsSecretsAndNodes() throws {
        let maps = json("""
        {"items": [{"metadata": {"name": "conf", "namespace": "default", "uid": "c1"}, "data": {"a": "1", "b": "2"}, "binaryData": {"c": "AA=="}}]}
        """)
        #expect(try KubeResourceParser.parse(maps, kind: .configMaps).first?.field(KubeFieldLabel.keys) == "3")

        let secrets = json("""
        {"items": [{"metadata": {"name": "tls", "namespace": "default", "uid": "x1"}, "type": "kubernetes.io/tls", "data": {"tls.crt": "YQ==", "tls.key": "Yg=="}}]}
        """)
        let secret = try #require(try KubeResourceParser.parse(secrets, kind: .secrets).first)
        #expect(secret.status == "kubernetes.io/tls")
        #expect(secret.field(KubeFieldLabel.keys) == "2")

        let nodes = json("""
        {"items": [
          {"metadata": {"name": "dev", "namespace": "ignored", "uid": "n1", "labels": {"node-role.kubernetes.io/control-plane": ""}},
           "spec": {}, "status": {"conditions": [{"type": "Ready", "status": "True"}],
             "nodeInfo": {"kubeletVersion": "v1.31.0"}, "addresses": [{"type": "InternalIP", "address": "192.168.64.13"}]}},
          {"metadata": {"name": "w1", "uid": "n2"}, "spec": {"unschedulable": true},
           "status": {"conditions": [{"type": "Ready", "status": "True"}]}},
          {"metadata": {"name": "w2", "uid": "n3"}, "spec": {}, "status": {"conditions": [{"type": "Ready", "status": "False"}]}}
        ]}
        """)
        let items = try KubeResourceParser.parse(nodes, kind: .nodes)
        #expect(items[0].namespace == nil)
        #expect(items[0].status == "Ready")
        #expect(items[0].health == .ok)
        #expect(items[0].field(KubeFieldLabel.roles) == "control-plane")
        #expect(items[0].field(KubeFieldLabel.version) == "v1.31.0")
        #expect(items[0].field(KubeFieldLabel.internalIP) == "192.168.64.13")
        #expect(items[1].status == "Ready,SchedulingDisabled")
        #expect(items[1].health == .warning)
        #expect(items[2].health == .failed)
    }

    @Test func parsesEventsNewestFirst() throws {
        let data = json("""
        {"items": [
          {"metadata": {"name": "e1", "namespace": "default", "uid": "e1"}, "type": "Normal", "reason": "Pulled",
           "message": "Pulled image", "count": 1, "lastTimestamp": "2026-11-01T10:00:00Z",
           "involvedObject": {"kind": "Pod", "name": "web-1"}},
          {"metadata": {"name": "e2", "namespace": "default", "uid": "e2"}, "type": "Warning", "reason": "BackOff",
           "message": "Back-off restarting\\n", "count": 4, "lastTimestamp": "2026-11-01T11:00:00Z",
           "involvedObject": {"kind": "Pod", "name": "crash"}},
          {"metadata": {"name": "e3", "namespace": "default", "uid": "e3"}, "type": "Normal", "reason": "Scheduled",
           "eventTime": "2026-11-01T10:30:00.123456Z", "involvedObject": {"kind": "Pod", "name": "web-2"}}
        ]}
        """)
        let items = try KubeResourceParser.parse(data, kind: .events)
        #expect(items.map(\.name) == ["e2", "e3", "e1"])
        #expect(items[0].health == .warning)
        #expect(items[0].status == "BackOff")
        #expect(items[0].field(KubeFieldLabel.object) == "Pod/crash")
        #expect(items[0].field(KubeFieldLabel.message) == "Back-off restarting")
        #expect(items[0].field(KubeFieldLabel.count) == "4")
    }

    @Test func parsesNamespacesAndRejectsGarbage() throws {
        let data = json(#"{"items": [{"metadata": {"name": "web"}}, {"metadata": {"name": "default"}}]}"#)
        #expect(try KubeResourceParser.namespaces(data) == ["default", "web"])
        #expect(throws: (any Error).self) { try KubeResourceParser.parse(json("[]"), kind: .pods) }
        #expect(throws: (any Error).self) { try KubeResourceParser.parse(json("not json"), kind: .pods) }
    }

    @Test func kindCapabilities() {
        #expect(KubeResourceKind.allCases.filter(\.canScale) == [.deployments, .statefulSets])
        #expect(KubeResourceKind.allCases.filter(\.canRestart) == [.deployments, .statefulSets, .daemonSets])
        #expect(!KubeResourceKind.events.canDelete)
        #expect(!KubeResourceKind.nodes.isNamespaced)
        #expect(KubeResourceKind.allCases.filter(\.canPortForward) == [.pods, .services])
    }
}

struct KubeSecretDataTests {
    private let secret = json("""
    {"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
     "metadata": {"name": "db", "namespace": "default",
       "annotations": {"kubectl.kubernetes.io/last-applied-configuration": "{\\"data\\":{\\"password\\":\\"c2VjcmV0\\"}}", "team": "core"}},
     "data": {"password": "c2VjcmV0", "blob": "/w=="},
     "stringData": {"plain": "text"},
     "immutable": false}
    """)

    @Test func entriesDecodeOnDemand() throws {
        let entries = try KubeSecretData.entries(fromJSON: secret)
        #expect(entries.map(\.key) == ["blob", "password"])
        #expect(entries[1].text == "secret")
        #expect(entries[0].text == nil)
        #expect(entries[0].byteCount == 1)
    }

    @Test func yamlHidesEveryValue() throws {
        let yaml = try KubeSecretData.redactedYAML(fromJSON: secret)
        #expect(!yaml.contains("c2VjcmV0"))
        #expect(!yaml.contains("text"))
        #expect(yaml.contains("password: \(KubeSecretData.mask)"))
        #expect(yaml.contains("team: core"))
        #expect(yaml.contains("immutable: false"))
        #expect(yaml.contains("kind: Secret"))
    }
}
