import Foundation
import Testing
import DockerKit
@testable import AppCore

private func json(_ text: String) -> Data { Data(text.utf8) }

struct KubeConfigFileTests {
    private let base64CA = Data("CA-PEM".utf8).base64EncodedString()

    private var config: String {
        """
        apiVersion: v1
        kind: Config
        current-context: certs
        clusters:
        - name: local
          cluster:
            server: https://127.0.0.1:6445
            certificate-authority-data: \(base64CA)
        - name: files
          cluster:
            server: https://10.0.0.1:6443/prefix
            certificate-authority: ca.crt
            tls-server-name: kubernetes
            proxy-url: socks5://127.0.0.1:1080
        - name: open
          cluster: {server: "https://dev.example:443", insecure-skip-tls-verify: true}
        contexts:
        - {name: certs, context: {cluster: local, user: certs, namespace: web}}
        - {name: token, context: {cluster: open, user: token}}
        - {name: token-file, context: {cluster: files, user: token-file}}
        - {name: basic, context: {cluster: open, user: basic}}
        - {name: exec, context: {cluster: open, user: exec}}
        - {name: oidc, context: {cluster: open, user: oidc}}
        - {name: no-user, context: {cluster: open}}
        - {name: broken, context: {cluster: missing}}
        users:
        - name: certs
          user:
            client-certificate-data: \(Data("CERT".utf8).base64EncodedString())
            client-key-data: \(Data("KEY".utf8).base64EncodedString())
        - name: token
          user: {token: abc}
        - name: token-file
          user: {tokenFile: secrets/token, client-certificate: /abs/cert.pem, client-key: key.pem}
        - name: basic
          user: {username: admin, password: pw}
        - name: exec
          user:
            exec:
              apiVersion: client.authentication.k8s.io/v1beta1
              command: aws
              args: [eks, get-token]
              env: [{name: AWS_PROFILE, value: dev}]
              provideClusterInfo: true
        - name: oidc
          user:
            auth-provider:
              name: oidc
              config: {id-token: idt, refresh-token: r}
        """
    }

    private func file() throws -> KubeConfigFile { try KubeConfigFile(yaml: config, directory: "/k") }

    private func files(_ path: String) throws -> Data {
        switch path {
        case "/k/ca.crt": Data("FILE-CA".utf8)
        case "/abs/cert.pem": Data("FILE-CERT".utf8)
        case "/k/key.pem": Data("FILE-KEY".utf8)
        default: throw CocoaError(.fileNoSuchFile)
        }
    }

    @Test func inlineCertificates() throws {
        let connection = try file().connection(for: "certs", readFile: files)
        #expect(connection.server.absoluteString == "https://127.0.0.1:6445")
        #expect(connection.namespace == "web")
        #expect(connection.certificateAuthorityPEM == Data("CA-PEM".utf8))
        #expect(connection.auth.clientCertificatePEM == Data("CERT".utf8))
        #expect(connection.auth.clientKeyPEM == Data("KEY".utf8))
        #expect(!connection.insecureSkipTLSVerify)
    }

    @Test func filesResolveAgainstTheKubeconfigDirectory() throws {
        let connection = try file().connection(for: "token-file", readFile: files)
        #expect(connection.certificateAuthorityPEM == Data("FILE-CA".utf8))
        #expect(connection.auth.clientCertificatePEM == Data("FILE-CERT".utf8))
        #expect(connection.auth.clientKeyPEM == Data("FILE-KEY".utf8))
        #expect(connection.auth.tokenFile == "/k/secrets/token")
        #expect(connection.tlsServerName == "kubernetes")
        #expect(connection.proxyURL?.absoluteString == "socks5://127.0.0.1:1080")
    }

    @Test func tokenBasicExecAndAuthProvider() throws {
        let config = try file()
        let token = try config.connection(for: "token", readFile: files)
        #expect(token.auth.token == "abc")
        #expect(token.insecureSkipTLSVerify)

        let basic = try config.connection(for: "basic", readFile: files).auth
        #expect(basic.username == "admin")
        #expect(basic.password == "pw")

        let exec = try #require(try config.connection(for: "exec", readFile: files).auth.exec)
        #expect(exec.command == "aws")
        #expect(exec.args == ["eks", "get-token"])
        #expect(exec.env == ["AWS_PROFILE": "dev"])
        #expect(exec.apiVersion == "client.authentication.k8s.io/v1beta1")
        #expect(exec.provideClusterInfo)
        #expect(exec.baseDirectory == "/k")

        let oidc = try config.connection(for: "oidc", readFile: files).auth
        #expect(oidc.authProvider == "oidc")
        #expect(oidc.token == "idt")

        #expect(try config.connection(for: "no-user", readFile: files).auth == KubeAuth())
    }

