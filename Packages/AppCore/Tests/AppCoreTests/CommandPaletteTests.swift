import Foundation
import Testing
@testable import AppCore
import DockerKit

@Suite struct FuzzyMatchTests {
    @Test func emptyQueryMatchesEverything() {
        #expect(FuzzyMatch.score("", in: "nginx") == 0)
    }

    @Test func subsequenceMatchesInOrderOnly() {
        #expect(FuzzyMatch.score("ngx", in: "nginx") != nil)
        #expect(FuzzyMatch.score("xgn", in: "nginx") == nil)
        #expect(FuzzyMatch.score("nginxx", in: "nginx") == nil)
    }

    @Test func ignoresCaseAndDiacritics() {
        #expect(FuzzyMatch.score("CAFE", in: "café-api") != nil)
        #expect(FuzzyMatch.score("café", in: "CAFE") != nil)
    }

    @Test func exactBeatsPrefixBeatsSubstringBeatsScattered() throws {
        let exact = try #require(FuzzyMatch.score("web", in: "web"))
        let prefix = try #require(FuzzyMatch.score("web", in: "webapp"))
        let substring = try #require(FuzzyMatch.score("web", in: "my-web"))
        let scattered = try #require(FuzzyMatch.score("web", in: "wide-label"))
        #expect(exact > prefix)
        #expect(prefix > substring)
        #expect(substring > scattered)
    }

    @Test func wordStartsBeatMidWordMatches() throws {
        let camel = try #require(FuzzyMatch.score("mc", in: "myCache"))
        let plain = try #require(FuzzyMatch.score("mc", in: "mxxxxcache"))
        #expect(camel > plain)
    }

    @Test func picksTheBestStartPosition() throws {
        // The first "a" is mid-word; the later one starts a word.
        let score = try #require(FuzzyMatch.score("ap", in: "data-api"))
        let worse = try #require(FuzzyMatch.score("ap", in: "daxxxxxp"))
        #expect(score > worse)
    }

    @Test func bestScoreTakesTheMaximum() {
        #expect(FuzzyMatch.bestScore("redis", in: ["nginx", "redis"]) == FuzzyMatch.score("redis", in: "redis"))
        #expect(FuzzyMatch.bestScore("zzz", in: ["nginx", "redis"]) == nil)
    }
}

@Suite struct PaletteRankerTests {
    private let hostA = UUID()
    private let hostB = UUID()

    private func item(_ kind: PaletteKind, _ title: String, host: UUID? = nil, hostName: String? = nil, keywords: [String] = []) -> PaletteItem {
        PaletteItem(kind: kind, title: title, hostID: host, hostName: hostName, target: title, keywords: keywords)
    }

    @Test func emptyQueryListsRecentsThenCommandsHostsSections() {
        let web = item(.container, "web", host: hostA)
        let db = item(.container, "db", host: hostA)
        let addHost = item(.command, "Add Host…")
        let host = item(.host, "Local")
        let section = item(.section, "Images", host: hostA)
        let ranked = PaletteRanker.rank([section, web, host, db, addHost], query: "  ", recents: [db.id, web.id])
        #expect(ranked.map(\.id) == [db.id, web.id, addHost.id, host.id, section.id])
    }

    @Test func recentsThatNoLongerExistAreSkipped() {
        let web = item(.container, "web", host: hostA)
        let ranked = PaletteRanker.rank([web], query: "", recents: ["container:gone:x", web.id])
        #expect(ranked.map(\.id) == [web.id])
    }

    @Test func titleMatchOutranksKeywordMatch() {
        let byTitle = item(.container, "redis", host: hostA)
        let byImage = item(.container, "cache", host: hostA, keywords: ["redis:7"])
        let ranked = PaletteRanker.rank([byImage, byTitle], query: "redis")
        #expect(ranked.map(\.title) == ["redis", "cache"])
    }

    @Test func everyWordMustMatchAndHostNameCounts() {
        let onProd = item(.container, "web", host: hostA, hostName: "prod")
        let onDev = item(.container, "web", host: hostB, hostName: "dev")
        let ranked = PaletteRanker.rank([onDev, onProd], query: "web prod")
        #expect(ranked.map(\.id) == [onProd.id])
    }

    @Test func kindNameMatches() {
        let volume = item(.volume, "data", host: hostA)
        let container = item(.container, "data", host: hostA)
        let ranked = PaletteRanker.rank([container, volume], query: "data volume")
        #expect(ranked.first?.id == volume.id)
    }

    @Test func recentItemWinsATie() {
        let first = item(.container, "api-1", host: hostA)
        let second = item(.container, "api-2", host: hostA)
        let ranked = PaletteRanker.rank([first, second], query: "api", recents: [second.id])
        #expect(ranked.first?.id == second.id)
    }

    @Test func tiesPreferKindThenShorterTitle() {
        let image = item(.image, "nginx", host: hostA)
        let container = item(.container, "nginx", host: hostA)
        let longer = item(.container, "nginx-proxy", host: hostA)
        let ranked = PaletteRanker.rank([longer, image, container], query: "ngin")
        #expect(ranked.map(\.id) == [container.id, longer.id, image.id])
    }

    @Test func respectsTheLimit() {
        let items = (0..<100).map { item(.container, "box\($0)", host: hostA) }
        #expect(PaletteRanker.rank(items, query: "box", limit: 10).count == 10)
    }

    @Test func noMatchGivesNoResults() {
        #expect(PaletteRanker.rank([item(.container, "web")], query: "qqq").isEmpty)
    }
}

