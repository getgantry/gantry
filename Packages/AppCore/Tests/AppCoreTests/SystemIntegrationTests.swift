import Foundation
import Testing
@testable import AppCore
@testable import DockerKit
import GantryShared

private func container(
    id: String,
    name: String,
    state: String = "running",
    status: String = "Up 1 hour",
    labels: [String: String] = [:],
    ports: String = "[]"
) -> ContainerSummary {
    let labelJSON = String(decoding: try! JSONEncoder().encode(labels), as: UTF8.self)
    let json = """
    {"Id":"\(id)","Names":["/\(name)"],"Image":"nginx","State":"\(state)","Status":"\(status)",\
    "Labels":\(labelJSON),"Ports":\(ports)}
    """
    return try! JSONDecoder().decode(ContainerSummary.self, from: Data(json.utf8))
}

private func connected() -> ConnectionStatus {
    let json = #"{"Version":"27.0","ApiVersion":"1.47","Os":"linux","Arch":"arm64"}"#
    return .connected(try! JSONDecoder().decode(SystemVersion.self, from: Data(json.utf8)))
}

// MARK: - Notification routing

@Suite struct NotificationRouteTests {
    private let host = UUID()

    private var info: [AnyHashable: Any] {
        GantryNotification.containerInfo(hostID: host, containerID: "abc")
    }

    @Test func actionsMapToTheirRoutes() {
        typealias A = GantryNotification.Action
        #expect(NotificationRoute.resolve(actionIdentifier: A.restart, userInfo: info) == .restart(hostID: host, containerID: "abc"))
        #expect(NotificationRoute.resolve(actionIdentifier: A.viewLogs, userInfo: info) == .viewLogs(hostID: host, containerID: "abc"))
        #expect(NotificationRoute.resolve(actionIdentifier: A.copyPrompt, userInfo: info) == .copyPrompt(hostID: host, containerID: "abc"))
        #expect(NotificationRoute.resolve(actionIdentifier: A.systemDefault, userInfo: info) == .openContainer(hostID: host, containerID: "abc"))
    }

    @Test func dismissIsIgnoredAndOperationsShowActivity() {
        typealias A = GantryNotification.Action
        #expect(NotificationRoute.resolve(actionIdentifier: A.systemDismiss, userInfo: info) == .ignore)
        let operation: [AnyHashable: Any] = GantryNotification.operationInfo
        #expect(NotificationRoute.resolve(actionIdentifier: A.showActivity, userInfo: operation) == .showActivity)
        #expect(NotificationRoute.resolve(actionIdentifier: A.systemDefault, userInfo: operation) == .showActivity)
    }

    @Test func malformedInfoFallsBackToActivity() {
        let bad: [AnyHashable: Any] = ["hostID": "nope", "containerID": "abc"]
        #expect(NotificationRoute.resolve(actionIdentifier: GantryNotification.Action.restart, userInfo: bad) == .showActivity)
        let empty: [AnyHashable: Any] = ["hostID": host.uuidString, "containerID": ""]
        #expect(NotificationRoute.resolve(actionIdentifier: GantryNotification.Action.restart, userInfo: empty) == .showActivity)
    }

    @Test func backgroundActionsDoNotBringTheAppForward() {
        #expect(!NotificationRoute.restart(hostID: host, containerID: "a").bringsAppForward)
        #expect(!NotificationRoute.copyPrompt(hostID: host, containerID: "a").bringsAppForward)
        #expect(NotificationRoute.viewLogs(hostID: host, containerID: "a").bringsAppForward)
        #expect(NotificationRoute.showActivity.bringsAppForward)
    }

    @Test func categoryFollowsTheSetting() {
        #expect(GantryNotification.category(isOperation: false, actionsEnabled: true) == GantryNotification.Category.containerAlert)
        #expect(GantryNotification.category(isOperation: true, actionsEnabled: true) == GantryNotification.Category.operationFinished)
        #expect(GantryNotification.category(isOperation: false, actionsEnabled: false) == nil)
    }
}

