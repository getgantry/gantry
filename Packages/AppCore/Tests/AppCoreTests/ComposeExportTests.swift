import Foundation
import Testing
import Yams
@testable import DockerKit
@testable import AppCore

// MARK: - Helpers

private func data(_ text: String) -> Data { Data(text.utf8) }

private func dockerSource(remote: Bool = false, image: Bool = true) -> ComposeExportSource {
    ComposeExportSource(
        containerInspect: data(ComposeExportFixtures.dockerContainer),
        imageInspect: image ? data(ComposeExportFixtures.dockerImage) : nil,
        isRemoteHost: remote
    )
}

/// The Apple source the way the transport builds it: the Docker-shaped
/// translation with the CLI object under `AppleContainer`.
private func appleSource(image: Bool = true, edit: (inout [String: Any]) -> Void = { _ in }) throws -> ComposeExportSource {
    var element = try #require((try JSONSerialization.jsonObject(with: data(ComposeExportFixtures.appleContainer)) as? [[String: Any]])?.first)
    edit(&element)
    let body = try AppleContainerJSON.containerInspectBody(fromAppleInspect: element)
    let imageBody = try AppleContainerJSON.imageInspectBody(fromAppleInspect: data(ComposeExportFixtures.appleImage))
    return ComposeExportSource(containerInspect: body, imageInspect: image ? imageBody : nil, isAppleContainer: true)
}

private func yamlRoot(_ result: ComposeExportResult) throws -> [String: Any] {
    try #require(try Yams.load(yaml: result.yaml) as? [String: Any])
}

private func service(_ result: ComposeExportResult, _ name: String) throws -> [String: Any] {
    let services = try #require(try yamlRoot(result)["services"] as? [String: Any])
    return try #require(services[name] as? [String: Any])
}

private func parse(_ result: ComposeExportResult, environment: [String: String] = [:]) throws -> ComposeProject {
    try ComposeParser().parse(
        text: result.yaml,
        fileURL: URL(fileURLWithPath: "/tmp/export/docker-compose.yml"),
        directory: URL(fileURLWithPath: "/tmp/export"),
        environment: environment
    )
}

// MARK: - Docker

@Test func composeExportMapsDockerContainer() throws {
    let result = try ComposeExporter.export([dockerSource()])
    let web = try service(result, "web")
    #expect(web["image"] as? String == "nginx:1.27")
    #expect(web["container_name"] as? String == "web")
    // Equal to the image defaults: no entrypoint, command, stop signal or PATH.
    #expect(web["entrypoint"] == nil)
    #expect(web["command"] == nil)
    #expect(web["stop_signal"] == nil)
    #expect(web["hostname"] == nil)
    #expect(web["ports"] as? [String] == ["5353:53/udp", "8080:80", "127.0.0.1:8443:443"])
    #expect(web["volumes"] as? [String] == ["/srv/site:/usr/share/nginx/html:ro", "/var/cache/nginx", "web-data:/var/lib/web"])
    #expect(web["tmpfs"] as? [String] == ["/run:rw,size=64m"])
    #expect(web["restart"] as? String == "on-failure:3")
    #expect(web["cap_add"] as? [String] == ["NET_ADMIN"])
    #expect(web["extra_hosts"] as? [String] == ["host.docker.internal:host-gateway"])
    #expect(web["ipc"] == nil)
    #expect(web["runtime"] == nil)
    #expect(web["shm_size"] == nil)
    let labels = try #require(web["labels"] as? [String: String])
    #expect(labels == ["app": "web", "on": "80"])
    let networks = try #require(web["networks"] as? [String: Any])
    let backend = try #require(networks["backend"] as? [String: Any])
    #expect(backend["aliases"] as? [String] == ["frontend"])
    #expect(backend["ipv4_address"] as? String == "172.20.0.10")
    let limits = try #require(((web["deploy"] as? [String: Any])?["resources"] as? [String: Any])?["limits"] as? [String: Any])
    #expect(limits["cpus"] as? String == "1.5")
    #expect(limits["memory"] as? String == "512m")
    let ulimits = try #require(web["ulimits"] as? [String: Any])
    #expect((ulimits["nofile"] as? [String: Any])?["hard"] as? Int == 2048)

    let root = try yamlRoot(result)
    #expect(((root["networks"] as? [String: Any])?["backend"] as? [String: Any])?["external"] as? Bool == true)
    #expect(((root["volumes"] as? [String: Any])?["web-data"] as? [String: Any])?["external"] as? Bool == true)
    #expect(root["name"] == nil)
    #expect(!result.yaml.contains("version:"))
}

