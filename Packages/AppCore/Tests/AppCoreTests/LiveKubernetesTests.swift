import Foundation
import Testing
@testable import AppCore

// Live test of the native Kubernetes client. Gated:
//   GANTRY_K8S_LIVE_CONTEXT=gtest swift test --filter LiveKubernetes
// Lists nodes and pods, reads logs, execs, applies and forwards ports. It
// creates and deletes only the namespace `gantry-test`. Run it with
// `env PATH=/usr/bin:/bin` to prove that it needs no kubectl.

private let liveContext = ProcessInfo.processInfo.environment["GANTRY_K8S_LIVE_CONTEXT"].flatMap { $0.isEmpty ? nil : $0 }

private let testManifest = """
apiVersion: v1
kind: Namespace
metadata:
  name: gantry-test
---
apiVersion: v1
kind: Pod
metadata:
  name: echo
  namespace: gantry-test
  labels:
    app: gantry-echo
spec:
  terminationGracePeriodSeconds: 1
  containers:
  - name: echo
    image: docker.io/library/alpine:3.22
    command: ["sh", "-c", "printf '#!/bin/sh\\\\necho pong-from-gantry\\\\n' > /p.sh; chmod +x /p.sh; exec nc -lk -p 8080 -e /p.sh"]
    ports:
    - name: echo
      containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: echo
  namespace: gantry-test
spec:
  selector:
    app: gantry-echo
  ports:
  - port: 80
    targetPort: echo
"""

@Suite(.enabled(if: liveContext != nil), .serialized, .timeLimit(.minutes(5)))
struct LiveKubernetesTests {
    private func client() throws -> KubeAPIClient {
        let config = try KubeConfigFile.load(paths: KubeConfig.paths())
        return KubeAPIClient(connection: try config.connection(for: liveContext!))
    }

    private func demoPod(_ client: KubeAPIClient) async throws -> KubeResource {
        let pods = try await client.list(.pods, namespace: "default")
        return try #require(pods.first { $0.name.hasPrefix("gantry-demo") && $0.status == "Running" })
    }

    @Test func listsNodesPodsAndReadsLogs() async throws {
        let client = try client()
        let nodes = try await client.list(.nodes, namespace: nil)
        #expect(nodes.count >= 1)
        #expect(nodes.allSatisfy { $0.health == .ok })
        #expect(try await client.namespaces().contains("kube-system"))

        let demo = try await demoPod(client)
        let logs = try await client.send(KubeRequests.logs(pod: demo, container: nil, follow: false, tail: 3))
        #expect(String(decoding: logs, as: UTF8.self).contains("hello from gantry"))

        // Follow: the first line comes from the tail, the next one live.
        var seen: [String] = []
        for try await line in client.lines(KubeRequests.logs(pod: demo, container: nil, follow: true, tail: 1)) {
            seen.append(line)
            if seen.count == 2 { break }
        }
        #expect(seen.count == 2)
        #expect(seen.allSatisfy { $0.contains("hello from gantry") })

        let yaml = try await client.yaml(for: demo)
        #expect(yaml.hasPrefix("apiVersion: v1\nkind: Pod\nmetadata:"))
        #expect(!yaml.contains("managedFields"))
    }

    @Test func execRunsACommand() async throws {
        let client = try client()
        let demo = try await demoPod(client)
        let output = try await client.execute(pod: demo, container: nil, command: ["echo", "ok"])
        #expect(output.stdout == "ok\n")
        #expect(output.exitCode == 0)

        let failing = try await client.execute(pod: demo, container: nil, command: ["sh", "-c", "echo bad >&2; exit 3"])
        #expect(failing.stderr == "bad\n", "\(failing)")
        #expect(failing.exitCode == 3)
    }

    @Test @MainActor func shellSessionResizesAndEchoes() async throws {
        let client = try client()
        let demo = try await demoPod(client)
        let session = try await KubePodShellSession.connect(client, pod: demo, container: nil)
        session.resize(cols: 100, rows: 30)
        session.send(Data("stty size; echo marker-$((40+2))\n".utf8))
        var text = ""
        for try await chunk in session.bytes {
            text += String(decoding: chunk, as: UTF8.self)
            if text.contains("marker-42") { break }
        }
        session.terminate()
        #expect(text.contains("30 100"))
    }