@Suite struct PaletteRecentsTests {
    @Test func recordMovesToFrontAndDeduplicates() {
        var recents = PaletteRecents(ids: ["a", "b", "c"])
        recents.record("c")
        #expect(recents.ids == ["c", "a", "b"])
        recents.record("d")
        #expect(recents.ids == ["d", "c", "a", "b"])
    }

    @Test func keepsAtMostTheLimit() {
        var recents = PaletteRecents()
        for index in 0..<30 { recents.record("\(index)") }
        #expect(recents.ids.count == PaletteRecents.limit)
        #expect(recents.ids.first == "29")
    }

    @Test func roundTripsThroughDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "palette-tests-\(UUID().uuidString)"))
        var recents = PaletteRecents()
        recents.record("x")
        recents.record("y")
        recents.save(to: defaults)
        #expect(PaletteRecents.load(from: defaults).ids == ["y", "x"])
    }
}

@Suite struct PaletteCatalogTests {
    private let host = PaletteCatalog.Host(id: UUID(), name: "Local", isAppleContainer: false, isConnected: true)

    private func container(_ name: String, state: String, project: String? = nil, service: String? = nil) throws -> ContainerSummary {
        var labels: [String] = []
        if let project { labels.append(#""com.docker.compose.project":"\#(project)""#) }
        if let service { labels.append(#""com.docker.compose.service":"\#(service)""#) }
        let json = #"{"Id":"id-\#(name)","Names":["/\#(name)"],"Image":"nginx:latest","State":"\#(state)","Labels":{\#(labels.joined(separator: ","))}}"#
        return try JSONDecoder().decode(ContainerSummary.self, from: Data(json.utf8))
    }

    private func network(_ name: String) throws -> NetworkResource {
        let json = #"{"Id":"net-\#(name)","Name":"\#(name)","Driver":"bridge"}"#
        return try JSONDecoder().decode(NetworkResource.self, from: Data(json.utf8))
    }

    @Test func containerActionsFollowState() {
        #expect(PaletteCatalog.containerActions(.running) == [.open, .logs, .shell, .stop, .restart, .remove])
        #expect(PaletteCatalog.containerActions(.exited) == [.open, .start, .logs, .remove])
        #expect(PaletteCatalog.containerActions(.paused).contains(.shell) == false)
        #expect(PaletteCatalog.containerActions(.removing) == [.open])
    }

    @Test func composeActionsFollowRunningCount() {
        #expect(PaletteCatalog.composeActions(running: 0, total: 2) == [.open, .start])
        #expect(PaletteCatalog.composeActions(running: 2, total: 2) == [.open, .stop, .restart])
        #expect(PaletteCatalog.composeActions(running: 1, total: 2) == [.open, .start, .stop, .restart])
    }

    @Test func machineActionsFollowState() {
        #expect(PaletteCatalog.machineActions(isRunning: true) == [.open, .stop, .remove])
        #expect(PaletteCatalog.machineActions(isRunning: false) == [.open, .start, .remove])
    }

    @Test func buildsContainersAndComposeProjects() throws {
        let items = PaletteCatalog.items(host: host, containers: [
            try container("shop-web-1", state: "running", project: "shop", service: "web"),
            try container("shop-db-1", state: "exited", project: "shop", service: "db"),
            try container("solo", state: "exited")
        ])
        let containers = items.filter { $0.kind == .container }
        #expect(containers.count == 3)
        let web = try #require(containers.first { $0.title == "shop-web-1" })
        #expect(web.hostName == "Local")
        #expect(web.hostID == host.id)
        #expect(web.target == "id-shop-web-1")
        #expect(web.isActive == true)
        #expect(web.keywords.contains("web"))
        #expect(web.keywords.contains("nginx:latest"))

        let projects = items.filter { $0.kind == .composeProject }
        #expect(projects.map(\.title) == ["shop"])
        #expect(projects.first?.actions == [.open, .start, .stop, .restart])
        #expect(projects.first?.keywords.sorted() == ["db", "web"])
    }

    @Test func builtInNetworksCannotBeRemoved() throws {
        let items = PaletteCatalog.items(host: host, networks: [try network("bridge"), try network("backend")])
        #expect(items.first { $0.title == "bridge" }?.actions == [.open])
        #expect(items.first { $0.title == "backend" }?.actions == [.open, .remove])
    }

    @Test func disconnectedHostGivesNoResources() throws {
        let down = PaletteCatalog.Host(id: UUID(), name: "Down", isAppleContainer: false, isConnected: false)
        #expect(PaletteCatalog.items(host: down, containers: [try container("a", state: "running")]).isEmpty)
    }

    @Test func machinesAndClustersOnlyOnAppleHosts() {
        let machine = ContainerMachine(id: "dev", status: "running")
        let cluster = ContainerCluster(name: "k", nodes: [])
        #expect(PaletteCatalog.items(host: host, machines: [machine], clusters: [cluster]).isEmpty)
        let apple = PaletteCatalog.Host(id: UUID(), name: "Mac", isAppleContainer: true, isConnected: true)
        let items = PaletteCatalog.items(host: apple, machines: [machine], clusters: [cluster])
        #expect(items.map(\.kind) == [.machine, .cluster])
        #expect(items.first?.actions == [.open, .stop, .remove])
    }

    @Test func itemIDsAreStable() {
        let first = PaletteItem(kind: .container, title: "a", hostID: host.id, target: "x")
        let second = PaletteItem(kind: .container, title: "renamed", hostID: host.id, target: "x")
        #expect(first.id == second.id)
        #expect(first.defaultAction == .open)
        #expect(PaletteItem(kind: .command, title: "c", target: "c", actions: []).actions == [.open])
    }
}
