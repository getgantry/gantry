import Foundation
import Testing
@testable import AppCore

struct StatsTimeAxisTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_003)

    @Test(arguments: [
        (0.0, 5), (1, 5), (10, 5), (15, 5), (16, 10), (30, 10), (45, 15),
        (60, 30), (90, 30), (91, 60), (179, 60), (180, 60), (181, 120),
        (100_000, 3600),
    ])
    func stepFollowsTheSpan(span: TimeInterval, step: Int) {
        #expect(StatsTimeAxis(span: span).stepSeconds == step)
    }

    @Test func ticksAreRoundTimesInsideTheSpan() {
        let axis = StatsTimeAxis(from: start, to: start.addingTimeInterval(60))
        #expect(axis.stepSeconds == 30)
        #expect(axis.ticks.map(\.timeIntervalSince1970) == [1_800_000_030, 1_800_000_060])
    }

    @Test func atMostFourTicksAndNoRepeats() {
        for span in stride(from: 0.0, through: 10_000, by: 7) {
            let ticks = StatsTimeAxis(from: start, to: start.addingTimeInterval(span)).ticks
            #expect(ticks.count <= 4, "span \(span)")
            #expect(Set(ticks).count == ticks.count)
            #expect(ticks.allSatisfy { $0 >= start && $0 <= start.addingTimeInterval(span) })
        }
    }

    @Test func tenSecondsGiveAtLeastOneTick() {
        let ticks = StatsTimeAxis(from: start, to: start.addingTimeInterval(10)).ticks
        #expect(ticks.map(\.timeIntervalSince1970) == [1_800_000_005, 1_800_000_010])
    }

    @Test func labelsNearTheEdgesGrowInward() {
        let axis = StatsTimeAxis(from: start, to: start.addingTimeInterval(100))
        #expect(axis.anchor(for: start.addingTimeInterval(5)) == .leading)
        #expect(axis.anchor(for: start.addingTimeInterval(50)) == .center)
        #expect(axis.anchor(for: start.addingTimeInterval(95)) == .trailing)
        #expect(StatsTimeAxis(span: 0).anchor(for: start) == .center)
    }

    @Test func secondsShowOnlyForShortSteps() {
        #expect(StatsTimeAxis(span: 60).showsSeconds)
        #expect(!StatsTimeAxis(span: 180).showsSeconds)
    }

    @Test func aClockThatGoesBackGivesAnEmptySpan() {
        let axis = StatsTimeAxis(from: start, to: start.addingTimeInterval(-30))
        #expect(axis.stepSeconds == 5)
        #expect(axis.end == start)
    }
}