    @Test func applyAndPortForward() async throws {
        let client = try client()
        try await waitUntilNamespaceIsGone(client)
        let first = try await client.apply(testManifest, defaultNamespace: "default")
        #expect(first.map(\.reference) == ["namespace/gantry-test", "pod/echo", "service/echo"])
        #expect(first.allSatisfy { $0.succeeded }, "\(first)")
        let again = try await client.apply(testManifest, defaultNamespace: "default")
        #expect(again.allSatisfy { $0.outcome == .configured }, "\(again)")

        let pod = KubeResource(kind: .pods, name: "echo", namespace: "gantry-test")
        try await waitUntilReady(client, pod)

        let direct = try await KubePortForwarder.start(client, pod: pod, port: 8080, localPort: 0) { print("forward error: \($0)") }
        #expect(direct.localPort > 0)
        #expect(await readLine(port: direct.localPort) == "pong-from-gantry")
        #expect(await readLine(port: direct.localPort) == "pong-from-gantry")
        direct.stop()

        let service = KubeResource(kind: .services, name: "echo", namespace: "gantry-test")
        let target = try await client.portForwardTarget(service, port: 80)
        #expect(target == KubePortForwardTarget(pod: pod, port: 8080))
        let viaService = try await KubePortForwarder.start(client, pod: target.pod, port: target.port, localPort: 0) { _ in }
        #expect(await readLine(port: viaService.localPort) == "pong-from-gantry")
        viaService.stop()

        try await client.send(KubeRequest(.delete, "/api/v1/namespaces/gantry-test", query: [URLQueryItem(name: "propagationPolicy", value: "Background")]))
    }

    /// A namespace from an earlier run may still terminate.
    @Test @MainActor func browserWatchSeesChanges() async throws {
        let browser = KubernetesBrowser(defaults: UserDefaults(suiteName: "kube-\(UUID().uuidString)")!)
        await browser.prepare()
        browser.selectedContext = liveContext
        browser.namespace = "default"
        browser.kind = .configMaps
        let client = try #require(browser.client)
        let watch = Task { await browser.watch() }
        defer { watch.cancel() }
        for _ in 0..<50 where !browser.isWatching { try await Task.sleep(for: .milliseconds(100)) }
        #expect(browser.isWatching)
        let name = "gantry-watch-\(Int.random(in: 1000...9999))"
        _ = try await client.apply("apiVersion: v1\nkind: ConfigMap\nmetadata: {name: \(name)}\ndata: {a: b}\n", defaultNamespace: "default")
        for _ in 0..<50 where !browser.resources.contains(where: { $0.name == name }) { try await Task.sleep(for: .milliseconds(100)) }
        #expect(browser.resources.contains { $0.name == name })
        try await client.delete(KubeResource(kind: .configMaps, name: name, namespace: "default"))
        for _ in 0..<50 where browser.resources.contains(where: { $0.name == name }) { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!browser.resources.contains { $0.name == name })
    }

    private func waitUntilNamespaceIsGone(_ client: KubeAPIClient) async throws {
        for _ in 0..<120 {
            do {
                try await client.send(KubeRequest(.get, "/api/v1/namespaces/gantry-test"))
            } catch let error as KubeAPIError where error.statusCode == 404 {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private func waitUntilReady(_ client: KubeAPIClient, _ pod: KubeResource) async throws {
        for _ in 0..<120 {
            let pods = try await client.list(.pods, namespace: pod.namespace)
            if let found = pods.first(where: { $0.name == pod.name }), found.health == .ok { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        Issue.record("the pod did not get ready")
    }

    /// Reads one line from 127.0.0.1:port. busybox `nc -lk` serves one
    /// connection at a time, so an empty answer is tried again.
    private func readLine(port: Int) async -> String {
        for _ in 0..<5 {
            let line = await readLineOnce(port: port)
            if !line.isEmpty { return line }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return ""
    }

    private func readLineOnce(port: Int) async -> String {
        await Task.detached {
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            defer { close(socket) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var timeout = timeval(tv_sec: 15, tv_usec: 0)
            setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard connected == 0 else { return "" }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 256)
            while !data.contains(0x0A) {
                let count = read(socket, &buffer, buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer[0..<count])
            }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