    @Test func authDescriptionHidesSecrets() throws {
        let auth = try file().connection(for: "basic", readFile: files).auth
        #expect(auth.description == "KubeAuth(basic)")
        #expect(!String(describing: auth).contains("pw"))
    }

    @Test func errors() throws {
        let config = try file()
        #expect(throws: KubeConfigError.unknownContext("gone")) { try config.connection(for: "gone", readFile: files) }
        #expect(throws: KubeConfigError.missingCluster("broken")) { try config.connection(for: "broken", readFile: files) }
        let missingFile = "apiVersion: v1\nclusters: [{name: c, cluster: {server: 'https://a', certificate-authority: /nope}}]\ncontexts: [{name: x, context: {cluster: c}}]"
        #expect(throws: KubeConfigError.unreadableFile("/nope")) {
            try KubeConfigFile(yaml: missingFile, directory: "/").connection(for: "x", readFile: files)
        }
        let badServer = "clusters: [{name: c, cluster: {server: 'ftp://a'}}]\ncontexts: [{name: x, context: {cluster: c}}]"
        #expect(throws: KubeConfigError.invalidServer("ftp://a")) {
            try KubeConfigFile(yaml: badServer, directory: "/").connection(for: "x", readFile: files)
        }
    }

    @Test func mergeKeepsTheFirstDefinition() throws {
        let first = "current-context: a\ncontexts: [{name: a, context: {cluster: one}}]\nclusters: [{name: one, cluster: {server: 'https://1'}}]"
        let second = "current-context: b\ncontexts: [{name: a, context: {cluster: two}}, {name: b, context: {cluster: two}}]\nclusters: [{name: two, cluster: {server: 'https://2'}}]"
        let texts = ["/1": first, "/2": second]
        let merged = try KubeConfigFile.load(paths: ["/1", "/2"]) { path in
            guard let text = texts[path] else { throw CocoaError(.fileNoSuchFile) }
            return text
        }
        #expect(merged.currentContext == "a")
        let contexts = merged.contextList()
        #expect(contexts.map(\.name) == ["a", "b"])
        #expect(contexts[0].server == "https://1")
        #expect(contexts[0].isCurrent)
        #expect(throws: KubeConfigError.unreadable("/3")) { try KubeConfigFile.load(paths: ["/3"]) { _ in throw CocoaError(.fileNoSuchFile) } }
    }
}

struct KubeExecCredentialTests {
    @Test func parsesTokenAndCertificate() throws {
        let token = try KubeExecCredential.parse(json("""
        {"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential",
         "status":{"token":"t0k","expirationTimestamp":"2030-01-02T03:04:05Z"}}
        """))
        #expect(token.token == "t0k")
        #expect(token.expiration == ISO8601DateFormatter().date(from: "2030-01-02T03:04:05Z"))
        #expect(token.isValid(at: ISO8601DateFormatter().date(from: "2030-01-02T03:00:00Z")!))
        #expect(!token.isValid(at: ISO8601DateFormatter().date(from: "2030-01-02T03:04:00Z")!))
        #expect(!token.description.contains("t0k"))

        let certificate = try KubeExecCredential.parse(json("""
        {"kind":"ExecCredential","status":{"clientCertificateData":"C","clientKeyData":"K"}}
        """))
        #expect(certificate.clientCertificatePEM == Data("C".utf8))
        #expect(certificate.clientKeyPEM == Data("K".utf8))
        #expect(certificate.isValid())
    }

    @Test func rejectsBadOutput() {
        #expect(throws: KubeAPIError.self) { try KubeExecCredential.parse(json("not json")) }
        #expect(throws: KubeAPIError.self) { try KubeExecCredential.parse(json(#"{"kind":"Other","status":{"token":"x"}}"#)) }
        #expect(throws: KubeAPIError.self) { try KubeExecCredential.parse(json(#"{"kind":"ExecCredential","status":{}}"#)) }
    }