// MARK: - Entity logic

@Suite struct FleetEntityTests {
    @Test func composeProjectsGroupByLabelAndSkipLooseContainers() {
        let host = UUID()
        let label = ComposeRunner.Label.project
        let list = [
            container(id: "1", name: "shop-web", labels: [label: "shop", ComposeRunner.Label.workingDir: "/srv/shop"]),
            container(id: "2", name: "shop-db", state: "exited", labels: [label: "shop"]),
            container(id: "3", name: "blog", labels: [label: "Blog"]),
            container(id: "4", name: "loose")
        ]
        let projects = ComposeProjectRef.projects(hostID: host, hostName: "Local", containers: list)
        #expect(projects.map(\.name) == ["Blog", "shop"])
        let shop = projects[1]
        #expect(shop.running == 1)
        #expect(shop.total == 2)
        #expect(Set(shop.containerIDs) == ["1", "2"])
        #expect(shop.workingDirectory == "/srv/shop")
        #expect(ComposeProjectRef.split(shop.id)?.project == "shop")
        #expect(ComposeProjectRef.split(shop.id)?.hostID == host)
    }

    @Test func matchingIgnoresCaseAndNeedsEveryWord() {
        #expect(EntityMatching.matches("Postgres Primary", query: "postgres"))
        #expect(EntityMatching.matches("Postgres Primary", query: "pri post"))
        #expect(!EntityMatching.matches("Postgres Primary", query: "mysql"))
        #expect(EntityMatching.matches("café", query: "CAFE"))
        #expect(EntityMatching.matches("anything", query: "  "))
    }

    @Test func rankingPutsExactAndPrefixFirst() {
        let names = ["my-web", "web-2", "web", "db"]
        #expect(EntityMatching.ranked(names, query: "web") { $0 } == ["web", "web-2", "my-web"])
    }

    @Test func indexPlanCapsAndDeletesWhatIsGone() {
        let plan = SpotlightIndexPlan.make(previous: ["a", "b", "z"], current: ["a", "c", "c", "d"], limit: 2)
        #expect(plan.index == ["a", "c"])
        #expect(plan.delete == ["b", "z"])
    }
}

// MARK: - Browser target

@Suite struct BrowserTargetTests {
    private let web = [PortBinding(ip: "0.0.0.0", privatePort: 80, publicPort: 8080), PortBinding(privatePort: 53, publicPort: 5353, type: "udp")]

    @Test func localUsesLocalhostForWildcardBinds() {
        let host = DockerHost(name: "Local", kind: .local)
        let url = try? BrowserTarget.url(host: host, ports: web, ipAddress: nil, domain: nil, containerName: "web").get()
        #expect(url?.absoluteString == "http://localhost:8080")
    }

    @Test func picksTheLowestContainerPort() {
        let host = DockerHost(name: "Local", kind: .local)
        let ports = [PortBinding(ip: "0.0.0.0", privatePort: 443, publicPort: 8443), PortBinding(ip: "127.0.0.1", privatePort: 80, publicPort: 8080)]
        let url = try? BrowserTarget.url(host: host, ports: ports, ipAddress: nil, domain: nil, containerName: "web").get()
        #expect(url?.absoluteString == "http://127.0.0.1:8080")
    }

    @Test func sshUsesTheServerNameOrAsksForAForward() {
        let host = DockerHost(name: "Box", kind: .ssh(SSHEndpoint(host: "box.lan", port: 22, username: "me")))
        let open = try? BrowserTarget.url(host: host, ports: web, ipAddress: nil, domain: nil, containerName: "web").get()
        #expect(open?.absoluteString == "http://box.lan:8080")
        let loopback = [PortBinding(ip: "127.0.0.1", privatePort: 80, publicPort: 9000)]
        let result = BrowserTarget.url(host: host, ports: loopback, ipAddress: nil, domain: nil, containerName: "web")
        #expect(result == .failure(.needsForward(port: 9000)))
    }

