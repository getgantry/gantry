import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

// MARK: - Operation center

@MainActor
@Suite struct OperationCenterTests {
    @Test func runSucceedsWithSummaryAndCallsOnFinish() async {
        let center = OperationCenter()
        var finished: [OperationState] = []
        center.onFinish = { finished.append($0.state) }
        let operation = center.run(.trim, title: "Trim", host: "Local") { op in
            op.update(progress: "half", fraction: 0.5)
            op.append(log: "line")
            return "2 disks"
        }
        #expect(center.runningCount == 1)
        await operation.wait()
        #expect(operation.state == .succeeded("2 disks"))
        #expect(operation.finishedAt != nil)
        #expect(operation.log == ["line"])
        #expect(center.runningCount == 0)
        #expect(finished == [.succeeded("2 disks")])
    }

    @Test func thrownErrorMarksFailed() async {
        let center = OperationCenter()
        let operation = center.run(.pull, title: "Pull") { _ in throw OperationFailure("denied") }
        await operation.wait()
        #expect(operation.state == .failed("denied"))
    }

    @Test func cancelStopsTheTask() async {
        let center = OperationCenter()
        let operation = center.run(.build, title: "Build") { _ in
            try await Task.sleep(for: .seconds(30))
            return nil
        }
        #expect(operation.canCancel)
        center.cancel(operation)
        #expect(operation.isCancelling)
        await operation.wait()
        #expect(operation.state == .cancelled)
        #expect(!operation.canCancel)
    }

    @Test func cancelRunsTheHandlerOfBegunWork() {
        let center = OperationCenter()
        var cancelled = false
        let operation = center.begin(.clusterCreate, title: "Cluster", cancelConfirmation: "nodes go") {
            cancelled = true
        }
        center.cancel(operation)
        #expect(cancelled)
        #expect(operation.state == .running)
        center.finish(operation, .cancelled)
        #expect(operation.state == .cancelled)
        // A second finish does nothing.
        center.finish(operation, .succeeded(nil))
        #expect(operation.state == .cancelled)
    }

    @Test func orderPutsRunningFirstThenLastFinished() {
        var clock = Date(timeIntervalSince1970: 0)
        let center = OperationCenter(now: { clock })
        let first = center.begin(.pull, title: "first")
        clock += 1
        let second = center.begin(.pull, title: "second")
        clock += 1
        let third = center.begin(.pull, title: "third")
        clock += 1
        center.finish(first, .succeeded(nil))
        clock += 1
        center.finish(third, .failed("x"))
        #expect(center.ordered.map(\.title) == ["second", "third", "first"])
        #expect(center.operations.map(\.title) == ["first", "second", "third"])
        center.clearFinished()
        #expect(center.operations.map(\.title) == ["second"])
    }

    @Test func finishedListIsCapped() {
        let center = OperationCenter()
        center.finishedLimit = 2
        for index in 0..<4 {
            center.finish(center.begin(.other, title: "\(index)"), .succeeded(nil))
        }
        #expect(center.operations.map(\.title) == ["2", "3"])
    }

    @Test func logIsCappedAndUpdatesStopAfterFinish() {
        let center = OperationCenter()
        let operation = center.begin(.build, title: "b")
        for index in 0..<(LongOperation.logLimit + 5) { operation.append(log: "\(index)") }
        #expect(operation.log.count == LongOperation.logLimit)
        #expect(operation.logTail(1) == ["\(LongOperation.logLimit + 4)"])
        center.finish(operation, .succeeded(nil))
        operation.update(progress: "late", fraction: 2)
        #expect(operation.progressText == nil)
    }
}

// MARK: - Destructive actions

