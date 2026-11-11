import Foundation
import Testing
@testable import AppCore

struct StatsTimeAxisTests {
    @Test(arguments: [
        (0.0, 5), (1, 5), (10, 5), (15, 5), (16, 10), (30, 10), (45, 15),
        (60, 30), (90, 30), (91, 60), (179, 60), (180, 60), (181, 120),
        (100_000, 3600),
    ])
    func stepFollowsTheSpan(span: TimeInterval, step: Int) {
        #expect(StatsTimeAxis(span: span).stepSeconds == step)
    }

    @Test func aStepGivesAtMostFourLabels() {
        for span in stride(from: 0.0, through: 10_000, by: 7) {
            let axis = StatsTimeAxis(span: span)
            #expect(span / Double(axis.stepSeconds) <= 3, "span \(span)")
        }
    }

    @Test func secondsShowOnlyForShortSteps() {
        #expect(StatsTimeAxis(span: 10).showsSeconds)
        #expect(StatsTimeAxis(span: 60).showsSeconds)
        #expect(StatsTimeAxis(span: 60).stepMinutes == nil)
        #expect(!StatsTimeAxis(span: 180).showsSeconds)
        #expect(StatsTimeAxis(span: 180).stepMinutes == 1)
        #expect(StatsTimeAxis(span: 600).stepMinutes == 5)
    }

    @Test func spanComesFromTheFirstAndLastSample() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(StatsTimeAxis(samplesFrom: start, to: start.addingTimeInterval(60)).stepSeconds == 30)
        #expect(StatsTimeAxis(samplesFrom: nil, to: nil).stepSeconds == 5)
        // A clock that goes back gives the shortest step, not a crash.
        #expect(StatsTimeAxis(samplesFrom: start, to: start.addingTimeInterval(-30)).stepSeconds == 5)
    }
}
