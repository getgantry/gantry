import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

@MainActor
@Suite struct HostSessionTests {
    /// Builds a session backed by a mock-transport client, marked connected.
    private func connectedSession(
        host: DockerHost = DockerHost(name: "Local", kind: .local),
        configure: (MockTransport) -> Void
    ) async -> (HostSession, MockTransport) {
        let transport = MockTransport()
        // Negotiate is exercised through the real DockerClient.
        transport.on(.get, "/version", json: Fixtures.version)
        configure(transport)
        let client = DockerClient(transport: transport)
        let version = try! await client.negotiate()
        let session = HostSession(host: host)
        session._setConnectedClientForTesting(client, version: version)
        return (session, transport)
    }

    // MARK: - refreshAll / refresh*

    @Test func refreshAllPopulatesLists() async {
        let (session, _) = await connectedSession { t in
            t.on(.get, "/containers/json", json: Fixtures.containers([("c1", "running")]))
            t.on(.get, "/images/json", json: Fixtures.images)
            t.on(.get, "/volumes", json: Fixtures.volumes)
            t.on(.get, "/networks", json: Fixtures.networks)
            t.on(.get, "/info", json: Fixtures.info)
        }
        await session.refreshAll()
        #expect(session.containers.count == 1)
        #expect(session.containers.first?.id == "c1")
        #expect(session.images.count == 1)
        #expect(session.volumes.count == 1)
        #expect(session.networks.count == 1)
        #expect(session.info != nil)
        #expect(session.lastError == nil)
    }

    @Test func individualRefreshers() async {
        let (session, _) = await connectedSession { t in
            t.on(.get, "/containers/json", json: Fixtures.containers([("a", "exited")]))
            t.on(.get, "/images/json", json: Fixtures.images)
            t.on(.get, "/volumes", json: Fixtures.volumes)
            t.on(.get, "/networks", json: Fixtures.networks)
        }
        await session.refreshContainers()
        await session.refreshImages()
        await session.refreshVolumes()
        await session.refreshNetworks()
        #expect(session.containers.count == 1)
        #expect(session.images.count == 1)
        #expect(session.volumes.count == 1)
        #expect(session.networks.count == 1)
    }

