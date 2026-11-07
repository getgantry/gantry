import Foundation
import Testing
@testable import AppCore

@Suite struct LoadMathTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func counters(
        at seconds: TimeInterval, cpu: Int64, system: Int64, online: Int = 2, mem: Int64 = 100,
        rx: Int64 = 0, tx: Int64 = 0, read: Int64 = 0, write: Int64 = 0
    ) -> ContainerCounters {
        ContainerCounters(
            date: t0.addingTimeInterval(seconds), cpuTotal: cpu, systemCPU: system, onlineCPUs: online,
            memoryBytes: mem, networkRx: rx, networkTx: tx, blockRead: read, blockWrite: write
        )
    }

    @Test func firstReadingHasNoRates() {
        let point = LoadMath.point(previous: nil, current: counters(at: 0, cpu: 500, system: 1000, rx: 9000))
        #expect(point.cpuPercent == 0)
        #expect(point.networkRate == 0)
        #expect(point.memoryBytes == 100)
    }

    @Test func cpuAndRatesFromDeltas() {
        let old = counters(at: 0, cpu: 1000, system: 10000, rx: 1000, tx: 0, read: 0, write: 500)
        let new = counters(at: 5, cpu: 3000, system: 20000, mem: 600, rx: 6000, tx: 2500, read: 5000, write: 500)
        let point = LoadMath.point(previous: old, current: new)
        #expect(point.cpuPercent == 40)
        #expect(point.memoryBytes == 600)
        #expect(point.networkInRate == 1000)
        #expect(point.networkOutRate == 500)
        #expect(point.diskReadRate == 1000)
        #expect(point.diskWriteRate == 0)
    }

    @Test func counterResetGivesZeroNotNegative() {
        let old = counters(at: 0, cpu: 5000, system: 10000, rx: 9000)
        let new = counters(at: 5, cpu: 100, system: 20000, rx: 10)
        let point = LoadMath.point(previous: old, current: new)
        #expect(point.cpuPercent == 0)
        #expect(point.networkInRate == 0)
    }

    @Test func sameInstantHasNoRates() {
        let old = counters(at: 0, cpu: 0, system: 0, rx: 0)
        let new = counters(at: 0, cpu: 10, system: 100, rx: 500)
        let point = LoadMath.point(previous: old, current: new)
        #expect(point.networkInRate == 0)
        #expect(point.cpuPercent == 20)
    }

    @Test func totalAddsEveryField() {
        let a = ContainerLoadPoint(date: t0, cpuPercent: 10, memoryBytes: 100, networkInRate: 1, networkOutRate: 2, diskReadRate: 3, diskWriteRate: 4)
        let b = ContainerLoadPoint(date: t0, cpuPercent: 5, memoryBytes: 50, networkInRate: 1, networkOutRate: 1, diskReadRate: 1, diskWriteRate: 1)
        let sum = LoadMath.total([a, b], date: t0)
        #expect(sum.cpuPercent == 15)
        #expect(sum.memoryBytes == 150)
        #expect(sum.networkRate == 5)
        #expect(sum.diskRate == 9)
    }
}

@Suite struct ContainerLoadHistoryTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func point(_ cpu: Double, mem: Int64 = 0) -> ContainerLoadPoint {
        ContainerLoadPoint(date: t0, cpuPercent: cpu, memoryBytes: mem)
    }

    @Test func keepsAtMostCapacityPoints() {
        var history = ContainerLoadHistory(capacity: 3)
        for i in 0..<5 { history.record(["a": point(Double(i))]) }
        #expect(history.history("a").map(\.cpuPercent) == [2, 3, 4])
        #expect(history.latest("a")?.cpuPercent == 4)
    }

    @Test func dropsContainersThatAreGone() {
        var history = ContainerLoadHistory()
        history.record(["a": point(1), "b": point(2)])
        history.record(["b": point(3)])
        #expect(history.history("a").isEmpty)
        #expect(history.history("b").count == 2)
        history.record([:])
        #expect(history.series.isEmpty)
    }

    @Test func topSortsByLatestValueWithStableTies() {
        var history = ContainerLoadHistory()
        history.record(["a": point(5, mem: 10), "b": point(50, mem: 5), "c": point(5, mem: 99)])
        #expect(history.top(by: .cpu, limit: 2).map(\.id) == ["b", "a"])
        #expect(history.top(by: .memory, limit: 5).map(\.id) == ["c", "a", "b"])
        #expect(history.top(by: .cpu, limit: 0).isEmpty)
    }

    @Test func zeroCapacityStillKeepsOnePoint() {
        var history = ContainerLoadHistory(capacity: 0)
        history.record(["a": point(1)])
        history.record(["a": point(2)])
        #expect(history.history("a").map(\.cpuPercent) == [2])
    }
}

@Suite struct MetricSummaryTests {
    @Test func emptySeriesHasNoSummary() {
        #expect(MetricSummary([]) == nil)
    }

    @Test func latestAverageAndPeak() throws {
        let summary = try #require(MetricSummary([1, 5, 3]))
        #expect(summary.latest == 3)
        #expect(summary.average == 3)
        #expect(summary.peak == 5)
    }

    @Test func domainUpperBoundHasHeadroomAndMinimum() {
        #expect(MetricSummary.domainUpperBound([], minimum: 1024) == 1024)
        #expect(MetricSummary.domainUpperBound([10_000], minimum: 1024) == 12_000)
    }
}
