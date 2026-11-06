import Foundation
import Testing
@testable import AppCore
import DockerKit

@Suite struct ContainerCountsTests {
    private func container(_ id: String, state: String, status: String = "", extra: String = "") throws -> ContainerSummary {
        let json = #"{"Id":"\#(id)","Names":["/\#(id)"],"Image":"nginx","State":"\#(state)","Status":"\#(status)"\#(extra)}"#
        return try JSONDecoder().decode(ContainerSummary.self, from: Data(json.utf8))
    }

    @Test func countsEveryState() throws {
        let counts = ContainerCounts([
            try container("a", state: "running", status: "Up 2 minutes (healthy)"),
            try container("b", state: "running", status: "Up 1 minute (unhealthy)"),
            try container("c", state: "paused"),
            try container("d", state: "exited"),
            try container("e", state: "created"),
            try container("f", state: "restarting"),
            try container("g", state: "dead")
        ])
        #expect(counts.running == 2)
        #expect(counts.unhealthy == 1)
        #expect(counts.healthy == 1)
        #expect(counts.paused == 1)
        #expect(counts.stopped == 4)
        #expect(counts.restarting == 1)
        #expect(counts.dead == 1)
        #expect(counts.attention == 3)
        #expect(counts.total == 7)
    }

    @Test func skipsTheBuilderAndDebugSidecars() throws {
        let builder = try container(
            "buildkit", state: "running",
            extra: #","Labels":{"com.apple.container.resource.role":"builder"}"#
        )
        let sidecar = try container("gantry-debug-web", state: "running")
        let mine = try container("web", state: "running")
        let counts = ContainerCounts([builder, sidecar, mine])
        #expect(counts.running == 1)
        #expect(counts.total == 1)
    }

    @Test func sumsAcrossHosts() throws {
        let one = ContainerCounts([try container("a", state: "running")])
        let two = ContainerCounts([try container("b", state: "exited"), try container("c", state: "running")])
        let sum = one + two
        #expect(sum.running == 2)
        #expect(sum.stopped == 1)
    }
}

@Suite struct CountPhrasesTests {
    private let english = Locale(identifier: "en")

    @Test func singularAndPlural() {
        #expect(CountPhrases.containers(1, locale: english) == "1 container")
        #expect(CountPhrases.containers(2, locale: english) == "2 containers")
        #expect(CountPhrases.containers(0, locale: english) == "0 containers")
        #expect(CountPhrases.hosts(1, locale: english) == "1 host")
        #expect(CountPhrases.services(3, locale: english) == "3 services")
    }

    @Test func twoPluralsInOneSentence() {
        #expect(CountPhrases.runningAcrossHosts(running: 1, hosts: 1, locale: english)
            == "1 container running across 1 host.")
        #expect(CountPhrases.runningAcrossHosts(running: 3, hosts: 2, locale: english)
            == "3 containers running across 2 hosts.")
        #expect(CountPhrases.runningOnHosts(running: 1, hosts: 1, locale: english) == "1 running · 1 host")
        #expect(CountPhrases.runningOnHosts(running: 4, hosts: 2, locale: english) == "4 running · 2 hosts")
    }
}
