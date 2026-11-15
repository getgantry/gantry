import Foundation
import Testing
@testable import DockerKit

@Suite("buildx history parser")
struct BuildxHistoryTests {
    @Test func listLinesFromBuildx0291() throws {
        let records = try BuildxHistoryParser.records(from: BuildHistoryFixtures.buildxList)
        #expect(records.count == 3)
        let failed = try #require(records.first)
        #expect(failed.ref == "default/default/o4kn3a8tluispaxrrvdsh5ypt")
        #expect(failed.id == "o4kn3a8tluispaxrrvdsh5ypt")
        #expect(failed.name == "w/Dockerfile.fail")
        #expect(failed.status == "Error")
        #expect(failed.totalSteps == 6)
        #expect(failed.cachedSteps == 1)
        #expect(failed.completedSteps == 6)
        let started = try #require(failed.createdAt)
        let ended = try #require(failed.completedAt)
        #expect(abs(ended.timeIntervalSince(started) - 0.255) < 0.002)
        #expect(records[1].cachedSteps == 3)
        #expect(records[2].status == "Completed")
    }

    @Test func listArrayWithCamelCaseKeys() throws {
        let text = #"[{"ID":"qu2gsuo8ejqrwdfii23xkkckt","Name":"buildx","Status":"Completed","CreatedAt":"2025-01-24T11:05:47Z","Duration":"2.1s"}]"#
        let records = try BuildxHistoryParser.records(from: text)
        #expect(records.count == 1)
        #expect(records[0].id == "qu2gsuo8ejqrwdfii23xkkckt")
        #expect(records[0].status == "Completed")
        #expect(records[0].createdAt != nil)
        #expect(records[0].totalSteps == nil)
    }

    @Test func emptyListHasNoRecords() throws {
        #expect(try BuildxHistoryParser.records(from: "\n").isEmpty)
    }

    @Test func garbageThrows() {
        #expect(throws: DockerError.self) { try BuildxHistoryParser.records(from: "ERROR: something") }
    }

    @Test func inspectOfTheFailedBuild() throws {
        let inspect = try BuildxHistoryParser.inspect(from: BuildHistoryFixtures.buildxInspectFailed)
        #expect(inspect.name == "w/Dockerfile.fail")
        #expect(inspect.dockerfile == "Dockerfile.fail")
        #expect(inspect.context == "w")
        #expect(inspect.status == "failed")
        #expect(inspect.errorStep == "[3/3] RUN exit 3")
        #expect(inspect.errorMessage == #"process "/bin/sh -c exit 3" did not complete successfully: exit code: 3"#)
        #expect(inspect.startedAt != nil)
    }

    @Test func inspectOfASucceededBuildHasNoError() throws {
        let inspect = try BuildxHistoryParser.inspect(from: BuildHistoryFixtures.buildxInspectFirst)
        #expect(inspect.errorMessage == nil)
        #expect(inspect.status == "completed")
    }

    @Test func versionFromBuildxVersion() {
        #expect(BuildxHistoryParser.version(from: BuildHistoryFixtures.buildxVersion) == "0.29.1")
        #expect(BuildxHistoryParser.version(from: "github.com/docker/buildx 0.12.1+ds1 0.12.1+ds1-1") == "0.12.1")
        #expect(BuildxHistoryParser.version(from: "docker: 'buildx' is not a docker command.") == nil)
    }

    @Test(arguments: [("0.22.9", false), ("0.23.0", true), ("0.29.1", true), ("1.0", true), ("0.9.1", false)])
    func versionGate(version: String, supported: Bool) {
        #expect(BuildxHistoryParser.isSupported(version) == supported)
    }

    @Test func nanosecondDates() throws {
        let date = try #require(BuildxHistoryParser.date("2026-11-14T15:43:05.578935175Z"))
        let plain = try #require(BuildxHistoryParser.date("2026-11-14T15:43:05Z"))
        #expect(abs(date.timeIntervalSince(plain) - 0.578) < 0.001)
    }
}
