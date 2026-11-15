import Foundation
import Testing
@testable import DockerKit

@Suite("Build progress parser")
struct BuildProgressTests {
    /// The text that Gantry logs from a classic `/build` stream.
    private func classicLog(_ stream: String) -> (log: String, failed: Bool) {
        var log = ""
        var failed = false
        for line in stream.split(separator: "\n") {
            guard let decoded = try? JSONDecoder().decode(BuildResponseLine.self, from: Data(line.utf8)),
                  let logLine = decoded.asLogLine() else { continue }
            if logLine.isError { failed = true } else { log += logLine.text }
        }
        return (log, failed)
    }

    @Test func appleFirstBuildRunsEachStep() {
        let steps = BuildProgressParser.steps(fromLog: BuildHistoryFixtures.appleFirst)
        #expect(steps.count == 9)
        #expect(BuildStepSummary(steps).cached == 0)
        let dockerfile = steps.filter { !$0.isInternal }
        #expect(dockerfile.map(\.name) == [
            "[linux/arm64 1/4] RUN echo one > /one",
            "[linux/arm64 2/4] COPY Dockerfile /Dockerfile",
            "[linux/arm64 3/4] RUN echo two > /two"
        ])
        #expect(dockerfile.allSatisfy { $0.state == .run })
        #expect(steps.first { $0.number == 5 }?.duration == 0.2)
    }

    @Test func appleCachedBuildMarksCachedSteps() {
        let steps = BuildProgressParser.steps(fromLog: BuildHistoryFixtures.appleCached)
        let summary = BuildStepSummary(steps)
        #expect(summary.total == 9)
        #expect(summary.cached == 3)
        #expect(steps.filter { !$0.isInternal }.allSatisfy { $0.state == .cached })
    }

    @Test func appleFailedBuildMarksTheFailedStep() {
        let steps = BuildProgressParser.steps(fromLog: BuildHistoryFixtures.appleFailed, failed: true)
        #expect(steps.count == 6)
        let failed = steps.filter { $0.state == .failed }
        #expect(failed.map(\.name) == ["[linux/arm64 2/3] RUN exit 3"])
        #expect(steps.first { $0.name.contains("1/3") }?.state == .cached)
    }

    @Test(arguments: [
        (BuildHistoryFixtures.buildxLogsFirst, 9, 0),
        (BuildHistoryFixtures.buildxLogsCached, 9, 3),
        (BuildHistoryFixtures.buildxLogsFailed, 6, 1)
    ])
    func buildxLogsGiveTheCountsOfHistoryList(log: String, total: Int, cached: Int) {
        let summary = BuildStepSummary(BuildProgressParser.steps(fromLog: log))
        #expect(summary.total == total)
        #expect(summary.cached == cached)
    }

    @Test func buildxFailedLogMarksTheStep() {
        let steps = BuildProgressParser.steps(fromLog: BuildHistoryFixtures.buildxLogsFailed)
        #expect(steps.last?.name == "[3/3] RUN exit 3")
        #expect(steps.last?.state == .failed)
    }

    @Test func classicFirstBuildRunsEachStep() {
        let (log, failed) = classicLog(BuildHistoryFixtures.classicFirstStream)
        let steps = BuildProgressParser.steps(fromLog: log, failed: failed)
        #expect(steps.map(\.name) == [
            "FROM alpine:3.20", "RUN echo one > /one", "COPY Dockerfile /Dockerfile", "RUN echo two > /two"
        ])
        #expect(steps.allSatisfy { $0.state == .run && !$0.isInternal })
    }

    @Test func classicCachedBuildMarksCachedSteps() {
        let (log, failed) = classicLog(BuildHistoryFixtures.classicCachedStream)
        let steps = BuildProgressParser.steps(fromLog: log, failed: failed)
        #expect(steps.map(\.state) == [.run, .cached, .cached, .cached])
    }

    @Test func classicFailedBuildMarksTheLastStep() {
        let (log, failed) = classicLog(BuildHistoryFixtures.classicFailedStream)
        #expect(failed)
        let steps = BuildProgressParser.steps(fromLog: log, failed: failed)
        #expect(steps.map(\.state) == [.run, .cached, .failed])
        #expect(steps.last?.name == "RUN exit 3")
    }

    @Test func emptyLogHasNoSteps() {
        #expect(BuildProgressParser.steps(fromLog: "").isEmpty)
        #expect(BuildProgressParser.steps(fromLog: "Build complete.\n", failed: true).isEmpty)
    }

    @Test func dockerfileStepNames() {
        #expect(BuildProgressParser.isDockerfileStep("[2/4] RUN x"))
        #expect(BuildProgressParser.isDockerfileStep("[linux/arm64 2/4] RUN x"))
        #expect(BuildProgressParser.isDockerfileStep("[builder 1/3] FROM golang"))
        #expect(!BuildProgressParser.isDockerfileStep("[internal] load build context"))
        #expect(!BuildProgressParser.isDockerfileStep("exporting to image"))
    }
}