    @Test func appleUsesTheDomainThenTheAddress() {
        let host = DockerHost(name: "Apple", kind: .appleContainer)
        let ports = [PortBinding(privatePort: 3000)]
        let named = try? BrowserTarget.url(host: host, ports: ports, ipAddress: "192.168.64.5", domain: "test", containerName: "api").get()
        #expect(named?.absoluteString == "http://api.test:3000")
        let byIP = try? BrowserTarget.url(host: host, ports: ports, ipAddress: "192.168.64.5", domain: nil, containerName: "api").get()
        #expect(byIP?.absoluteString == "http://192.168.64.5:3000")
    }

    @Test func noPortIsAFailure() {
        let host = DockerHost(name: "Local", kind: .local)
        #expect(BrowserTarget.url(host: host, ports: [], ipAddress: nil, domain: nil, containerName: "x") == .failure(.noPort))
        let apple = DockerHost(name: "Apple", kind: .appleContainer)
        #expect(BrowserTarget.url(host: apple, ports: [PortBinding(privatePort: 80)], ipAddress: nil, domain: nil, containerName: "x") == .failure(.noPort))
    }
}

// MARK: - Snapshot builder and health

@Suite struct FleetSnapshotBuilderTests {
    @Test func buildsTotalsProblemsAndControls() {
        let local = UUID()
        let remote = UUID()
        let apple = UUID()
        let hosts: [FleetSnapshotBuilder.HostInput] = [
            .init(id: local, name: "Local", status: connected(), isAppleContainer: false, containers: [
                container(id: "1", name: "web"),
                container(id: "2", name: "api", status: "Up 3 minutes (unhealthy)"),
                container(id: "3", name: "old", state: "dead", status: "Dead")
            ]),
            .init(id: remote, name: "Box", status: .failed("timeout"), isAppleContainer: false, containers: [container(id: "9", name: "ghost")]),
            .init(id: apple, name: "Apple", status: .disconnected, isAppleContainer: true, containers: [])
        ]
        let now = Date(timeIntervalSince1970: 100)
        let snapshot = FleetSnapshotBuilder.build(hosts: hosts, appleServicesRunning: false, controlToken: "tok", now: now)

        #expect(snapshot.generatedAt == now)
        #expect(snapshot.hostsUp == 1)
        #expect(snapshot.running == 2)
        #expect(snapshot.unhealthy == 1)
        #expect(snapshot.hosts[1].state == .failed)
        #expect(snapshot.hosts[1].running == 0)
        #expect(snapshot.topProblem == .init(kind: .hostFailed, hostID: remote, hostName: "Box", containerName: nil))
        #expect(snapshot.appleServices == .init(running: false))
        #expect(snapshot.controlToken == "tok")
        // Only connected hosts give controls; running containers come first.
        #expect(snapshot.containers.map(\.name) == ["api", "web", "old"])
    }

    @Test func unhealthyWinsOverDeadWhenNoHostFails() {
        let host = UUID()
        let input = FleetSnapshotBuilder.HostInput(id: host, name: "Local", status: connected(), isAppleContainer: false, containers: [
            container(id: "1", name: "gone", state: "dead", status: "Dead"),
            container(id: "2", name: "sick", status: "Up (unhealthy)")
        ])
        let snapshot = FleetSnapshotBuilder.build(hosts: [input], appleServicesRunning: nil, controlToken: "", now: .now)
        #expect(snapshot.topProblem?.kind == .unhealthy)
        #expect(snapshot.topProblem?.containerName == "sick")
        #expect(snapshot.appleServices == nil)
    }

    @Test func healthLevels() {
        #expect(HostHealthSummary(status: .failed("x"), containers: []).level == .down)
        #expect(HostHealthSummary(status: connected(), containers: [container(id: "1", name: "a")]).level == .ok)
        let sick = HostHealthSummary(status: connected(), containers: [container(id: "1", name: "a", status: "Up (unhealthy)")])
        #expect(sick.level == .warning)
        #expect(sick.counts.unhealthy == 1)
    }
}