    @Test func execInfoAndCommandLookup() throws {
        let config = KubeExecConfig(command: "gke-auth", apiVersion: "client.authentication.k8s.io/v1", provideClusterInfo: true, baseDirectory: "/k")
        let connection = KubeConnection(context: "c", server: URL(string: "https://1.2.3.4")!, certificateAuthorityPEM: Data("CA".utf8))
        let info = try #require(try JSONSerialization.jsonObject(with: Data(KubeExecCredential.execInfo(config, connection: connection).utf8)) as? [String: Any])
        #expect(info["kind"] as? String == "ExecCredential")
        let cluster = (info["spec"] as? [String: Any])?["cluster"] as? [String: Any]
        #expect(cluster?["server"] as? String == "https://1.2.3.4")
        #expect(cluster?["certificate-authority-data"] as? String == Data("CA".utf8).base64EncodedString())

        let found = KubeExecCredential.resolveCommand(config, environment: ["PATH": "/x"]) { $0 == "/opt/homebrew/bin/gke-auth" }
        #expect(found == "/opt/homebrew/bin/gke-auth")
        let relative = KubeExecConfig(command: "./bin/auth", baseDirectory: "/k")
        #expect(KubeExecCredential.resolveCommand(relative, environment: [:]) { $0 == "/k/bin/auth" } == "/k/bin/auth")
        #expect(KubeExecCredential.resolveCommand(config, environment: [:]) { _ in false } == nil)
    }

    @Test func runsAPluginScript() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kube-exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("plugin").path
        let body = """
        #!/bin/sh
        case "$KUBERNETES_EXEC_INFO" in *ExecCredential*) ;; *) exit 9 ;; esac
        printf '{"kind":"ExecCredential","status":{"token":"%s-%s"}}' "$1" "$PLUGIN_ENV"
        """
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let config = KubeExecConfig(command: script, args: ["arg"], env: ["PLUGIN_ENV": "env"])
        let connection = KubeConnection(context: "c", server: URL(string: "https://a")!)
        #expect(try await KubeExecCredential.run(config, connection: connection).token == "arg-env")

        try "#!/bin/sh\necho 'login first' >&2\nexit 1\n".write(toFile: script, atomically: true, encoding: .utf8)
        await #expect(throws: KubeAPIError.credentials("login first")) {
            try await KubeExecCredential.run(config, connection: connection)
        }
    }
}

struct KubeRequestTests {
    private let server = URL(string: "https://127.0.0.1:6445")!
    private let pod = KubeResource(kind: .pods, name: "web-1", namespace: "default", containers: ["app"])
    private let deployment = KubeResource(kind: .deployments, name: "api", namespace: "web")

    private func url(_ request: KubeRequest, server: URL? = nil) -> String {
        request.url(server: server ?? self.server)?.absoluteString ?? ""
    }