    @Test func refreshFailureIsSilentAndKeepsOldValue() async {
        let (session, transport) = await connectedSession { t in
            t.on(.get, "/containers/json", json: Fixtures.containers([("a", "running")]))
        }
        await session.refreshContainers()
        #expect(session.containers.count == 1)
        // Break the route so the next refresh fails (599 apiError).
        transport.on(.get, "/containers/json", status: 599, json: #"{"message":"boom"}"#)
        await session.refreshContainers()
        // The prior list is kept, and a background refresh failure must NOT
        // surface a blocking modal — only user actions do.
        #expect(session.containers.count == 1)
        #expect(session.lastError == nil)
    }

    // MARK: - perform / mutate

    @Test func performStartSucceeds() async {
        let (session, transport) = await connectedSession { t in
            t.on(.post, "/containers/c1/start", status: 204, json: "")
            t.on(.get, "/containers/json", json: Fixtures.containers([("c1", "running")]))
        }
        let ok = await session.perform(.start, on: "c1")
        #expect(ok)
        // Refresh ran after the mutation.
        #expect(session.containers.first?.state == .running)
        #expect(transport.executed.contains { $0.path.hasSuffix("/containers/c1/start") })
    }

    @Test func performCoversAllActions() async {
        let (session, _) = await connectedSession { t in
            t.on(.post, "/containers/c1/start", status: 204, json: "")
            t.on(.post, "/containers/c1/stop", status: 204, json: "")
            t.on(.post, "/containers/c1/restart", status: 204, json: "")
            t.on(.post, "/containers/c1/kill", status: 204, json: "")
            t.on(.post, "/containers/c1/pause", status: 204, json: "")
            t.on(.post, "/containers/c1/unpause", status: 204, json: "")
            t.on(.delete, "/containers/c1", status: 204, json: "")
            t.on(.get, "/containers/json", json: Fixtures.containers([]))
        }
        for action: ContainerAction in [.start, .stop, .restart, .kill, .pause, .unpause, .remove(force: true)] {
            #expect(await session.perform(action, on: "c1"))
        }
    }

    @Test func performFailsAndSurfaces() async {
        let (session, _) = await connectedSession { t in
            t.on(.post, "/containers/c1/start", status: 500, json: #"{"message":"boom"}"#)
        }
        let ok = await session.perform(.start, on: "c1")
        #expect(!ok)
        #expect(session.lastError?.contains("boom") == true)
    }

    @Test func performWhenNotConnected() async {
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        let ok = await session.perform(.start, on: "c1")
        #expect(!ok)
        #expect(session.lastError == "Not connected")
    }

    // MARK: - details

    @Test func detailsSucceeds() async {
        let (session, _) = await connectedSession { t in
            t.on(.get, "/containers/c1/json", json: Fixtures.containerDetails)
        }
        let details = await session.details(for: "c1")
        #expect(details?.id == "c1")
        #expect(details?.state.running == true)
    }

    @Test func detailsFailureIsSilent() async {
        let (session, _) = await connectedSession { _ in }
        let details = await session.details(for: "missing")
        #expect(details == nil)
        // The Overview tab renders an inline "Details Unavailable" placeholder
        // when this returns nil; a failed inspect must not pop a modal.
        #expect(session.lastError == nil)
    }

    @Test func detailsNotConnected() async {
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        #expect(await session.details(for: "c1") == nil)
        #expect(session.lastError == "Not connected")
    }

    // MARK: - rawInspect*

    @Test func rawInspectFormatsJSON() async {
        let (session, _) = await connectedSession { t in
            t.on(.get, "/containers/c1/json", json: #"{"b":1,"a":2}"#)
            t.on(.get, "/images/i1/json", json: #"{"x":1}"#)
            t.on(.get, "/volumes/v1", json: #"{"y":2}"#)
            t.on(.get, "/networks/n1", json: #"{"z":3}"#)
        }
        let c = await session.rawInspectContainer(id: "c1")
        #expect(c.contains("\"a\""))
        #expect(c.contains("\n"))
        #expect(await session.rawInspectImage(id: "i1").contains("\"x\""))
        #expect(await session.rawInspectVolume(name: "v1").contains("\"y\""))
        #expect(await session.rawInspectNetwork(id: "n1").contains("\"z\""))
    }

    @Test func rawInspectReturnsErrorTextOnFailure() async {
        let (session, _) = await connectedSession { _ in }
        let result = await session.rawInspectContainer(id: "missing")
        #expect(!result.isEmpty)
        #expect(!result.contains("{"))
    }

    @Test func rawInspectNotConnected() async {
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        #expect(await session.rawInspectContainer(id: "c1") == "Not connected")
    }

    // MARK: - prune / remove / create wrappers

    @Test func pruneStoppedContainers() async {
        let (session, _) = await connectedSession { t in
            t.on(.post, "/containers/prune", json: Fixtures.pruneContainers(["a", "b"], reclaimed: 4096))
            t.on(.get, "/containers/json", json: Fixtures.containers([]))
        }
        let result = await session.pruneStoppedContainers()
        #expect(result?.deletedCount == 2)
        #expect(result?.spaceReclaimed == 4096)
    }

    @Test func pruneImagesAndVolumesAndNetworks() async {
        let (session, _) = await connectedSession { t in
            t.on(.post, "/images/prune", json: Fixtures.pruneImages(count: 3, reclaimed: 10))
            t.on(.post, "/volumes/prune", json: #"{"VolumesDeleted":["v1"],"SpaceReclaimed":5}"#)
            t.on(.post, "/networks/prune", json: #"{"NetworksDeleted":["n1","n2"]}"#)
            t.on(.post, "/build/prune", json: #"{"CachesDeleted":[{}],"SpaceReclaimed":7}"#)
            t.on(.get, "/images/json", json: Fixtures.images)
            t.on(.get, "/volumes", json: Fixtures.volumes)
            t.on(.get, "/networks", json: Fixtures.networks)
        }
        #expect(await session.pruneImages(dangling: true)?.deletedCount == 3)
        #expect(await session.pruneVolumes()?.deletedCount == 1)
        #expect(await session.pruneNetworks()?.deletedCount == 2)
        #expect(await session.pruneBuildCache()?.spaceReclaimed == 7)
    }

    @Test func removeImageVolumeNetwork() async {
        let (session, _) = await connectedSession { t in
            t.on(.delete, "/images/i1", json: "[]")
            t.on(.delete, "/volumes/v1", status: 204, json: "")
            t.on(.delete, "/networks/n1", status: 204, json: "")
            t.on(.get, "/images/json", json: Fixtures.images)
            t.on(.get, "/volumes", json: Fixtures.volumes)
            t.on(.get, "/networks", json: Fixtures.networks)
        }
        #expect(await session.removeImage(id: "i1"))
        #expect(await session.removeVolume(name: "v1"))
        #expect(await session.removeNetwork(id: "n1"))
    }

    @Test func createVolumeAndNetwork() async {
        let (session, _) = await connectedSession { t in
            t.on(.post, "/volumes/create", status: 201, json: #"{"Name":"v1","Driver":"local","Mountpoint":"/x"}"#)
            t.on(.post, "/networks/create", status: 201, json: #"{"Id":"newnet","Warning":""}"#)
            t.on(.get, "/volumes", json: Fixtures.volumes)
            t.on(.get, "/networks", json: Fixtures.networks)
        }
        #expect(await session.createVolume(name: "v1")?.name == "v1")
        #expect(await session.createNetwork(name: "n1") == "newnet")
    }

    @Test func renameTagUpdateRestartPolicyCommit() async {
        let (session, _) = await connectedSession { t in
            t.on(.post, "/containers/c1/rename", status: 204, json: "")
            t.on(.post, "/images/i1/tag", status: 201, json: "")
            t.on(.post, "/containers/c1/update", json: #"{"Warnings":[]}"#)
            t.on(.post, "/commit", status: 201, json: #"{"Id":"img"}"#)
            t.on(.get, "/containers/json", json: Fixtures.containers([]))
            t.on(.get, "/images/json", json: Fixtures.images)
        }
        #expect(await session.rename(containerID: "c1", to: "newname"))
        #expect(await session.tagImage(id: "i1", repo: "r", tag: "t"))
        #expect(await session.updateRestartPolicy(containerID: "c1", policy: "always", maxRetries: 0))
        #expect(await session.commit(containerID: "c1", repo: "r", tag: "t", comment: "c"))
    }

    @Test func connectDisconnectContainerNetwork() async {
        let (session, _) = await connectedSession { t in
            t.on(.post, "/networks/n1/connect", json: "")
            t.on(.post, "/networks/n1/disconnect", json: "")
            t.on(.get, "/networks", json: Fixtures.networks)
        }
        #expect(await session.connectContainer(networkID: "n1", containerID: "c1"))
        #expect(await session.disconnectContainer(networkID: "n1", containerID: "c1"))
    }

    @Test func imageHistoryAndSystemDF() async {
        let (session, _) = await connectedSession { t in
            t.on(.get, "/images/i1/history", json: #"[{"Id":"l1","Created":1,"Size":2,"CreatedBy":"x","Comment":""}]"#)
            t.on(.get, "/system/df", json: #"{"LayersSize":1,"Images":[],"Containers":[],"Volumes":[]}"#)
        }
        let history = await session.imageHistory(id: "i1")
        #expect(history?.count == 1)
        #expect(await session.systemDF() != nil)
    }

    @Test func networkContainersDecodesAttachments() async {
        let (session, _) = await connectedSession { t in
            t.on(.get, "/networks/n1", json: """
            {"Containers":{"id1":{"Name":"web","IPv4Address":"10.0.0.5/24","IPv6Address":""}}}
            """)
        }
        let attached = await session.networkContainers(id: "n1")
        #expect(attached.count == 1)
        #expect(attached.first?.name == "web")
    }

    // MARK: - createAndRun / createContainer

    @Test func createAndRunStartsContainer() async throws {
        let (session, transport) = await connectedSession { t in
            t.on(.post, "/containers/create", status: 201, json: #"{"Id":"new1","Warnings":[]}"#)
            t.on(.post, "/containers/new1/start", status: 204, json: "")
            t.on(.get, "/containers/json", json: Fixtures.containers([("new1", "running")]))
        }
        let req = ContainerCreateRequest(image: "nginx", name: "web")
        let id = try await session.createAndRun(req)
        #expect(id == "new1")
        #expect(transport.executed.contains { $0.path.hasSuffix("/containers/new1/start") })
    }

    @Test func createContainerWithoutStart() async throws {
        let (session, transport) = await connectedSession { t in
            t.on(.post, "/containers/create", status: 201, json: #"{"Id":"new2","Warnings":[]}"#)
            t.on(.get, "/containers/json", json: Fixtures.containers([]))
        }
        let id = try await session.createContainer(ContainerCreateRequest(image: "nginx"))
        #expect(id == "new2")
        #expect(!transport.executed.contains { $0.path.hasSuffix("/start") })
    }

    @Test func createAndRunNotConnectedThrows() async {
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        await #expect(throws: DockerError.self) {
            try await session.createAndRun(ContainerCreateRequest(image: "x"))
        }
    }

    // MARK: - containerLoad CPU delta math

    @Test func containerLoadEmptyWhenNoRunning() async {
        let (session, _) = await connectedSession { t in
            t.on(.get, "/containers/json", json: Fixtures.containers([("c1", "exited")]))
        }
        await session.refreshContainers()
        let load = await session.containerLoad()
        #expect(load?.cpuPercent == 0)
        #expect(load?.sampled == 0)
    }

    @Test func containerLoadCPUDeltaAcrossTwoCalls() async {
        // First call establishes baseline (CPU 0); second computes the delta.
        // total goes 1000 -> 3000 (delta 2000), system 10000 -> 20000
        // (delta 10000), online 2 -> cpu% = 2000/10000 * 2 * 100 = 40.
        var callCount = 0
        let transport = MockTransport()
        transport.on(.get, "/version", json: Fixtures.version)
        transport.on(.get, "/containers/json", json: Fixtures.containers([("c1", "running")]))
        let client = DockerClient(transport: transport)
        let version = try! await client.negotiate()
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        session._setConnectedClientForTesting(client, version: version)
        await session.refreshContainers()

        // Re-route stats per call via a custom transport subclass is overkill;
        // instead register both samples sequentially by swapping the route.
        transport.on(.get, "/containers/c1/stats",
                     json: Fixtures.statsOnce(total: 1000, system: 10000, online: 2, memUsage: 500, memLimit: 1000))
        let first = await session.containerLoad()
        #expect(first?.cpuPercent == 0)        // baseline only
        #expect(first?.memoryUsedBytes == 500)
        #expect(first?.sampled == 1)

        transport.on(.get, "/containers/c1/stats",
                     json: Fixtures.statsOnce(total: 3000, system: 20000, online: 2, memUsage: 600, memLimit: 1000))
        let second = await session.containerLoad()
        #expect(second?.cpuPercent == 40.0)
        #expect(second?.memoryUsedBytes == 600)
        callCount += 1
        #expect(callCount == 1)
    }

    @Test func containerLoadNotConnected() async {
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        #expect(await session.containerLoad() == nil)
    }

    // MARK: - event monitoring / debounce

    @Test func consumeEventsDebouncesContainerRefresh() async {
        let transport = MockTransport()
        transport.on(.get, "/version", json: Fixtures.version)
        transport.on(.get, "/containers/json", json: Fixtures.containers([("c1", "running")]))
        transport.on(.get, "/images/json", json: Fixtures.images)
        transport.on(.get, "/volumes", json: Fixtures.volumes)
        transport.on(.get, "/networks", json: Fixtures.networks)
        // One clean event stream then it ends; loop falls back to polling.
        transport.onStream("/events", lines: [
            Fixtures.event(type: "container", action: "start"),
            Fixtures.event(type: "container", action: "die"),
            Fixtures.event(type: "image", action: "pull"),
            Fixtures.event(type: "volume", action: "create"),
            Fixtures.event(type: "network", action: "create")
        ])
        let client = DockerClient(transport: transport)
        let version = try! await client.negotiate()
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        session._setConnectedClientForTesting(client, version: version)

        session.startEventMonitoring()
        // Give the debounced container refresh (300ms) time to fire.
        try? await Task.sleep(for: .milliseconds(600))
        await session.disconnect()

        // Image/volume/network events trigger immediate refreshes; container
        // events are debounced into a single one. All lists populated.
        #expect(session.status == .disconnected)
    }

    // MARK: - openExecSession (hijack)

    @Test func openExecSessionReturnsLiveSession() async throws {
        let transport = MockTransport()
        transport.on(.get, "/version", json: Fixtures.version)
        transport.on(.post, "/containers/c1/exec", json: #"{"Id":"exec1"}"#)
        transport.onHijack { _ in
            DockerHijackedConnection(
                status: 101,
                headers: [:],
                bytes: AsyncThrowingStream { $0.finish() },
                write: { _ in },
                close: {}
            )
        }
        let client = DockerClient(transport: transport)
        let version = try! await client.negotiate()
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        session._setConnectedClientForTesting(client, version: version)

        let exec = try await session.openExecSession(containerID: "c1", command: ["sh"])
        #expect(exec.id == "exec1")
        #expect(exec.tty)
        exec.terminate()
    }

    @Test func openExecSessionNotConnectedThrows() async {
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        await #expect(throws: DockerError.self) {
            try await session.openExecSession(containerID: "c1", command: ["sh"])
        }
    }

    // MARK: - host access (local host has none)

    @Test func localHostHasNoHostAccess() {
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        #expect(!session.supportsHostAccess)
        #expect(throws: DockerError.self) { try session.openHostShell() }
        #expect(throws: DockerError.self) { try session.hostFileSystem() }
    }

    // MARK: - credential / host-key prompt plumbing

    @Test func submitAndCancelCredentialAreSafeWhenIdle() {
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        // No pending request: these must not crash.
        session.submitCredential("x", store: false)
        session.cancelCredential()
        session.submitHostKeyDecision(trust: true)
        #expect(session.pendingCredentialRequest == nil)
        #expect(session.pendingHostKeyPrompt == nil)
    }

    @Test func credentialRequestKindEquatable() {
        #expect(HostSession.CredentialRequest.Kind.password == .password)
        #expect(HostSession.CredentialRequest.Kind.keyPassphrase(file: "a")
                != .keyPassphrase(file: "b"))
    }

    @Test func promptValueTypesConstruct() {
        let req = HostSession.CredentialRequest(kind: .password, hostName: "h")
        #expect(req.hostName == "h")
        #expect(req.kind == .password)
        let prompt = HostSession.HostKeyPromptState(host: "h", fingerprint: "fp", keyType: "ed25519")
        #expect(prompt.host == "h")
        #expect(prompt.fingerprint == "fp")
        #expect(prompt.keyType == "ed25519")
    }

    @Test func surfaceSwallowsCancellation() async {
        // A refresh whose client call throws DockerError.cancelled must NOT
        // populate lastError (cancellation is not a user-facing failure).
        let transport = MockTransport()
        transport.on(.get, "/version", json: Fixtures.version)
        transport.on(.get, "/containers/json", status: 599, json: #"{"message":"x"}"#)
        let client = DockerClient(transport: CancelTransport(version: Fixtures.version))
        let version = try! await client.negotiate()
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        session._setConnectedClientForTesting(client, version: version)
        await session.refreshContainers()
        // CancelTransport throws DockerError.cancelled -> swallowed.
        #expect(session.lastError == nil)
        #expect(session.containers.isEmpty)
    }

    // MARK: - disconnect from a connected session clears state

    @Test func disconnectClearsState() async {
        let (session, transport) = await connectedSession { t in
            t.on(.get, "/containers/json", json: Fixtures.containers([("c1", "running")]))
            t.on(.get, "/images/json", json: Fixtures.images)
            t.on(.get, "/volumes", json: Fixtures.volumes)
            t.on(.get, "/networks", json: Fixtures.networks)
            t.on(.get, "/info", json: Fixtures.info)
        }
        await session.refreshAll()
        #expect(!session.containers.isEmpty)
        await session.disconnect()
        #expect(session.status == .disconnected)
        #expect(session.containers.isEmpty)
        #expect(session.images.isEmpty)
        #expect(session.info == nil)
        #expect(transport.shutdownCount == 1)
    }
}
