import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

@MainActor
@Suite struct ComposeProjectActionsTests {
    private func container(_ id: String, project: String?, image: String, state: String = "running") -> ContainerSummary {
        let labels = project.map { #"{"com.docker.compose.project":"\#($0)"}"# } ?? "{}"
        let json = #"{"Id":"\#(id)","Names":["/\#(id)"],"Image":"\#(image)","State":"\#(state)","Labels":\#(labels)}"#
        return try! JSONDecoder().decode(ContainerSummary.self, from: Data(json.utf8))
    }

    private func network(_ id: String, _ name: String, project: String?) -> NetworkResource {
        let labels = project.map { #"{"com.docker.compose.project":"\#($0)"}"# } ?? "{}"
        let json = #"{"Id":"\#(id)","Name":"\#(name)","Labels":\#(labels)}"#
        return try! JSONDecoder().decode(NetworkResource.self, from: Data(json.utf8))
    }

    private var sample: [ContainerSummary] {
        [
            container("c1", project: "shop", image: "postgres:17"),
            container("c2", project: "shop", image: "redis:7", state: "exited"),
            container("c3", project: "shop", image: "postgres:17"),
            container("c4", project: "shop", image: "sha256:" + String(repeating: "a", count: 64)),
            container("c5", project: "blog", image: "nginx:1"),
            container("c6", project: nil, image: "busybox"),
        ]
    }

    @Test func downTakesEveryProjectContainer() {
        let plan = ComposeProjectPlan.downContainers("shop", in: sample)
        #expect(plan.eligible.map(\.id) == ["c1", "c2", "c3", "c4"])
        #expect(plan.skipped.isEmpty)
    }

    @Test func downNetworksAreTheLabelledOnes() {
        let networks = [
            network("n1", "shop_default", project: "shop"),
            network("n2", "shop_back", project: "shop"),
            network("n3", "shop_external", project: nil),
            network("n4", "blog_default", project: "blog"),
            network("n5", "bridge", project: "shop"),
        ]
        #expect(ComposeProjectPlan.downNetworks("shop", in: networks).map(\.id) == ["n1", "n2"])
    }

    @Test func pullTakesUniqueTagsAndSkipsIDs() {
        let plan = ComposeProjectPlan.pull("shop", in: sample)
        #expect(plan.eligible.map(\.id) == ["postgres:17", "redis:7"])
        #expect(plan.skipped.count == 1)
        #expect(!ComposeProjectPlan.isPullable(String(repeating: "b", count: 64)))
        #expect(ComposeProjectPlan.isPullable("ghcr.io/acme/app:1.2"))
    }

    @Test func confirmationCountsRunningMembers() {
        let action = DestructiveAction.composeDown(project: "shop", containers: sample)
        #expect(action.kind == .composeDown)
        #expect(action.names == ["shop"])
        #expect(action.targets == ["c1", "c2", "c3", "c4"])
        #expect(action.impact == .runningContainersStop(3))
        #expect(action.isGated)
    }

    private func connectedSession(configure: (MockTransport) -> Void) async -> (HostSession, MockTransport) {
        let transport = MockTransport()
        transport.on(.get, "/version", json: Fixtures.version)
        configure(transport)
        let client = DockerClient(transport: transport)
        let version = try! await client.negotiate()
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        session._setConnectedClientForTesting(client, version: version)
        return (session, transport)
    }

    private static let containersJSON = #"""
    [{"Id":"c1","Names":["/shop-db-1"],"Image":"postgres:17","State":"running","Labels":{"com.docker.compose.project":"shop"}},
     {"Id":"c2","Names":["/shop-cache-1"],"Image":"redis:7","State":"exited","Labels":{"com.docker.compose.project":"shop"}},
     {"Id":"c9","Names":["/other"],"Image":"nginx:1","State":"running","Labels":{}}]
    """#

    @Test func composeDownRemovesContainersThenProjectNetworks() async {
        let (session, transport) = await connectedSession { t in
            t.on(.get, "/containers/json", json: Self.containersJSON)
            t.on(.get, "/networks", json: #"[{"Id":"n1","Name":"shop_default","Labels":{"com.docker.compose.project":"shop"}},{"Id":"n2","Name":"other","Labels":{}}]"#)
            t.on(.post, "/containers/c1/stop", status: 204, json: "")
            t.on(.post, "/containers/c2/stop", status: 304, json: "")
            t.on(.delete, "/containers/c1", status: 204, json: "")
            t.on(.delete, "/containers/c2", status: 204, json: "")
            t.on(.delete, "/networks/n1", status: 204, json: "")
        }
        await session.refreshContainers()
        let center = OperationCenter()
        session.operations = center
        let operation = session.composeDown(project: "shop")
        #expect(operation?.kind == .composeDown)
        #expect(operation?.title == "Compose down shop")
        await operation?.wait()

        let deletes = transport.executed.filter { $0.method == .delete }.map(\.path)
        #expect(deletes.filter { $0.contains("/containers/") }.count == 2)
        #expect(transport.executed.contains { $0.method == .post && $0.path.hasSuffix("/containers/c1/stop") })
        let removes = transport.executed.filter { $0.method == .delete && $0.path.contains("/containers/") }
        #expect(removes.allSatisfy { !$0.query.contains { $0.name == "force" && $0.value == "true" } })
        #expect(!deletes.contains { $0.contains("/containers/c9") })
        #expect(deletes.contains { $0.hasSuffix("/networks/n1") })
        #expect(!deletes.contains { $0.hasSuffix("/networks/n2") })
        #expect(!deletes.contains { $0.contains("/volumes/") })
        #expect(operation?.state == .succeeded("2 done."))
        #expect(operation?.progress.items == .init(done: 2, total: 2, unit: .items))
    }

    @Test func composePullPullsEachServiceImage() async {
        let (session, transport) = await connectedSession { t in
            t.on(.get, "/containers/json", json: Self.containersJSON)
            t.onStream("/images/create", lines: [#"{"status":"Pulling"}"#])
        }
        await session.refreshContainers()
        // The session holds its center weakly.
        let center = OperationCenter()
        session.operations = center
        let operation = session.composePull(project: "shop")
        #expect(operation?.kind == .composePull)
        await operation?.wait()
        let pulls = transport.executed.filter { $0.path.hasSuffix("/images/create") }
        let images = Set(pulls.compactMap { $0.query.first { $0.name == "fromImage" }?.value })
        #expect(images == ["postgres", "redis"])
        #expect(operation?.state == .succeeded("2 done."))
    }

    @Test func emptyProjectStartsNothing() async {
        let (session, _) = await connectedSession { t in
            t.on(.get, "/containers/json", json: Self.containersJSON)
        }
        await session.refreshContainers()
        #expect(session.composeDown(project: "none") == nil)
        #expect(session.composePull(project: "none") == nil)
    }
}
