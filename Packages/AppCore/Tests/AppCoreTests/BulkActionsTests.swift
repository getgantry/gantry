import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

@MainActor
@Suite struct BulkActionsTests {
    private func connectedSession(
        host: DockerHost = DockerHost(name: "Local", kind: .local),
        configure: (MockTransport) -> Void
    ) async -> (HostSession, MockTransport) {
        let transport = MockTransport()
        transport.on(.get, "/version", json: Fixtures.version)
        configure(transport)
        let client = DockerClient(transport: transport)
        let version = try! await client.negotiate()
        let session = HostSession(host: host)
        session._setConnectedClientForTesting(client, version: version)
        return (session, transport)
    }

    private func container(_ id: String, _ state: ContainerState, image: String = "") -> ContainerSummary {
        let json = #"{"Id":"\#(id)","Names":["/\#(id)"],"State":"\#(state.rawValue)","ImageID":"\#(image)"}"#
        return try! JSONDecoder().decode(ContainerSummary.self, from: Data(json.utf8))
    }

    private func image(_ id: String, tags: [String]) -> ImageSummary {
        let json = #"{"Id":"\#(id)","RepoTags":\#(tags.isEmpty ? "[]" : "[\"" + tags.joined(separator: "\",\"") + "\"]")}"#
        return try! JSONDecoder().decode(ImageSummary.self, from: Data(json.utf8))
    }

    private func requests(_ transport: MockTransport, _ method: DockerRequest.Method, _ suffix: String) -> Int {
        transport.executed.filter { $0.method == method && $0.path.hasSuffix(suffix) }.count
    }

    // MARK: - Actions per host

    @Test func pauseAndResumeOnlyWhenTheHostSupportsThem() {
        let docker = BulkAction.actions(for: .containers, capabilities: .docker)
        let apple = BulkAction.actions(for: .containers, capabilities: .appleContainer)
        #expect(docker == [.start, .stop, .restart, .pause, .unpause])
        #expect(apple == [.start, .stop, .restart])
        #expect(BulkAction.actions(for: .images, capabilities: .appleContainer) == [.pull])
        #expect(BulkAction.actions(for: .volumes, capabilities: .docker).isEmpty)
        #expect(BulkAction.actions(for: .networks, capabilities: .docker).isEmpty)
    }

    // MARK: - Plans

    @Test func containerPlanSkipsItemsTheActionDoesNotApplyTo() {
        let list = [container("a", .running), container("b", .exited), container("c", .paused)]
        #expect(BulkPlan.containers(list, action: .start).eligible.map(\.id) == ["b"])
        #expect(BulkPlan.containers(list, action: .stop).eligible.map(\.id) == ["a"])
        #expect(BulkPlan.containers(list, action: .pause).eligible.map(\.id) == ["a"])
        #expect(BulkPlan.containers(list, action: .unpause).eligible.map(\.id) == ["c"])
        #expect(BulkPlan.containers(list, action: .remove(force: false)).eligible.count == 3)
        #expect(BulkPlan.containers(list, action: .start).skipped.map(\.id) == ["a", "c"])
    }

    @Test func pullPlanUsesTheTagAndSkipsUntaggedImages() {
        let list = [image("sha256:1", tags: ["nginx:latest"]), image("sha256:2", tags: ["<none>:<none>"])]
        let plan = BulkPlan.images(list, action: .pull)
        #expect(plan.eligible == [BulkItem(id: "nginx:latest", name: "nginx:latest")])
        #expect(plan.skipped.count == 1)
        #expect(BulkPlan.images(list, action: .remove(force: false)).eligible.map(\.id) == ["sha256:1", "sha256:2"])
    }

    @Test func networkPlanKeepsBuiltInNetworks() throws {
        let json = #"[{"Id":"n1","Name":"bridge"},{"Id":"n2","Name":"backend"}]"#
        let list = try JSONDecoder().decode([NetworkResource].self, from: Data(json.utf8))
        let plan = BulkPlan.networks(list, action: .remove(force: false))
        #expect(plan.eligible.map(\.id) == ["n2"])
        #expect(plan.skipped.map(\.name) == ["bridge"])
    }

    // MARK: - Runs

