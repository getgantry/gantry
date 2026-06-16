import Foundation
import Testing
@testable import AppCore
import DockerKit

@MainActor
@Suite("Container alert detection")
struct ContainerAlertTests {
    private func makeSession() -> (HostSession, Collector) {
        let session = HostSession(host: DockerHost(name: "prod", kind: .local))
        let collector = Collector()
        session.onContainerAlert = { collector.alerts.append($0) }
        return (session, collector)
    }

    private final class Collector {
        var alerts: [ContainerAlert] = []
    }

    private func dieEvent(id: String, name: String, exitCode: String) -> DockerEvent {
        DockerEvent(
            type: "container",
            action: "die",
            actorID: id,
            actorAttributes: ["name": name, "exitCode": exitCode]
        )
    }

    @Test func nonZeroExitEmitsCrashAlert() {
        let (session, collector) = makeSession()
        session.evaluateContainerAlert(dieEvent(id: "c1", name: "web", exitCode: "1"))
        #expect(collector.alerts.count == 1)
        #expect(collector.alerts.first?.kind == .exited(code: 1))
        #expect(collector.alerts.first?.containerName == "web")
        #expect(collector.alerts.first?.hostName == "prod")
    }

    @Test func cleanExitDoesNotAlert() {
        let (session, collector) = makeSession()
        session.evaluateContainerAlert(dieEvent(id: "c1", name: "job", exitCode: "0"))
        #expect(collector.alerts.isEmpty)
    }

    @Test func userInitiatedStopIsNotReportedAsCrash() {
        let (session, collector) = makeSession()
        // Simulate the bookkeeping perform() does for a manual stop/kill.
        session.markExpectedExit("c1")
        session.evaluateContainerAlert(dieEvent(id: "c1", name: "web", exitCode: "137"))
        #expect(collector.alerts.isEmpty)
    }

    @Test func expectedExitIsConsumedOnce() {
        let (session, collector) = makeSession()
        session.markExpectedExit("c1")
        // First die is the expected stop.
        session.evaluateContainerAlert(dieEvent(id: "c1", name: "web", exitCode: "137"))
        // A later, unexpected crash of the same container must alert again.
        session.evaluateContainerAlert(dieEvent(id: "c1", name: "web", exitCode: "1"))
        #expect(collector.alerts.count == 1)
        #expect(collector.alerts.first?.kind == .exited(code: 1))
    }

    @Test func oomAlwaysAlerts() {
        let (session, collector) = makeSession()
        session.evaluateContainerAlert(DockerEvent(
            type: "container",
            action: "oom",
            actorID: "c1",
            actorAttributes: ["name": "hungry"]
        ))
        #expect(collector.alerts.first?.kind == .outOfMemory)
    }

    @Test func unhealthyAlertsOncePerEpisode() {
        let (session, collector) = makeSession()
        let unhealthy = DockerEvent(
            type: "container",
            action: "health_status: unhealthy",
            actorID: "c1",
            actorAttributes: ["name": "api"]
        )
        session.evaluateContainerAlert(unhealthy)
        session.evaluateContainerAlert(unhealthy)
        #expect(collector.alerts.count == 1)
        #expect(collector.alerts.first?.kind == .unhealthy)

        // Recovering and failing again is a new episode -> a second alert.
        session.evaluateContainerAlert(DockerEvent(
            type: "container",
            action: "health_status: healthy",
            actorID: "c1",
            actorAttributes: ["name": "api"]
        ))
        session.evaluateContainerAlert(unhealthy)
        #expect(collector.alerts.count == 2)
    }

    @Test func normalLifecycleEventsAreSilent() {
        let (session, collector) = makeSession()
        for action in ["start", "stop", "create", "pause", "unpause", "rename"] {
            session.evaluateContainerAlert(DockerEvent(
                type: "container",
                action: action,
                actorID: "c1",
                actorAttributes: ["name": "web"]
            ))
        }
        #expect(collector.alerts.isEmpty)
    }

    @Test func alertBodyNamesContainerAndHost() {
        let alert = ContainerAlert(
            hostID: UUID(),
            hostName: "prod",
            containerID: "c1",
            containerName: "web",
            kind: .exited(code: 2)
        )
        #expect(alert.title == "Container stopped")
        #expect(alert.body.contains("web"))
        #expect(alert.body.contains("prod"))
        #expect(alert.body.contains("code 2"))
    }
}