    @Test func listPaths() {
        #expect(url(KubeRequests.list(.pods, namespace: nil)) == "https://127.0.0.1:6445/api/v1/pods")
        #expect(url(KubeRequests.list(.pods, namespace: "web")) == "https://127.0.0.1:6445/api/v1/namespaces/web/pods")
        #expect(url(KubeRequests.list(.nodes, namespace: "web")) == "https://127.0.0.1:6445/api/v1/nodes")
        #expect(url(KubeRequests.list(.deployments, namespace: "web")) == "https://127.0.0.1:6445/apis/apps/v1/namespaces/web/deployments")
        #expect(url(KubeRequests.list(.ingresses, namespace: nil)).hasSuffix("/apis/networking.k8s.io/v1/ingresses"))
        #expect(url(KubeRequests.list(.pods, namespace: "web", labelSelector: "app=a,tier=b"))
            .hasSuffix("/namespaces/web/pods?labelSelector=app%3Da%2Ctier%3Db"))
        #expect(url(KubeRequests.namespaces, server: URL(string: "https://h/proxy/")!) == "https://h/proxy/api/v1/namespaces")
    }

    @Test func watchQuery() {
        let request = KubeRequests.watch(.pods, namespace: "web", resourceVersion: "42")
        #expect(request.streaming)
        #expect(url(request).hasSuffix("/pods?watch=true&resourceVersion=42&allowWatchBookmarks=true&timeoutSeconds=240"))
    }

    @Test func actions() throws {
        let delete = KubeRequests.delete(deployment)
        #expect(delete.method == .delete)
        #expect(url(delete) == "https://127.0.0.1:6445/apis/apps/v1/namespaces/web/deployments/api?propagationPolicy=Background")

        let scale = KubeRequests.scale(deployment, replicas: -2)
        #expect(scale.method == .patch)
        #expect(scale.contentType == "application/merge-patch+json")
        #expect(url(scale).hasSuffix("/deployments/api/scale"))
        #expect(scale.body == Data(#"{"spec":{"replicas":0}}"#.utf8))

        let restart = KubeRequests.restart(deployment, at: Date(timeIntervalSince1970: 0))
        #expect(restart.contentType == "application/strategic-merge-patch+json")
        let body = String(decoding: try #require(restart.body), as: UTF8.self)
        #expect(body == #"{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io\/restartedAt":"1970-01-01T00:00:00Z"}}}}}"#)
    }

    @Test func streams() {
        let logs = KubeRequests.logs(pod: pod, container: "app", follow: true, tail: 200, previous: true)
        #expect(logs.streaming)
        #expect(url(logs).hasSuffix("/api/v1/namespaces/default/pods/web-1/log?container=app&follow=true&previous=true&tailLines=200"))
        #expect(!KubeRequests.logs(pod: pod, container: nil, follow: false, tail: 5).streaming)

        let exec = KubeRequests.exec(pod: pod, container: "app", command: ["sh", "-c", "a; b && c +1"])
        #expect(url(exec).hasSuffix("/pods/web-1/exec?command=sh&command=-c&command=a%3B%20b%20%26%26%20c%20%2B1&container=app&stdin=true&stdout=true&stderr=false&tty=true"))
        let batch = KubeRequests.exec(pod: pod, container: nil, command: ["ls"], stdin: false, tty: false)
        #expect(url(batch).hasSuffix("exec?command=ls&stdin=false&stdout=true&stderr=true&tty=false"))

        #expect(url(KubeRequests.portForward(pod: pod, port: 8080)).hasSuffix("/pods/web-1/portforward?ports=8080"))
    }

    @Test func apply() {
        let request = KubeRequests.apply(path: "/api/v1/namespaces/a/configmaps/c", yaml: "kind: ConfigMap\n")
        #expect(request.method == .patch)
        #expect(request.contentType == "application/apply-patch+yaml")
        #expect(url(request).hasSuffix("/configmaps/c?fieldManager=gantry&force=false"))
        #expect(KubeRequests.discovery(apiVersion: "v1").path == "/api/v1")
        #expect(KubeRequests.discovery(apiVersion: "example.com/v2").path == "/apis/example.com/v2")
    }

    @Test func errorStatus() {
        let status = KubeAPIError.from(statusCode: 404, body: json(#"{"kind":"Status","reason":"NotFound","message":"pods \"a\" not found"}"#))
        #expect(status == .status(code: 404, reason: "NotFound", message: "pods \"a\" not found"))
        #expect(status.statusCode == 404)
        #expect(KubeAPIError.from(statusCode: 502, body: Data("bad gateway".utf8)).errorDescription == "HTTP 502: bad gateway")
    }

    @Test func headers() {
        var auth = KubeRequestAuth()
        auth.authorization = "Bearer x"
        let headers = KubeAPIClient.headers(for: KubeRequests.scale(deployment, replicas: 1), auth: auth)
        #expect(headers.first(name: "Authorization") == "Bearer x")
        #expect(headers.first(name: "Content-Type") == "application/merge-patch+json")
        #expect(headers.first(name: "Accept") == "application/json")
    }

    @Test func requestAuthKinds() async throws {
        let server = URL(string: "https://a")!
        var auth = KubeAuth()
        auth.username = "u"
        auth.password = "p"
        let basic = try await KubeAPIClient(connection: KubeConnection(context: "c", server: server, auth: auth)).requestAuth()
        #expect(basic.authorization == "Basic " + Data("u:p".utf8).base64EncodedString())

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("token-\(UUID().uuidString)")
        try "file-token\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        auth = KubeAuth()
        auth.token = "inline"
        auth.tokenFile = file.path
        let token = try await KubeAPIClient(connection: KubeConnection(context: "c", server: server, auth: auth)).requestAuth()
        #expect(token.authorization == "Bearer file-token")
    }

    @Test func lineBuffer() {
        var buffer = KubeLineBuffer()
        #expect(buffer.feed(Data("one\ntw".utf8)) == ["one"])
        #expect(buffer.feed(Data("o\r\nthree".utf8)) == ["two"])
        #expect(buffer.flush() == "three")
        #expect(buffer.flush() == nil)
    }
}

struct KubeTLSTests {
    /// Makes a key and a self-signed certificate with the system openssl.
    private func makePEM(_ keyArguments: [String]) throws -> (cert: Data, key: Data)? {
        let openssl = "/usr/bin/openssl"
        guard FileManager.default.isExecutableFile(atPath: openssl) else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kube-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("key.pem").path
        let cert = directory.appendingPathComponent("cert.pem").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: openssl)
        process.arguments = ["req", "-x509", "-nodes", "-subj", "/CN=gantry-test", "-days", "1"] + keyArguments + ["-keyout", key, "-out", cert]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return (try Data(contentsOf: URL(fileURLWithPath: cert)), try Data(contentsOf: URL(fileURLWithPath: key)))
    }

    @Test(arguments: [["-newkey", "rsa:2048"], ["-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1"]])
    func loadsRSAAndECKeys(_ keyArguments: [String]) throws {
        guard let pem = try makePEM(keyArguments) else { return }
        let connection = KubeConnection(context: "c", server: URL(string: "https://a")!, certificateAuthorityPEM: pem.cert)
        let tls = try KubeTLS.configuration(connection, certificatePEM: pem.cert, keyPEM: pem.key)
        #expect(tls.certificateChain.count == 1)
        #expect(tls.privateKey != nil)
        #expect(tls.certificateVerification == .fullVerification)
    }

    @Test func insecureAndInvalid() throws {
        var connection = KubeConnection(context: "c", server: URL(string: "https://a")!, insecureSkipTLSVerify: true)
        #expect(try KubeTLS.configuration(connection, certificatePEM: nil, keyPEM: nil).certificateVerification == .none)
        connection.insecureSkipTLSVerify = false
        connection.certificateAuthorityPEM = Data("not a certificate".utf8)
        #expect(throws: KubeAPIError.self) { try KubeTLS.configuration(connection, certificatePEM: nil, keyPEM: nil) }
        connection.certificateAuthorityPEM = nil
        #expect(throws: KubeAPIError.self) {
            try KubeTLS.configuration(connection, certificatePEM: Data("x".utf8), keyPEM: Data("y".utf8))
        }
    }
}