    @Test func stopContinuesAfterAFailureAndReportsIt() async {
        let (session, transport) = await connectedSession { t in
            t.on(.get, "/containers/json", json: Fixtures.containers([("c1", "running"), ("c2", "running"), ("c3", "running")]))
            t.on(.post, "/containers/c1/stop", status: 204, json: "")
            t.on(.post, "/containers/c2/stop", status: 500, json: #"{"message":"boom"}"#)
            t.on(.post, "/containers/c3/stop", status: 204, json: "")
        }
        await session.refreshContainers()
        let center = OperationCenter()
        session.operations = center
        let operation = session.runBulk(.stop, on: .containers, ids: ["c1", "c2", "c3"])
        await operation?.wait()

        #expect(requests(transport, .post, "/stop") == 3)
        guard case .failed(let message) = operation?.state else {
            Issue.record("expected a failed operation")
            return
        }
        #expect(message.contains("1 of 3 failed"))
        #expect(message.contains("c2: ") && message.contains("boom"))
        #expect(session.lastError == message)
        #expect(operation?.kind == .bulk)
        #expect(operation?.fraction == 1)
        #expect(operation?.log.count == 3)
    }

    @Test func successfulRunReportsASummaryAndRefreshesOnce() async {
        let (session, transport) = await connectedSession { t in
            t.on(.get, "/containers/json", json: Fixtures.containers([("c1", "exited"), ("c2", "exited"), ("c3", "running")]))
            t.on(.post, "/containers/c1/start", status: 204, json: "")
            t.on(.post, "/containers/c2/start", status: 204, json: "")
        }
        await session.refreshContainers()
        session.lastError = "old"
        let center = OperationCenter()
        session.operations = center
        let before = requests(transport, .get, "/containers/json")
        let operation = session.runBulk(.start, on: .containers, ids: ["c1", "c2", "c3"])
        await operation?.wait()

        #expect(operation?.state == .succeeded("2 done, 1 skipped."))
        #expect(requests(transport, .post, "/start") == 2)
        #expect(requests(transport, .get, "/containers/json") == before + 1)
        #expect(session.lastError == nil)
        #expect(center.operations.count == 1)
    }

    @Test func nothingToDoStartsNoOperation() async {
        let (session, _) = await connectedSession { t in
            t.on(.get, "/containers/json", json: Fixtures.containers([("c1", "running")]))
        }
        await session.refreshContainers()
        let center = OperationCenter()
        session.operations = center
        #expect(session.runBulk(.start, on: .containers, ids: ["c1"]) == nil)
        #expect(center.operations.isEmpty)
    }

    @Test func removeImagesVolumesAndNetworksWithForce() async {
        let (session, transport) = await connectedSession { t in
            t.on(.get, "/images/json", json: #"[{"Id":"i1","RepoTags":["a:1"]},{"Id":"i2","RepoTags":["b:1"]}]"#)
            t.on(.get, "/volumes", json: #"{"Volumes":[{"Name":"v1"},{"Name":"v2"}]}"#)
            t.on(.get, "/networks", json: #"[{"Id":"n1","Name":"one"},{"Id":"n2","Name":"two"}]"#)
            t.on(.delete, "/images/i1", json: "[]")
            t.on(.delete, "/images/i2", json: "[]")
            t.on(.delete, "/volumes/v1", status: 204, json: "")
            t.on(.delete, "/volumes/v2", status: 204, json: "")
            t.on(.delete, "/networks/n1", status: 204, json: "")
            t.on(.delete, "/networks/n2", status: 204, json: "")
        }
        await session.refreshImages()
        await session.refreshVolumes()
        await session.refreshNetworks()
        let center = OperationCenter()
        session.operations = center

        await session.runBulk(.remove(force: true), on: .images, ids: ["i1", "i2"])?.wait()
        await session.runBulk(.remove(force: false), on: .volumes, ids: ["v1", "v2"])?.wait()
        let networks = session.runBulk(.remove(force: false), on: .networks, ids: ["n1", "n2"])
        await networks?.wait()

        let imageDeletes = transport.executed.filter { $0.method == .delete && $0.path.contains("/images/") }
        #expect(imageDeletes.count == 2)
        #expect(imageDeletes.allSatisfy { $0.query.contains { $0.name == "force" && $0.value == "true" } })
        #expect(requests(transport, .delete, "/volumes/v1") + requests(transport, .delete, "/volumes/v2") == 2)
        #expect(networks?.state == .succeeded("2 done."))
    }

    @Test func pullLatestPullsEveryTag() async {
        let (session, transport) = await connectedSession { t in
            t.on(.get, "/images/json", json: #"[{"Id":"i1","RepoTags":["nginx:latest"]},{"Id":"i2","RepoTags":["redis:7"]}]"#)
            t.onStream("/images/create", lines: [#"{"status":"Pulling"}"#])
        }
        await session.refreshImages()
        let center = OperationCenter()
        session.operations = center
        let operation = session.runBulk(.pull, on: .images, ids: ["i1", "i2"])
        await operation?.wait()

        let pulls = transport.executed.filter { $0.path.hasSuffix("/images/create") }
        let images = Set(pulls.compactMap { $0.query.first { $0.name == "fromImage" }?.value })
        #expect(images == ["nginx", "redis"])
        #expect(operation?.state == .succeeded("2 done."))
    }

    @Test func disconnectedRunFailsEveryItem() async {
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        let plan = BulkPlan(eligible: [BulkItem(id: "c1", name: "web")], skipped: [])
        let outcome = await session.performBulk(.stop, on: .containers, plan: plan, operation: nil)
        #expect(outcome.failed == [BulkFailure(item: BulkItem(id: "c1", name: "web"), message: "Not connected")])
    }

    @Test func manyItemsRunWithBoundedConcurrencyAndKeepOrder() async {
        let ids = (1...9).map { "c\($0)" }
        let (session, _) = await connectedSession { t in
            t.on(.get, "/containers/json", json: Fixtures.containers(ids.map { ($0, "running") }))
            for id in ids { t.on(.post, "/containers/\(id)/restart", status: 204, json: "") }
        }
        await session.refreshContainers()
        let plan = session.bulkPlan(.restart, on: .containers, ids: Set(ids))
        let outcome = await session.performBulk(.restart, on: .containers, plan: plan, operation: nil)
        #expect(outcome.succeeded.map(\.id) == ids)
    }

    // MARK: - Confirmation

    @Test func removeConfirmationNamesTheCountAndTheUsers() async {
        let (session, _) = await connectedSession { t in
            t.on(.get, "/images/json", json: #"[{"Id":"i1","RepoTags":["a:1"]},{"Id":"i2","RepoTags":["b:1"]}]"#)
        }
        await session.refreshImages()
        let action = DestructiveAction.removeImages(
            session.images,
            containers: [container("x", .running, image: "i1"), container("y", .exited, image: "i2")],
            engine: .docker
        )
        #expect(action.names == ["a:1", "b:1"])
        #expect(action.impact == .containersUseImages(2))
        #expect(action.forceAvailable)
        #expect(action.isGated)

        let volumes = DestructiveAction.removeVolumes(names: ["v1", "v2"], containers: [], engine: .appleContainer)
        #expect(volumes.targets == ["v1", "v2"])
        #expect(!volumes.forceAvailable)
    }

    @Test func bulkRemoveActionLeavesBuiltInNetworksOut() async {
        let (session, _) = await connectedSession { t in
            t.on(.get, "/networks", json: #"[{"Id":"n1","Name":"bridge"},{"Id":"n2","Name":"backend"}]"#)
        }
        await session.refreshNetworks()
        #expect(session.bulkRemoveAction(on: .networks, ids: ["n1", "n2"])?.targets == ["n2"])
        #expect(session.bulkRemoveAction(on: .networks, ids: ["n1"]) == nil)
    }

    @Test func listedNamesStopAtTheLimit() {
        let names = (1...12).map { "n\($0)" }
        let action = DestructiveAction(kind: .removeVolume, targets: names)
        let listed = action.listedNames(limit: 10)
        #expect(listed.shown.count == 9)
        #expect(listed.more == 3)
        #expect(DestructiveAction(kind: .removeVolume, targets: ["a", "b"]).listedNames().more == 0)
    }

    @Test func failureReportListsEveryFailedItem() {
        var outcome = BulkOutcome(action: .remove(force: false), resource: .volumes)
        outcome.succeeded = [BulkItem(id: "a", name: "a")]
        outcome.failed = [BulkFailure(item: BulkItem(id: "b", name: "b"), message: "in use")]
        #expect(outcome.failureReport == "Remove: 1 of 2 failed.\nb: in use")
        outcome.failed = []
        #expect(outcome.failureReport == nil)
    }
}
