import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

@MainActor
@Suite struct ComposeRunnerTests {
    private func connectedSession(configure: (MockTransport) -> Void) async -> (HostSession, MockTransport) {
        let transport = MockTransport()
        transport.on(.get, "/version", json: Fixtures.version)
        configure(transport)
        let client = DockerClient(transport: transport)
        let version = try! await client.negotiate()
        let session = HostSession(host: DockerHost(name: "Apple", kind: .appleContainer))
        session._setConnectedClientForTesting(client, version: version)
        return (session, transport)
    }

    /// A project where alphabetical order (app, zdb) differs from dependency
    /// order (zdb must precede app), so we also test the topological sort.
    private func sampleProject() -> ComposeProject {
        let yaml = """
        services:
          app:
            image: nginx
            depends_on: [zdb]
            ports: ["8080:80"]
            environment:
              - FOO=bar
            volumes:
              - appdata:/data
              - ./local:/etc/app:ro
          zdb:
            build: ./db
        volumes:
          appdata: {}
        """
        return try! ComposeParser().parse(
            text: yaml,
            fileURL: URL(fileURLWithPath: "/tmp/myproj/docker-compose.yml"),
            directory: URL(fileURLWithPath: "/tmp/myproj"),
            environment: [:]
        )
    }

    private func configureUpRoutes(_ t: MockTransport) {
        t.on(.get, "/containers/json", json: "[]")
        t.on(.get, "/images/json", json: Fixtures.images)        // nginx:latest present
        t.on(.get, "/volumes", json: "{\"Volumes\":[],\"Warnings\":[]}")
        t.on(.get, "/networks", json: "[]")
        t.on(.post, "/networks/create", json: "{\"Id\":\"netid\",\"Warning\":\"\"}")
        t.on(.post, "/volumes/create", json: "{\"Name\":\"myproj_appdata\",\"Driver\":\"local\",\"Mountpoint\":\"/x\"}")
        t.on(.post, "/build", status: 200, json: "built ok")
        t.on(.post, "/containers/create", status: 201, json: "{\"Id\":\"cid\",\"Warnings\":[]}")
        t.on(.post, "/start", status: 204, json: "")
    }

    @Test func bringsProjectUpInDependencyOrder() async throws {
        let (session, _) = await connectedSession(configure: configureUpRoutes)
        await session.refreshImages()   // seed nginx:latest so app's pull is skipped

        var events: [ComposeUpEvent] = []
        let runner = ComposeRunner(session: session, project: sampleProject())
        let started = try await runner.up { events.append($0) }

        #expect(started == 2)

        // Build happened for the built service.
        #expect(events.contains(.buildingImage(service: "zdb")))
        // nginx image was already present → no pull event for app.
        #expect(!events.contains { if case .pullingImage = $0 { return true } else { return false } })

        // Services started zdb-before-app (topological order).
        let startedOrder = events.compactMap { event -> String? in
            if case .startedService(let s, _) = event { return s } else { return nil }
        }
        #expect(startedOrder == ["zdb", "app"])

        // Network + named volume created with project scoping.
        #expect(events.contains(.creatingNetwork("myproj_default")))
        #expect(events.contains(.creatingVolume("myproj_appdata")))

        #expect(events.last == .finished(project: "myproj", started: 2))
    }

    @Test func buildRequestCarriesContextAndTag() async throws {
        let (session, transport) = await connectedSession(configure: configureUpRoutes)
        await session.refreshImages()
        let runner = ComposeRunner(session: session, project: sampleProject())
        _ = try await runner.up { _ in }

        let buildReq = try #require(transport.executed.first { $0.path.hasSuffix("/build") })
        let spec = try JSONDecoder().decode(ImageBuildSpec.self, from: #require(buildReq.body))
        #expect(spec.tag == "myproj-zdb:latest")
        #expect(spec.contextPath == "/tmp/myproj/db")
        #expect(spec.labels["com.docker.compose.project"] == "myproj")
    }

    @Test func createRequestCarriesComposeIdentity() async throws {
        let (session, transport) = await connectedSession(configure: configureUpRoutes)
        await session.refreshImages()
        let runner = ComposeRunner(session: session, project: sampleProject())
        _ = try await runner.up { _ in }

        // Find the app service's create request (image nginx).
        let creates = transport.executed.filter { $0.method == .post && $0.path.hasSuffix("/containers/create") }
        #expect(creates.count == 2)

        let appCreate = try #require(creates.first { req in
            guard let body = req.body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return false }
            return (json["Image"] as? String) == "nginx"
        })
        let appBody = try #require(appCreate.body)
        let json = try #require(try JSONSerialization.jsonObject(with: appBody) as? [String: Any])

        // Name from "<project>-<service>-1".
        #expect(ComposeRunnerTests.queryName(appCreate) == "myproj-app-1")

        let labels = try #require(json["Labels"] as? [String: String])
        #expect(labels["com.docker.compose.project"] == "myproj")
        #expect(labels["com.docker.compose.service"] == "app")
        #expect(labels["com.docker.compose.container-number"] == "1")

        let env = try #require(json["Env"] as? [String])
        #expect(env.contains("FOO=bar"))

        let hostConfig = try #require(json["HostConfig"] as? [String: Any])
        let binds = try #require(hostConfig["Binds"] as? [String])
        #expect(binds.contains("myproj_appdata:/data"))
        #expect(binds.contains("/tmp/myproj/local:/etc/app:ro"))

        let portBindings = try #require(hostConfig["PortBindings"] as? [String: Any])
        #expect(portBindings["80/tcp"] != nil)

        let networking = try #require(json["NetworkingConfig"] as? [String: Any])
        let endpoints = try #require(networking["EndpointsConfig"] as? [String: Any])
        #expect(endpoints["myproj_default"] != nil)
    }

    @Test func warnsOnUnsupportedRestartPolicy() async throws {
        let yaml = """
        services:
          web:
            image: nginx
            restart: always
        """
        let project = try ComposeParser().parse(
            text: yaml,
            fileURL: URL(fileURLWithPath: "/tmp/p/docker-compose.yml"),
            directory: URL(fileURLWithPath: "/tmp/p"),
            environment: [:]
        )
        let (session, _) = await connectedSession(configure: configureUpRoutes)
        await session.refreshImages()
        var events: [ComposeUpEvent] = []
        _ = try await ComposeRunner(session: session, project: project).up { events.append($0) }
        #expect(events.contains { if case .warning(let m) = $0 { return m.contains("restart") } else { return false } })
    }

    /// The create container name travels as a `name` query parameter.
    static func queryName(_ request: DockerRequest) -> String? {
        request.query.first { $0.name == "name" }?.value
    }
}