@Test func composeExportHealthcheckUsesComposeDurations() throws {
    let web = try service(try ComposeExporter.export([dockerSource()]), "web")
    let check = try #require(web["healthcheck"] as? [String: Any])
    #expect(check["test"] as? [String] == ["CMD-SHELL", "curl -f http://localhost/ || exit 1"])
    #expect(check["interval"] as? String == "30s")
    #expect(check["timeout"] as? String == "5s")
    #expect(check["start_period"] as? String == "1m30s")
    #expect(check["retries"] as? Int == 3)
}

@Test func composeExportQuotesAndEscapes() throws {
    let result = try ComposeExporter.export([dockerSource()])
    // `yes` stays a string, `$` is doubled, a label key `on` is quoted.
    #expect(result.yaml.contains("GREETING: \"yes\""))
    #expect(result.yaml.contains("PRICE: \"$$5\"") || result.yaml.contains("PRICE: $$5"))
    #expect(result.yaml.contains("\"on\": \"80\""))
    #expect(result.yaml.contains("- \"8080:80\""))
    let environment = try #require(try service(result, "web")["environment"] as? [String: String])
    #expect(environment["GREETING"] == "yes")
    #expect(environment["NGINX_VERSION"] == nil)
    #expect(environment["PATH"] == nil)
}

@Test func composeExportRoundTripsThroughParser() throws {
    let options = ComposeExportOptions(includedSecrets: [ComposeExportSecret(service: "web", variable: "API_TOKEN")])
    let result = try ComposeExporter.export([dockerSource()], options: options)
    let project = try parse(result)
    let web = try #require(project.services.first { $0.name == "web" })
    #expect(web.image == "nginx:1.27")
    #expect(web.ports.map { "\($0.hostIP ?? ""):\($0.hostPort ?? ""):\($0.containerPort)/\($0.proto)" }
        == [":5353:53/udp", ":8080:80/tcp", "127.0.0.1:8443:443/tcp"])
    #expect(web.volumes.contains(ComposeMount(kind: .bind(hostPath: "/srv/site"), containerPath: "/usr/share/nginx/html", readOnly: true)))
    #expect(web.volumes.contains(ComposeMount(kind: .named(volume: "web-data"), containerPath: "/var/lib/web")))
    let environment = Dictionary(uniqueKeysWithValues: web.environment.map { ($0.key, $0.value) })
    #expect(environment == ["API_TOKEN": "tok_9f8e7d6c5b4a3f2e1d0c", "GREETING": "yes", "PRICE": "$5"])
    #expect(web.restart == "on-failure:3")
    #expect(web.memoryBytes == 536_870_912)
    #expect(web.cpus == 1.5)
    #expect(project.networks["backend"]?.external == true)
    #expect(project.volumes["web-data"]?.external == true)
}

@Test func composeExportDockerWarnings() throws {
    let messages = try ComposeExporter.export([dockerSource(remote: true)]).warnings.map(\.message)
    #expect(messages.count == 3)
    #expect(messages.contains { $0.contains("--rm") })
    #expect(messages.contains { $0.contains("/var/cache/nginx") })
    #expect(messages.contains { $0.contains("remote host") })
    let all = try ComposeExporter.export([dockerSource()]).warnings
    #expect(all.allSatisfy { $0.service == "web" })
}

@Test func composeExportWithoutImageKeepsDefaults() throws {
    let result = try ComposeExporter.export([dockerSource(image: false)])
    let web = try service(result, "web")
    #expect(web["entrypoint"] as? [String] == ["/docker-entrypoint.sh"])
    #expect(web["command"] as? [String] == ["nginx", "-g", "daemon off;"])
    #expect((web["environment"] as? [String: String])?["PATH"] != nil)
    #expect(result.warnings.contains { $0.message.contains("could not inspect the image") })
}

// MARK: - Secrets

@Test func composeExportMasksSecretsByDefault() throws {
    let result = try ComposeExporter.export([dockerSource()])
    #expect(!result.yaml.contains("tok_9f8e7d6c5b4a3f2e1d0c"))
    #expect(result.yaml.contains("API_TOKEN: \"${API_TOKEN}\""))
    #expect(result.secrets == [ComposeExportSecret(service: "web", variable: "API_TOKEN")])
    #expect(!result.includesSecretValues)
    // Compose reads the masked value from the shell or `.env`.
    let project = try parse(result, environment: ["API_TOKEN": "from-env"])
    #expect(project.services.first?.environment.first { $0.key == "API_TOKEN" }?.value == "from-env")
}

@Test func composeExportIncludesChosenSecret() throws {
    let secret = ComposeExportSecret(service: "web", variable: "API_TOKEN")
    let result = try ComposeExporter.export([dockerSource()], options: ComposeExportOptions(includedSecrets: [secret]))
    #expect(result.yaml.contains("tok_9f8e7d6c5b4a3f2e1d0c"))
    #expect(result.includesSecretValues)
    #expect(result.secrets == [secret])
}

