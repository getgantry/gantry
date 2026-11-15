import Foundation
import Testing
@testable import AppCore

@MainActor
@Suite struct MenuBarActivityTests {
    @Test func emptyCenterHidesTheSection() {
        let activity = MenuBarActivity(center: OperationCenter(), now: Date())
        #expect(!activity.isVisible)
        #expect(activity.runningCount == 0)
        #expect(MenuBarActivity.menuBarLabel(runningCount: 0) == "Gantry")
    }

    @Test func runningNewestFirstWithLimit() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let center = OperationCenter(now: { clock })
        for index in 1...7 {
            center.begin(.pull, title: "op\(index)")
            clock += 1
        }
        let activity = MenuBarActivity(center: center, now: clock)
        #expect(activity.running.map(\.title) == ["op7", "op6", "op5", "op4", "op3"])
        #expect(activity.hiddenRunning == 2)
        #expect(activity.runningCount == 7)
        #expect(MenuBarActivity.menuBarLabel(runningCount: 7) == "Gantry, running operations: 7")
    }

    @Test func recentShowsOnlyTheLastTenMinutes() {
        var clock = Date(timeIntervalSince1970: 0)
        let center = OperationCenter(now: { clock })
        let old = center.begin(.build, title: "old")
        let fresh = center.begin(.composeDown, title: "fresh")
        let failed = center.begin(.pull, title: "failed")
        center.finish(old, .succeeded(nil))
        clock += 300
        center.finish(fresh, .cancelled)
        clock += 100
        center.finish(failed, .failed("no space"))
        clock += 301
        let activity = MenuBarActivity(center: center, now: clock)
        #expect(activity.recent.map(\.title) == ["failed", "fresh"])
        #expect(activity.running.isEmpty)
        #expect(activity.isVisible)
    }

    @Test func recentIsLimited() {
        var clock = Date(timeIntervalSince1970: 0)
        let center = OperationCenter(now: { clock })
        for index in 1...5 {
            let operation = center.begin(.pull, title: "op\(index)")
            clock += 1
            center.finish(operation, .succeeded(nil))
        }
        #expect(MenuBarActivity(center: center, now: clock).recent.map(\.title) == ["op5", "op4", "op3"])
    }

    @Test func elapsedText() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(MenuBarActivity.elapsed(from: start, to: start + 42) == "0:42")
        #expect(MenuBarActivity.elapsed(from: start, to: start + 725) == "12:05")
        #expect(MenuBarActivity.elapsed(from: start, to: start + 3723) == "1:02:03")
        #expect(MenuBarActivity.elapsed(from: start + 10, to: start) == "0:00")
    }
}
