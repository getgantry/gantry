import Foundation
import Testing
@testable import AppCore
import DockerKit

/// The Docker 29.6.2 diff of an alpine container on nettop (see the DockerKit
/// fixture): `/tmp/a` added, `/etc/profile` changed, `/etc/motd` deleted.
private let fixture: [ContainerChange] = [
    .init(path: "/etc", kind: .changed), .init(path: "/etc/profile", kind: .changed),
    .init(path: "/etc/motd", kind: .deleted), .init(path: "/opt", kind: .changed),
    .init(path: "/opt/new", kind: .added), .init(path: "/opt/new/sub", kind: .added),
    .init(path: "/opt/new/sub/f", kind: .added), .init(path: "/tmp", kind: .changed),
    .init(path: "/tmp/a", kind: .added)
]

@Suite struct ContainerChangesTests {
    private let all = Set(ContainerChange.Kind.allCases)

    @Test func countsEachKind() {
        let counts = ContainerChanges.Counts(fixture)
        #expect(counts == .init(added: 4, changed: 4, deleted: 1))
        #expect(counts.total == 9)
        #expect(counts.count(of: .deleted) == 1)
    }

    @Test func filterByKindAndSearchSortsByPath() {
        let added = ContainerChanges.filtered(fixture, kinds: [.added], search: "")
        #expect(added.map(\.path) == ["/opt/new", "/opt/new/sub", "/opt/new/sub/f", "/tmp/a"])
        let etc = ContainerChanges.filtered(fixture, kinds: all, search: "  ETC ")
        #expect(etc.map(\.path) == ["/etc", "/etc/motd", "/etc/profile"])
        #expect(ContainerChanges.filtered(fixture, kinds: [], search: "").isEmpty)
    }

    @Test func treeNestsPathsAndKeepsKinds() throws {
        let tree = ContainerChanges.tree(ContainerChanges.filtered(fixture, kinds: all, search: ""))
        #expect(tree.map(\.name) == ["etc", "opt", "tmp"])
        let etc = try #require(tree.first)
        #expect(etc.kind == .changed)
        #expect(etc.children?.map(\.name) == ["motd", "profile"])
        #expect(etc.children?.first?.kind == .deleted)
        #expect(etc.children?.first?.children == nil)
        let sub = try #require(tree[1].children?.first?.children?.first)
        #expect(sub.id == "/opt/new/sub")
        #expect(sub.children?.first?.id == "/opt/new/sub/f")
    }

    @Test func treeKeepsParentsThatTheFilterDropped() throws {
        // Only "added": /opt and /tmp are changed, so they have no kind.
        let tree = ContainerChanges.tree(ContainerChanges.filtered(fixture, kinds: [.added], search: ""))
        #expect(tree.map(\.name) == ["opt", "tmp"])
        #expect(tree[0].kind == nil)
        #expect(tree[1].children?.first?.kind == .added)
    }

    @Test func treeLimitsEachLevelWithAMoreRow() throws {
        let many = (0..<5).map { ContainerChange(path: "/d/f\($0)", kind: .added) }
        let tree = ContainerChanges.tree(many, limit: 3)
        let children = try #require(tree.first?.children)
        #expect(children.count == 4)
        #expect(children.prefix(3).allSatisfy { !$0.isMoreRow })
        #expect(children.last?.hiddenCount == 2)
        #expect(Set(children.map(\.id)).count == 4)
    }

    @Test func pageLimitsRows() {
        let page = ContainerChanges.page(Array(0..<10), limit: 4)
        #expect(page.rows == [0, 1, 2, 3])
        #expect(page.hidden == 6)
        #expect(ContainerChanges.page([1, 2], limit: 4).hidden == 0)
    }

    @Test func prepareLimitsTheFlatListOfALargeDiff() async {
        // SC-003: 50,000 entries, filtered and paged off the main actor.
        let large = (0..<50_000).map {
            ContainerChange(path: "/var/cache/pkg\($0 % 50)/file\($0)", kind: ContainerChange.Kind(rawValue: $0 % 3)!)
        }
        let clock = ContinuousClock()
        let start = clock.now
        let flat = await ContainerChanges.prepare(large, kinds: all, search: "", asTree: false)
        let elapsed = clock.now - start
        #expect(flat.matchCount == 50_000)
        #expect(flat.flat.count == ContainerChanges.rowLimit)
        #expect(flat.hidden == 50_000 - ContainerChanges.rowLimit)
        #expect(elapsed < .seconds(2))

        let tree = await ContainerChanges.prepare(large, kinds: [.added], search: "pkg7", asTree: true)
        #expect(tree.tree.first?.name == "var")
        #expect(tree.matchCount > 0)
    }

    @Test func kindsByPathMapsEachPath() {
        let map = ContainerChanges.kindsByPath(fixture)
        #expect(map["/tmp/a"] == .added)
        #expect(map["/etc"] == .changed)
        #expect(map["/nope"] == nil)
    }
}