@Test func secretDetectorRules() {
    #expect(SecretDetector.isSecret(name: "DB_PASSWORD", value: "x1"))
    #expect(SecretDetector.isSecret(name: "VALUE", value: "a8F3kq92LmZx7Pw4"))
    #expect(SecretDetector.isSecret(name: "DATABASE_URL", value: "postgres://app:s3cret@db/app"))
    #expect(!SecretDetector.isSecret(name: "DATABASE_URL", value: "postgres://db/app"))
    #expect(!SecretDetector.isSecret(name: "APP_MODE", value: "prod"))
    #expect(!SecretDetector.isSecret(name: "TOKEN", value: ""))
    #expect(SecretDetector.isVariableName("API_KEY_2"))
    #expect(!SecretDetector.isVariableName("my.token"))
}

// MARK: - Several containers

@Test func composeExportSeveralComposeContainers() throws {
    let db = ComposeExportFixtures.composeContainer(id: String(repeating: "d", count: 64), service: "db")
    let api = ComposeExportFixtures.composeContainer(
        id: String(repeating: "a", count: 64), service: "api",
        dependsOn: "db:service_started:false", networkMode: "container:" + String(repeating: "d", count: 64)
    )
    let result = try ComposeExporter.export([data(db), data(api)].map { ComposeExportSource(containerInspect: $0) })
    let root = try yamlRoot(result)
    #expect(root["name"] as? String == "shop")
    #expect(result.serviceNames == ["db", "api"])
    let apiService = try service(result, "api")
    #expect(apiService["container_name"] == nil)
    #expect(apiService["network_mode"] as? String == "service:db")
    #expect(apiService["depends_on"] as? [String] == ["db"])
    #expect(apiService["labels"] as? [String: String] == ["team": "core"])
    let dbService = try service(result, "db")
    // The Compose aliases (container and service name) are left out.
    #expect(dbService["networks"] as? [String] == ["shop_default"])
    #expect(((root["networks"] as? [String: Any])?.keys).map(Array.init) == ["shop_default"])
    #expect(try parse(result).services.count == 2)
}

@Test func composeExportGivesUniqueServiceNames() throws {
    let sources = [dockerSource(), dockerSource()]
    let result = try ComposeExporter.export(sources)
    #expect(result.serviceNames == ["web", "web-2"])
    let root = try yamlRoot(result)
    #expect((root["volumes"] as? [String: Any])?.count == 1)
    #expect((root["networks"] as? [String: Any])?.count == 1)
}

@Test func composeExportServiceNameRules() {
    #expect(ComposeExporter.serviceName(from: "My.App Server") == "my-app-server")
    #expect(ComposeExporter.serviceName(from: "_x") == "x")
    #expect(ComposeExporter.serviceName(from: "ü") == "service")
}

@Test func composeExportUnknownNetworkContainerWarns() throws {
    let api = ComposeExportFixtures.composeContainer(id: String(repeating: "a", count: 64), service: "api", networkMode: "container:elsewhere")
    let result = try ComposeExporter.export([ComposeExportSource(containerInspect: data(api))])
    #expect(try service(result, "api")["network_mode"] as? String == "container:elsewhere")
    #expect(result.warnings.contains { $0.message.contains("elsewhere") })
}

@Test func composeExportRejectsBadInput() {
    #expect(throws: ComposeExportError.noContainers) { try ComposeExporter.export([]) }
    #expect(throws: ComposeExportError.invalidInspect) {
        try ComposeExporter.export([ComposeExportSource(containerInspect: Data("nope".utf8))])
    }
}

// MARK: - Apple container

@Test func composeExportMapsAppleContainer() throws {
    let result = try ComposeExporter.export([try appleSource()])
    let web = try service(result, "gce-web")
    #expect(web["image"] as? String == "docker.io/library/alpine:latest")
    #expect(web["container_name"] as? String == "gce-web")
    #expect(web["entrypoint"] as? [String] == ["/bin/sh", "-c", "sleep 3600"])
    #expect(web["command"] == nil)
    #expect(web["working_dir"] as? String == "/srv")
    #expect(web["user"] as? String == "0:0")
    #expect(web["ports"] as? [String] == ["127.0.0.1:18080:80", "18053:53/udp"])
    #expect(web["volumes"] as? [String] == ["gce-data:/data", "/Users/me/site:/srv:ro"])
    #expect(web["tmpfs"] as? [String] == ["/cache"])
    #expect(web["networks"] as? [String] == ["gce-net"])
    #expect(web["cap_add"] as? [String] == ["CAP_NET_ADMIN"])
    #expect(web["labels"] as? [String: String] == ["app": "web", "tier": "front"])
    let environment = try #require(web["environment"] as? [String: String])
    #expect(environment["APP_MODE"] == "prod")
    #expect(environment["PRICE"] == "$$5")
    #expect(environment["DB_PASSWORD"] == "${DB_PASSWORD}")
    #expect(environment["PATH"] == nil)
    let limits = try #require(((web["deploy"] as? [String: Any])?["resources"] as? [String: Any])?["limits"] as? [String: Any])
    #expect(limits["cpus"] as? String == "2")
    #expect(limits["memory"] as? String == "512m")
    #expect(!result.yaml.contains("volume.img"))
    #expect(!result.yaml.contains("hunter2secret"))
    let root = try yamlRoot(result)
    #expect(((root["volumes"] as? [String: Any])?["gce-data"] as? [String: Any])?["external"] as? Bool == true)
    #expect(((root["networks"] as? [String: Any])?["gce-net"] as? [String: Any])?["external"] as? Bool == true)
    #expect(result.warnings.map(\.message).count == 1)
    #expect(result.warnings.first?.message.contains("CPUs and memory") == true)
}