@Suite struct DestructiveActionTests {
    private func container(_ id: String, running: Bool, image: String = "img", volume: String? = nil) -> ContainerSummary {
        let mounts = volume.map { #","Mounts":[{"Type":"volume","Name":"\#($0)","Source":"/s","Destination":"/d"}]"# } ?? ""
        let json = #"{"Id":"\#(id)","Names":["/\#(id)"],"ImageID":"\#(image)","State":"\#(running ? "running" : "exited")"\#(mounts)}"#
        return try! JSONDecoder().decode(ContainerSummary.self, from: Data(json.utf8))
    }

    @Test func removingContainersCountsRunningOnes() {
        let action = DestructiveAction.removeContainers(
            [container("a", running: true), container("b", running: false), container("c", running: true)],
            engine: .docker
        )
        #expect(action.impact == .runningContainersStop(2))
        #expect(action.names == ["a", "b", "c"])
        #expect(action.forceAvailable)
        #expect(action.isGated)
    }

    @Test func stoppedContainerHasNoImpact() {
        let action = DestructiveAction.removeContainers([container("a", running: false)], engine: .appleContainer)
        #expect(action.impact == .none)
    }

    @Test func imageImpactCountsItsContainers() {
        let containers = [container("a", running: false, image: "sha"), container("b", running: true, image: "other")]
        let action = DestructiveAction.removeImage(id: "sha", name: "nginx", containers: containers, engine: .appleContainer)
        #expect(action.impact == .containersUseImage(1))
        #expect(action.forceAvailable)
    }

    @Test func volumeForceOnlyOnDocker() {
        let containers = [container("a", running: true, volume: "data")]
        let docker = DestructiveAction.removeVolume(name: "data", containers: containers, engine: .docker)
        let apple = DestructiveAction.removeVolume(name: "data", containers: containers, engine: .appleContainer)
        #expect(docker.impact == .containersUseVolume(1))
        #expect(docker.forceAvailable)
        #expect(!apple.forceAvailable)
    }

    @Test func forceAvailabilityPerEngine() {
        for engine in [DestructiveAction.Engine.docker, .appleContainer] {
            #expect(DestructiveAction.supportsForce(.removeContainer, engine: engine))
            #expect(DestructiveAction.supportsForce(.removeImage, engine: engine))
            #expect(!DestructiveAction.supportsForce(.removeNetwork, engine: engine))
            #expect(!DestructiveAction.supportsForce(.deleteMachine, engine: engine))
        }
        #expect(DestructiveAction.Engine(DockerHost(name: "a", kind: .appleContainer)) == .appleContainer)
        #expect(DestructiveAction.Engine(DockerHost(name: "l", kind: .local)) == .docker)
    }

    @Test func groupAndServiceActionsAskWithoutTouchID() {
        let group = DestructiveAction.group(
            .stopGroup, project: "web", containers: [container("a", running: true), container("b", running: false)]
        )
        #expect(group.impact == .runningContainersStop(1))
        #expect(group.names == ["web"])
        #expect(!group.isGated)
        let services = DestructiveAction.services(.restartServices, runningContainers: 3)
        #expect(services.impact == .runningContainersStop(3))
        #expect(!services.isGated)
        #expect(DestructiveAction.services(.stopServices, runningContainers: 0).impact == .none)
    }
}

// MARK: - Error routing

@MainActor
@Suite struct ErrorRoutingTests {
    @Test func actionErrorGoesToTheBanner() async {
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        let ok = await session.rename(containerID: "c1", to: "x")
        #expect(!ok)
        #expect(session.lastError == "Not connected")
    }

    @Test func sheetErrorStaysInTheSheet() async {
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        let error = await session.attempt(fallback: "fallback") {
            await session.rename(containerID: "c1", to: "x")
        }
        #expect(error == "Not connected")
        #expect(session.lastError == nil)
    }

    @Test func parallelAttemptsKeepTheirOwnErrors() async {
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        async let first = session.attempt { await session.rename(containerID: "a", to: "x") }
        async let second = session.attempt { () async -> Bool in true }
        let (a, b) = await (first, second)
        #expect(a.error == "Not connected")
        #expect(b.error == nil)
        #expect(session.lastError == nil)
    }

    @Test func backgroundLoadsStaySilent() async {
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        await session.refreshImages()
        await session.refreshAll()
        _ = await session.details(for: "c1")
        #expect(session.lastError == nil)
    }

    @Test func routeTable() {
        #expect(ErrorPresentation.route(inSheet: true, background: false) == .sheet)
        #expect(ErrorPresentation.route(inSheet: false, background: false) == .banner)
        #expect(ErrorPresentation.route(inSheet: true, background: true) == .silent)
    }

    @Test func bannerSourceFollowsHostKind() {
        #expect(ErrorPresentation.source(for: DockerHost(name: "a", kind: .appleContainer)) == .appleContainer)
        #expect(ErrorPresentation.source(for: DockerHost(name: "l", kind: .local)) == .docker)
        let ssh = DockerHost(name: "prod", kind: .ssh(SSHEndpoint(host: "example.com")))
        #expect(ErrorPresentation.source(for: ssh) == .host("prod"))
    }

    @Test func splitKeepsStderrForDetails() {
        let short = ErrorPresentation.split("  boom  ")
        #expect(short.summary == "boom")
        #expect(short.details == nil)
        let cli = ErrorPresentation.split("Error: failed\nstderr line 1\nstderr line 2")
        #expect(cli.summary == "Error: failed")
        #expect(cli.details == "Error: failed\nstderr line 1\nstderr line 2")
        let long = ErrorPresentation.split(String(repeating: "x", count: 400))
        #expect(long.summary.count == ErrorPresentation.summaryLimit)
        #expect(long.details?.count == 400)
    }
}
