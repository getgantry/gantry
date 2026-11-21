import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

private let oldDigest = "sha256:1111111111111111111111111111111111111111111111111111111111111111"
private let newDigest = "sha256:2222222222222222222222222222222222222222222222222222222222222222"

private func container(_ json: String) throws -> ContainerSummary {
    try JSONDecoder().decode(ContainerSummary.self, from: Data(json.utf8))
}

private func image(id: String, digests: [String]) throws -> ImageSummary {
    let list = digests.map { "\"\($0)\"" }.joined(separator: ",")
    return try JSONDecoder().decode(ImageSummary.self, from: Data(#"{"Id":"\#(id)","RepoDigests":[\#(list)]}"#.utf8))
}

// MARK: - Plan

@Suite struct ImageUpdatePlanTests {
    @Test func dockerTargetUsesRepoDigestOfTheRunningImage() throws {
        let web = try container(#"{"Id":"c1","Image":"nginx:alpine","ImageID":"sha256:img","State":"running"}"#)
        let images = [
            try image(id: "sha256:other", digests: ["nginx@\(newDigest)"]),
            try image(id: "sha256:img", digests: ["mirror.local/nginx@\(newDigest)", "nginx@\(oldDigest)"])
        ]
        let target = try #require(ImageUpdatePlan.target(for: web, images: images, isApple: false))
        #expect(target.key == "docker.io/library/nginx:alpine")
        #expect(target.localDigest == oldDigest)
        #expect(ImageUpdatePlan.status(of: target, remoteDigest: newDigest) == .updateAvailable)
        #expect(ImageUpdatePlan.status(of: target, remoteDigest: oldDigest) == .upToDate)
        #expect(ImageUpdatePlan.status(of: target, remoteDigest: nil) == nil)
    }

    @Test func dockerLocalBuildIsSkipped() throws {
        let app = try container(#"{"Id":"c1","Image":"myapp:dev","ImageID":"sha256:img","State":"running"}"#)
        #expect(ImageUpdatePlan.target(for: app, images: [try image(id: "sha256:img", digests: [])], isApple: false) == nil)
        #expect(ImageUpdatePlan.target(for: app, images: [], isApple: false) == nil)
    }

    @Test(arguments: [
        "nginx@sha256:2222222222222222222222222222222222222222222222222222222222222222",
        "sha256:0790692be935ea4420d085694f7985b1f692ca6a8771ab0e0bd8ba75ac180498",
        "0790692be935ea4420d085694f7985b1f692ca6a8771ab0e0bd8ba75ac180498",
        ""
    ])
    func pinnedOrUntaggedIsSkipped(_ reference: String) throws {
        let pinned = try container(#"{"Id":"c1","Image":"\#(reference)","ImageID":"\#(oldDigest)","State":"running"}"#)
        #expect(ImageUpdatePlan.target(for: pinned, images: [], isApple: true) == nil)
        #expect(ImageUpdatePlan.target(for: pinned, images: [], isApple: false) == nil)
    }

    @Test func appleTargetUsesTheDescriptorDigest() throws {
        // Image and ImageID as AppleContainerJSON maps `container list` 1.7.1.
        let web = try container(#"{"Id":"web","Image":"docker.io/library/alpine:3.22","ImageID":"\#(oldDigest)","State":"running"}"#)
        let target = try #require(ImageUpdatePlan.target(for: web, images: [], isApple: true))
        #expect(target.key == "docker.io/library/alpine:3.22")
        #expect(target.localDigest == oldDigest)
    }

    @Test func userEnvironmentAndCommandLeaveImageDefaultsOut() {
        let image = ["PATH=/usr/bin", "NGINX_VERSION=1.27.0"]
        let env = ImageUpdatePlan.userEnvironment(container: ["PATH=/usr/bin", "NGINX_VERSION=1.27.0", "MODE=prod"], image: image)
        #expect(env == ["MODE=prod"])
        #expect(ImageUpdatePlan.userCommand(container: ["nginx", "-g", "daemon off;"], image: ["nginx", "-g", "daemon off;"]) == nil)
        #expect(ImageUpdatePlan.userCommand(container: ["sh"], image: ["nginx"]) == ["sh"])
        #expect(ImageUpdatePlan.userCommand(container: nil, image: ["nginx"]) == nil)
        let defaults = ImageUpdatePlan.imageDefaults(fromInspect: Data(#"{"Config":{"Env":["A=1"],"Cmd":["x"]}}"#.utf8))
        #expect(defaults.env == ["A=1"])
        #expect(defaults.cmd == ["x"])
        #expect(ImageUpdatePlan.imageDefaults(fromInspect: Data("{}".utf8)).env.isEmpty)
    }
}

// MARK: - Cache and monitor

@Suite struct ImageUpdateCacheTests {
    @Test func freshnessRules() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var cache = ImageUpdateCache()
        #expect(cache.isDue("a", now: start))
        cache.record("a", digest: newDigest, at: start)
        cache.record("b", digest: nil, at: start)
        #expect(!cache.isDue("a", now: start.addingTimeInterval(5 * 3600)))
        #expect(cache.isDue("a", now: start.addingTimeInterval(6 * 3600)))
        #expect(!cache.isDue("b", now: start.addingTimeInterval(59 * 60)))
        #expect(cache.isDue("b", now: start.addingTimeInterval(3600)))
        #expect(cache.remoteDigest(for: "b") == nil)
        cache.prune(now: start.addingTimeInterval(8 * 24 * 3600))
        #expect(cache.entries.isEmpty)
    }

    @Test func fileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("upd-\(UUID().uuidString)/image-updates.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var cache = ImageUpdateCache()
        cache.record("docker.io/library/nginx:alpine", digest: newDigest, at: Date(timeIntervalSince1970: 1_700_000_000))
        try cache.save(to: url)
        #expect(ImageUpdateCache.load(from: url) == cache)
        #expect(ImageUpdateCache.load(from: url.appendingPathExtension("missing")).entries.isEmpty)
    }
}

private final class LookupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func bump() { lock.withLock { value += 1 } }
}

@MainActor
@Suite struct ImageUpdateMonitorTests {
    private func target(_ text: String) -> ImageUpdatePlan.Target {
        ImageUpdatePlan.Target(reference: ImageReference.parse(text)!, localDigest: oldDigest)
    }

    @Test func freshResultsSendNoRequestAndForceDoes() async {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let monitor = ImageUpdateMonitor(fileURL: nil, now: { now })
        let counter = LookupCounter()
        let lookup: @Sendable (ImageReference) async throws -> String = { _ in counter.bump(); return newDigest }
        let targets = [target("nginx:alpine"), target("docker.io/library/nginx:alpine"), target("redis:7")]

        await monitor.check(targets, force: false, lookup: lookup)
        #expect(counter.count == 2)
        #expect(monitor.remoteDigest(for: "docker.io/library/nginx:alpine") == newDigest)

        now = now.addingTimeInterval(3600)
        await monitor.check(targets, force: false, lookup: lookup)
        #expect(counter.count == 2)

        await monitor.check(targets, force: true, lookup: lookup)
        #expect(counter.count == 4)
    }

    @Test func failedLookupGivesNoDigest() async {
        let monitor = ImageUpdateMonitor(fileURL: nil)
        await monitor.check([target("nginx:alpine")], force: false) { _ in throw RegistryCheckError.rateLimited }
        #expect(monitor.remoteDigest(for: "docker.io/library/nginx:alpine") == nil)
        #expect(monitor.cache.entries["docker.io/library/nginx:alpine"] != nil)
    }
}

// MARK: - Session

@MainActor
@Suite struct ImageUpdateSessionTests {
    private static let containers = """
    [{"Id":"web","Names":["/web"],"Image":"nginx:alpine","ImageID":"sha256:img","State":"running","Status":"Up",
      "Ports":[{"PrivatePort":80,"PublicPort":8080,"Type":"tcp"}]},
     {"Id":"svc","Names":["/svc"],"Image":"redis:7","ImageID":"sha256:redis","State":"exited","Status":"Exited",
      "Labels":{"com.docker.compose.project":"shop"}},
     {"Id":"dev","Names":["/dev"],"Image":"myapp:dev","ImageID":"sha256:dev","State":"running","Status":"Up"}]
    """
    private static let images = """
    [{"Id":"sha256:img","RepoTags":["nginx:alpine"],"RepoDigests":["nginx@\(oldDigest)"]},
     {"Id":"sha256:redis","RepoTags":["redis:7"],"RepoDigests":["redis@\(newDigest)"]},
     {"Id":"sha256:dev","RepoTags":["myapp:dev"],"RepoDigests":[]}]
    """

    private func connectedSession(_ configure: (MockTransport) -> Void = { _ in }) async -> (HostSession, MockTransport) {
        let transport = MockTransport()
        transport.on(.get, "/version", json: Fixtures.version)
        transport.on(.get, "/containers/json", json: Self.containers)
        transport.on(.get, "/images/json", json: Self.images)
        transport.on(.get, "/distribution/docker.io/library/nginx:alpine/json", json: #"{"Descriptor":{"digest":"\#(newDigest)"}}"#)
        transport.on(.get, "/distribution/docker.io/library/redis:7/json", json: #"{"Descriptor":{"digest":"\#(newDigest)"}}"#)
        configure(transport)
        let client = DockerClient(transport: transport)
        let version = try! await client.negotiate()
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        session.imageUpdateMonitor = ImageUpdateMonitor(fileURL: nil)
        session._setConnectedClientForTesting(client, version: version)
        await session.refreshContainers()
        return (session, transport)
    }

    @Test func checkMarksOnlyTheContainerWithAnOlderDigest() async throws {
        let (session, transport) = await connectedSession()
        await session.checkImageUpdates()
        let byID = Dictionary(uniqueKeysWithValues: session.containers.map { ($0.id, $0) })
        #expect(session.imageUpdateStatus(for: try #require(byID["web"])) == .updateAvailable)
        #expect(session.imageUpdateStatus(for: try #require(byID["svc"])) == .upToDate)
        #expect(session.imageUpdateStatus(for: try #require(byID["dev"])) == nil)
        let distribution = transport.executed.filter { $0.path.contains("/distribution/") }
        #expect(distribution.count == 2)
    }

    @Test func failedCheckShowsNoMarkAndNoError() async throws {
        let (session, _) = await connectedSession { t in
            t.on(.get, "/distribution/docker.io/library/nginx:alpine/json", status: 500, json: #"{"message":"toomanyrequests"}"#)
        }
        await session.checkImageUpdates()
        let web = try #require(session.containers.first { $0.id == "web" })
        #expect(session.imageUpdateStatus(for: web) == nil)
        #expect(session.lastError == nil)
    }

    @Test func composeContainerIsNotUpdatedDirectly() async throws {
        let (session, _) = await connectedSession()
        let svc = try #require(session.containers.first { $0.id == "svc" })
        #expect(session.updateContainer(svc) == nil)
    }

    @Test func updatePullsThenRecreatesWithUserSettings() async throws {
        let (session, transport) = await connectedSession { t in
            t.on(.get, "/containers/web/json", json: """
            {"Id":"web","Name":"/web","State":{"Status":"running","Running":true},
             "Config":{"Image":"nginx:alpine","Env":["PATH=/usr/bin","NGINX_VERSION=1.27.0","MODE=prod"],
                       "Cmd":["nginx","-g","daemon off;"],"Labels":{"a":"b"}},
             "HostConfig":{"Binds":["/data:/usr/share/nginx/html"],"NetworkMode":"shopnet",
                           "RestartPolicy":{"Name":"always"}}}
            """)
            t.on(.get, "/images/sha256:img/json", json: """
            {"Id":"sha256:img","Config":{"Env":["PATH=/usr/bin","NGINX_VERSION=1.27.0"],"Cmd":["nginx","-g","daemon off;"]}}
            """)
            t.onStream("/images/create", lines: [#"{"status":"Pulling from library/nginx","id":"alpine"}"#, #"{"status":"Status: Downloaded newer image for nginx:alpine"}"#])
            t.on(.delete, "/containers/web", status: 204, json: "")
            t.on(.post, "/containers/create", status: 201, json: #"{"Id":"web2","Warnings":[]}"#)
            t.on(.post, "/containers/web2/start", status: 204, json: "")
        }
        let web = try #require(session.containers.first { $0.id == "web" })
        try await session.performUpdate(web, reference: "docker.io/library/nginx:alpine", operation: nil)

        let requests = transport.executed
        let pullIndex = try #require(requests.firstIndex { $0.path.hasSuffix("/images/create") })
        let removeIndex = try #require(requests.firstIndex { $0.method == .delete && $0.path.hasSuffix("/containers/web") })
        #expect(pullIndex < removeIndex)
        let create = try #require(requests.first { $0.path.hasSuffix("/containers/create") })
        #expect(create.query.contains(URLQueryItem(name: "name", value: "web")))
        let body = try #require(create.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["Image"] as? String == "nginx:alpine")
        #expect(body["Env"] as? [String] == ["MODE=prod"])
        #expect(body["Cmd"] == nil)
        let hostConfig = try #require(body["HostConfig"] as? [String: Any])
        #expect(hostConfig["NetworkMode"] as? String == "shopnet")
        #expect(hostConfig["Binds"] as? [String] == ["/data:/usr/share/nginx/html"])
        #expect(requests.contains { $0.path.hasSuffix("/containers/web2/start") })
    }

    @Test func failedPullKeepsTheOldContainer() async throws {
        let (session, transport) = await connectedSession { t in
            t.on(.get, "/containers/web/json", json: Fixtures.containerDetails)
            t.on(.get, "/images/sha256:img/json", json: "{}")
            t.onStream("/images/create", lines: [#"{"error":"manifest unknown","errorDetail":{"message":"manifest unknown"}}"#])
        }
        let web = try #require(session.containers.first { $0.id == "web" })
        await #expect(throws: (any Error).self) {
            try await session.performUpdate(web, reference: "docker.io/library/nginx:alpine", operation: nil)
        }
        #expect(!transport.executed.contains { $0.method == .delete })
    }
}