struct KubeChannelFrameTests {
    @Test func execFrames() {
        #expect(KubeChannelFrames.encode(channel: 0, Data("ls\n".utf8)) == Data([0, 0x6C, 0x73, 0x0A]))
        let decoded = KubeChannelFrames.decode(Data([1, 0x6F, 0x6B]))
        #expect(decoded?.channel == 1)
        #expect(decoded?.payload == Data("ok".utf8))
        #expect(KubeChannelFrames.decode(Data()) == nil)
        #expect(KubeChannelFrames.resizeMessage(cols: 120, rows: 0) == Data([4]) + Data(#"{"Width":120,"Height":1}"#.utf8))
        #expect(KubeChannelFrames.closeStdinMessage == Data([255, 0]))
    }

    @Test func execResult() {
        #expect(KubeChannelFrames.execResult(json(#"{"metadata":{},"status":"Success"}"#)) == (0, nil))
        let nonZero = json("""
        {"status":"Failure","message":"command terminated with non-zero exit code: error executing command [sh -c exit 3], exit code 3",
         "reason":"NonZeroExitCode","details":{"causes":[{"reason":"ExitCode","message":"3"}]}}
        """)
        #expect(KubeChannelFrames.execResult(nonZero) == (3, nil))
        let failure = KubeChannelFrames.execResult(json(#"{"status":"Failure","message":"container not found"}"#))
        #expect(failure.exitCode == nil)
        #expect(failure.message == "container not found")
        #expect(KubeChannelFrames.execResult(Data("plain text".utf8)).message == "plain text")
    }

    @Test func portForwardDemux() {
        var demux = KubePortForwardDemux(port: 8080)
        // 8080 = 0x1F90, little-endian.
        #expect(demux.feed(Data([0, 0x90, 0x1F])) == [])
        #expect(demux.feed(Data([1, 0x90, 0x1F])) == [])
        #expect(demux.feed(Data([0, 0x90, 0x1F])) == [.data(Data([0x90, 0x1F]))])
        #expect(demux.feed(Data([0]) + Data("hi".utf8)) == [.data(Data("hi".utf8))])
        #expect(demux.feed(Data([1]) + Data("refused".utf8)) == [.error("refused")])
        #expect(demux.feed(Data()) == [])

        var noPrefix = KubePortForwardDemux(port: 80)
        #expect(noPrefix.feed(Data([0]) + Data("pong".utf8)) == [.data(Data("pong".utf8))])
        #expect(KubePortForwardDemux.dataMessage(Data("x".utf8)) == Data([0, 0x78]))
    }
}

struct KubeApplyPlannerTests {
    private let manifest = """
    apiVersion: v1
    kind: Namespace
    metadata: {name: shop}
    ---
    # a comment only
    ---
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: web
      namespace: shop
    spec:
      replicas: 2
      template:
        metadata:
          annotations: {version: "1.10", enabled: "true"}
    ---
    apiVersion: v1
    kind: List
    items:
    - {apiVersion: v1, kind: ConfigMap, metadata: {name: cfg}, data: {port: "8080"}}
    - {apiVersion: example.com/v1, kind: Widget, metadata: {name: w}}
    """

    @Test func splitsDocumentsAndLists() throws {
        let objects = try KubeApplyPlanner.objects(from: manifest)
        #expect(objects.map(\.reference) == ["namespace/shop", "deployment.apps/web", "configmap/cfg", "widget.example.com/w"])
        #expect(objects[1].namespace == "shop")
        #expect(objects[2].namespace == nil)
        // The body keeps quoted strings as strings.
        #expect(objects[1].yaml.contains("\"1.10\"") || objects[1].yaml.contains("'1.10'"))
        #expect(objects[2].yaml.contains("\"8080\"") || objects[2].yaml.contains("'8080'"))
    }

    @Test func pathsAndKinds() throws {
        let objects = try KubeApplyPlanner.objects(from: manifest)
        let namespace = try #require(KubeApplyPlanner.knownResource(apiVersion: "v1", kind: "Namespace"))
        #expect(KubeApplyPlanner.path(objects[0], resource: namespace, defaultNamespace: "x") == "/api/v1/namespaces/shop")
        let deployment = try #require(KubeApplyPlanner.knownResource(apiVersion: "apps/v1", kind: "Deployment"))
        #expect(KubeApplyPlanner.path(objects[1], resource: deployment, defaultNamespace: "x") == "/apis/apps/v1/namespaces/shop/deployments/web")
        let configMap = try #require(KubeApplyPlanner.knownResource(apiVersion: "v1", kind: "ConfigMap"))
        #expect(KubeApplyPlanner.path(objects[2], resource: configMap, defaultNamespace: "dev") == "/api/v1/namespaces/dev/configmaps/cfg")
        #expect(KubeApplyPlanner.knownResource(apiVersion: "example.com/v1", kind: "Widget") == nil)
    }

    @Test func discovery() {
        let list = json("""
        {"kind":"APIResourceList","groupVersion":"example.com/v1","resources":[
          {"name":"widgets/status","kind":"Widget","namespaced":true},
          {"name":"widgets","kind":"Widget","namespaced":true},
          {"name":"gadgets","kind":"Gadget","namespaced":false}]}
        """)
        #expect(KubeApplyPlanner.resource(kind: "Widget", inDiscovery: list) == KubeAPIResource("widgets", namespaced: true))
        #expect(KubeApplyPlanner.resource(kind: "Gadget", inDiscovery: list) == KubeAPIResource("gadgets", namespaced: false))
        #expect(KubeApplyPlanner.resource(kind: "Nope", inDiscovery: list) == nil)
    }

    @Test func problemsAndErrors() throws {
        let objects = try KubeApplyPlanner.objects(from: "kind: ConfigMap\nmetadata: {name: a}\n---\napiVersion: v1\nkind: ConfigMap\n")
        #expect(KubeApplyPlanner.problem(objects[0]) != nil)
        #expect(KubeApplyPlanner.problem(objects[1]) != nil)
        #expect(throws: KubeApplyError.empty) { try KubeApplyPlanner.objects(from: "---\n# nothing\n") }
        #expect(throws: KubeApplyError.self) { try KubeApplyPlanner.objects(from: "a: [b\n") }
        #expect(throws: KubeApplyError.self) { try KubeApplyPlanner.objects(from: "- just\n- a list\n") }
    }
}

struct KubeYAMLTests {
    @Test func ordersKeysAndDropsManagedFields() throws {
        let data = json("""
        {"status":{"phase":"Running"},"spec":{"b":1,"a":true},"kind":"Pod","apiVersion":"v1",
         "metadata":{"name":"p","managedFields":[{"manager":"kubectl"}],"labels":{"version":"1.10","on":"yes"}},
         "data":{"text":"line1\\nline2"}}
        """)
        let yaml = try KubeYAML.render(json: data, redactSecret: false)
        #expect(yaml.hasPrefix("apiVersion: v1\nkind: Pod\nmetadata:\n"))
        #expect(!yaml.contains("managedFields"))
        #expect(yaml.contains("version: \"1.10\""))
        #expect(yaml.contains("on: \"yes\""))
        #expect(yaml.contains("a: true\n"))
        #expect(yaml.contains("|-\n") || yaml.contains("|\n"))
        #expect(yaml.hasSuffix("status:\n  phase: Running\n"))
        let index = { (text: String) in yaml.range(of: text)!.lowerBound }
        #expect(index("spec:") < index("data:") || index("data:") < index("status:"))
    }

    @Test func secretValuesStayHidden() throws {
        let data = json(#"{"apiVersion":"v1","kind":"Secret","metadata":{"name":"s"},"data":{"password":"c2VjcmV0"}}"#)
        let yaml = try KubeYAML.render(json: data, redactSecret: true)
        #expect(!yaml.contains("c2VjcmV0"))
        #expect(yaml.contains(KubeSecretData.mask))
    }
}

struct KubeRolloutStatusTests {
    private func deployment(generation: Int = 2, observed: Int = 2, replicas: Int = 3, updated: Int = 3, total: Int = 3, available: Int = 3, reason: String? = nil) -> Data {
        let condition = reason.map { #","conditions":[{"type":"Progressing","reason":"\#($0)"}]"# } ?? ""
        return json("""
        {"metadata":{"name":"web","generation":\(generation)},"spec":{"replicas":\(replicas)},
         "status":{"observedGeneration":\(observed),"updatedReplicas":\(updated),"replicas":\(total),"availableReplicas":\(available)\(condition)}}
        """)
    }

    @Test func deploymentStates() throws {
        #expect(try KubeRolloutStatus.evaluate(deployment(), kind: .deployments).done)
        #expect(try !KubeRolloutStatus.evaluate(deployment(observed: 1), kind: .deployments).done)
        #expect(try !KubeRolloutStatus.evaluate(deployment(updated: 1), kind: .deployments).done)
        #expect(try !KubeRolloutStatus.evaluate(deployment(total: 4), kind: .deployments).done)
        #expect(try !KubeRolloutStatus.evaluate(deployment(available: 2), kind: .deployments).done)
        #expect(try KubeRolloutStatus.evaluate(deployment(replicas: 0, updated: 0, total: 0, available: 0), kind: .deployments).done)
        #expect(throws: KubeAPIError.self) { try KubeRolloutStatus.evaluate(deployment(reason: "ProgressDeadlineExceeded"), kind: .deployments) }
    }

    @Test func statefulSetAndDaemonSet() throws {
        let rolling = json(#"{"metadata":{"name":"db","generation":1},"spec":{"replicas":2},"status":{"observedGeneration":1,"readyReplicas":2,"updateRevision":"b","currentRevision":"a","updatedReplicas":1}}"#)
        #expect(try !KubeRolloutStatus.evaluate(rolling, kind: .statefulSets).done)
        let done = json(#"{"metadata":{"name":"db","generation":1},"spec":{"replicas":2},"status":{"observedGeneration":1,"readyReplicas":2,"updateRevision":"b","currentRevision":"b"}}"#)
        #expect(try KubeRolloutStatus.evaluate(done, kind: .statefulSets).done)
        let onDelete = json(#"{"metadata":{"name":"db"},"spec":{"updateStrategy":{"type":"OnDelete"}},"status":{}}"#)
        #expect(try KubeRolloutStatus.evaluate(onDelete, kind: .statefulSets).done)

        let daemon = json(#"{"metadata":{"name":"agent","generation":3},"status":{"observedGeneration":3,"desiredNumberScheduled":2,"updatedNumberScheduled":2,"numberAvailable":1}}"#)
        #expect(try !KubeRolloutStatus.evaluate(daemon, kind: .daemonSets).done)
    }
}

struct KubeServiceTargetTests {
    private let service = json("""
    {"metadata":{"name":"web","namespace":"shop"},
     "spec":{"selector":{"tier":"front","app":"web"},"ports":[{"port":80,"targetPort":"http"},{"port":443,"targetPort":8443},{"port":9000}]}}
    """)
    private let pods = json("""
    {"items":[
     {"metadata":{"name":"web-old","deletionTimestamp":"2024-01-01T00:00:00Z"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}},
     {"metadata":{"name":"web-starting"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"False"}]}},
     {"metadata":{"name":"web-1"},"spec":{"containers":[{"ports":[{"name":"http","containerPort":8080}]}]},
      "status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}
    """)

    @Test func picksAReadyPodAndMapsPorts() throws {
        #expect(try KubeServiceTarget.selector(service: service) == "app=web,tier=front")
        let pod = KubeResource(kind: .pods, name: "web-1", namespace: "shop")
        #expect(try KubeServiceTarget.resolve(service: service, pods: pods, port: 80) == KubePortForwardTarget(pod: pod, port: 8080))
        #expect(try KubeServiceTarget.resolve(service: service, pods: pods, port: 443).port == 8443)
        #expect(try KubeServiceTarget.resolve(service: service, pods: pods, port: 9000).port == 9000)
    }

    @Test func errors() throws {
        #expect(throws: KubeAPIError.self) { try KubeServiceTarget.resolve(service: service, pods: json(#"{"items":[]}"#), port: 80) }
        let unnamed = json(#"{"items":[{"metadata":{"name":"p"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}"#)
        #expect(throws: KubeAPIError.self) { try KubeServiceTarget.resolve(service: service, pods: unnamed, port: 80) }
        #expect(try KubeServiceTarget.selector(service: json(#"{"spec":{}}"#)) == nil)
    }
}

struct KubeWatchEventTests {
    @Test func parsesEvents() {
        let added = KubeWatchEvent.parse(#"{"type":"ADDED","object":{"metadata":{"name":"p","namespace":"web","uid":"1","resourceVersion":"7"},"status":{"phase":"Running"}}}"#, kind: .pods)
        guard case .changed(let change, let resource, let version) = added else { Issue.record("not a change"); return }
        #expect(change == .added)
        #expect(resource.name == "p")
        #expect(version == "7")
        #expect(KubeWatchEvent.parse(#"{"type":"BOOKMARK","object":{"metadata":{"resourceVersion":"9"}}}"#, kind: .pods) == .bookmark("9"))
        #expect(KubeWatchEvent.parse(#"{"type":"ERROR","object":{"kind":"Status","code":410}}"#, kind: .pods) == .expired)
        #expect(KubeWatchEvent.parse("garbage", kind: .pods) == .ignored)
        #expect(KubeWatchEvent.listResourceVersion(json(#"{"metadata":{"resourceVersion":"123"},"items":[]}"#)) == "123")
        #expect(KubeWatchEvent.listResourceVersion(json(#"{"items":[]}"#)) == nil)
    }

    @Test func sortsLikeTheAPI() {
        let list = [
            KubeResource(kind: .pods, name: "b", namespace: "x"),
            KubeResource(kind: .pods, name: "a", namespace: "y"),
            KubeResource(kind: .pods, name: "a", namespace: "x"),
        ]
        #expect(KubeWatchEvent.sorted(list, kind: .pods).map { "\($0.namespace!)/\($0.name)" } == ["x/a", "x/b", "y/a"])
    }
}

@MainActor
struct KubernetesBrowserTests {
    private func kubeconfig(_ text: String) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("kubeconfig-\(UUID().uuidString)").path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func loadsContextsWithoutKubectl() async throws {
        let path = try kubeconfig("""
        current-context: dev
        clusters: [{name: dev, cluster: {server: "https://127.0.0.1:1"}}]
        contexts:
        - {name: dev, context: {cluster: dev, user: dev, namespace: web}}
        - {name: broken, context: {cluster: gone}}
        users: [{name: dev, user: {token: t}}]
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let defaults = UserDefaults(suiteName: "kube-\(UUID().uuidString)")!
        let browser = KubernetesBrowser(defaults: defaults, kubeconfigPaths: { [path] })
        await browser.prepare()
        #expect(browser.isPrepared)
        #expect(browser.contexts.map(\.name) == ["dev", "broken"])
        #expect(browser.selectedContext == "dev")
        #expect(browser.namespace == "web")
        #expect(browser.targetNamespace == "web")
        #expect(browser.client?.connection.server.absoluteString == "https://127.0.0.1:1")

        browser.selectedContext = "broken"
        #expect(browser.client == nil)
        #expect(browser.loadError != nil)
    }

    @Test func unreachableServerShowsAnError() async throws {
        let path = try kubeconfig("""
        clusters: [{name: c, cluster: {server: "https://127.0.0.1:1"}}]
        contexts: [{name: c, context: {cluster: c}}]
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let browser = KubernetesBrowser(defaults: UserDefaults(suiteName: "kube-\(UUID().uuidString)")!, kubeconfigPaths: { [path] })
        await browser.prepare()
        #expect(await browser.reload() == nil)
        #expect(browser.loadError != nil)
    }

    @Test func badFileShowsAnError() async throws {
        let path = try kubeconfig("clusters: [unclosed")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let browser = KubernetesBrowser(defaults: UserDefaults(suiteName: "kube-\(UUID().uuidString)")!, kubeconfigPaths: { [path] })
        await browser.prepare()
        #expect(browser.contexts.isEmpty)
        #expect(browser.loadError != nil)
    }
}