@Test func composeExportAppleRoundTrips() throws {
    let result = try ComposeExporter.export([try appleSource()])
    let project = try parse(result, environment: ["DB_PASSWORD": "p"])
    let web = try #require(project.services.first)
    #expect(web.image == "docker.io/library/alpine:latest")
    #expect(web.volumes.contains(ComposeMount(kind: .bind(hostPath: "/Users/me/site"), containerPath: "/srv", readOnly: true)))
    #expect(web.volumes.contains(ComposeMount(kind: .named(volume: "gce-data"), containerPath: "/data")))
    #expect(web.environment.first { $0.key == "PRICE" }?.value == "$5")
    #expect(web.memoryBytes == 536_870_912)
}

@Test func composeExportAppleProcessFromImageDefaults() throws {
    // The process equal to the image command: neither key.
    let plain = try ComposeExporter.export([try appleSource { element in
        setProcess(&element, executable: "/bin/sh", arguments: [])
    }])
    let web = try service(plain, "gce-web")
    #expect(web["entrypoint"] == nil)
    #expect(web["command"] == nil)
}

@Test func composeExportAppleWarnings() throws {
    let result = try ComposeExporter.export([try appleSource { element in
        var config = element["configuration"] as? [String: Any] ?? [:]
        config["rosetta"] = true
        config["ssh"] = true
        config["publishedSockets"] = [["hostPath": "/tmp/a.sock", "containerPath": "/a.sock"]]
        var labels = config["labels"] as? [String: String] ?? [:]
        labels["com.gantry.kernel"] = "/k/vmlinux"
        config["labels"] = labels
        element["configuration"] = config
    }])
    let messages = result.warnings.map(\.message)
    #expect(messages.contains { $0.contains("--rosetta") })
    #expect(messages.contains { $0.contains("--ssh") })
    #expect(messages.contains { $0.contains("--publish-socket") })
    #expect(messages.contains { $0.contains("--kernel") })
    // Gantry's own labels do not go into the file.
    #expect(!result.yaml.contains("com.gantry"))
}

@Test func composeExportImageReferencesForSession() {
    let refs = HostSession.imageReferences(inContainerInspect: data(ComposeExportFixtures.dockerContainer))
    #expect(refs == ["sha256:aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff00112233", "nginx:1.27"])
}

@Test func composeExportDurations() {
    #expect(ComposeExportFormat.duration(nanoseconds: 90_000_000_000) == "1m30s")
    #expect(ComposeExportFormat.duration(nanoseconds: 500_000_000) == "500ms")
    #expect(ComposeExportFormat.duration(nanoseconds: 3_600_000_000_000) == "1h")
    #expect(ComposeExportFormat.port(hostIP: "::1", host: "53", container: "53", proto: "udp") == "[::1]:53:53/udp")
    #expect(ComposeExportFormat.port(hostIP: "127.0.0.1", host: "", container: "80", proto: "tcp") == "127.0.0.1::80")
}

private func setProcess(_ element: inout [String: Any], executable: String, arguments: [String]) {
    var config = element["configuration"] as? [String: Any] ?? [:]
    var process = config["initProcess"] as? [String: Any] ?? [:]
    process["executable"] = executable
    process["arguments"] = arguments
    config["initProcess"] = process
    element["configuration"] = config
}

@Test func composeExportWriterSetsPermissions() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("compose-export-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("docker-compose.yml")
    let secret = ComposeExportSecret(service: "web", variable: "API_TOKEN")
    let withSecret = try ComposeExporter.export([dockerSource()], options: ComposeExportOptions(includedSecrets: [secret]))
    try ComposeExportWriter.write(withSecret, to: url)
    func mode() throws -> Int { (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0 }
    #expect(try mode() == 0o600)
    #expect(try String(contentsOf: url, encoding: .utf8) == withSecret.yaml)
    try ComposeExportWriter.write(try ComposeExporter.export([dockerSource()]), to: url)
    #expect(try mode() == 0o644)
}
