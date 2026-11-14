import Foundation
import Testing
@testable import AppCore
import DockerKit

/// Answers `docker` commands from a table and records them.
private final class FakeDockerCLI: DockerCLIRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: Result<DockerCLIResult, Error>] = [:]
    private(set) var calls: [[String]] = []

    func on(_ arguments: [String], _ result: DockerCLIResult) { answers[arguments.joined(separator: " ")] = .success(result) }
    func on(_ arguments: [String], throwing error: Error) { answers[arguments.joined(separator: " ")] = .failure(error) }

    func run(_ arguments: [String]) async throws -> DockerCLIResult {
        let answer = lock.withLock { () -> Result<DockerCLIResult, Error>? in
            calls.append(arguments)
            return answers[arguments.joined(separator: " ")]
        }
        guard let answer else { return DockerCLIResult(exitCode: 1, stdout: "", stderr: "unexpected") }
        return try answer.get()
    }
}

private let lsLines = """
{"cached_steps":1,"completed_at":"2026-11-14T15:43:05.578935175Z","completed_steps":6,"created_at":"2026-11-14T15:43:05.323942383Z","name":"w/Dockerfile.fail","ref":"default/default/o4kn3a8tluispaxrrvdsh5ypt","status":"Error","total_steps":6}
{"cached_steps":3,"completed_at":"2026-11-14T15:43:05.289937508Z","completed_steps":9,"created_at":"2026-11-14T15:43:05.065933883Z","name":"w","ref":"default/default/27e2j9dcpfc732x57g9lvkzol","status":"Completed","total_steps":9}
"""

private let inspectFailed = """
{"Name":"w/Dockerfile.fail","Ref":"o4kn3a8tluispaxrrvdsh5ypt","Context":"w","Dockerfile":"Dockerfile.fail","StartedAt":"2026-11-14T15:43:05.323942383Z","CompletedAt":"2026-11-14T15:43:05.578935175Z","Status":"failed","Error":{"Code":2,"Message":"process \\"/bin/sh -c exit 3\\" did not complete successfully: exit code: 3","Name":"[3/3] RUN exit 3"}}
"""

private let logsFailed = """
#1 [internal] load build definition from Dockerfile.fail
#1 DONE 0.0s

#5 [2/3] RUN echo one > /one
#5 CACHED

#6 [3/3] RUN exit 3
#6 ERROR: process "/bin/sh -c exit 3" did not complete successfully: exit code: 3
"""

@Suite struct BuildxHistoryServiceTests {
    private let version = ["buildx", "version"]
    private let list = ["buildx", "history", "ls", "--format", "json", "--no-trunc"]

    @Test func noRunnerMeansNoCLI() async {
        #expect(await BuildxHistoryService.availability(runner: nil) == .noDockerCLI)
    }

    @Test func missingExecutableMeansNoCLI() async {
        let cli = FakeDockerCLI()
        cli.on(version, throwing: DockerCLIMissing())
        #expect(await BuildxHistoryService.availability(runner: cli) == .noDockerCLI)
    }

    @Test func noBuildxPlugin() async {
        let cli = FakeDockerCLI()
        cli.on(version, DockerCLIResult(exitCode: 1, stdout: "", stderr: "docker: unknown command: docker buildx"))
        #expect(await BuildxHistoryService.availability(runner: cli) == .noBuildx)
    }

    @Test func oldBuildx() async {
        let cli = FakeDockerCLI()
        cli.on(version, DockerCLIResult(exitCode: 0, stdout: "github.com/docker/buildx v0.17.1 abc\n"))
        #expect(await BuildxHistoryService.availability(runner: cli) == .tooOld(version: "0.17.1"))
    }

    @Test func currentBuildx() async {
        let cli = FakeDockerCLI()
        cli.on(version, DockerCLIResult(exitCode: 0, stdout: "github.com/docker/buildx v0.29.1 a32761aeb3debd39be1eca514af3693af0db334b\n"))
        #expect(await BuildxHistoryService.availability(runner: cli) == .available(version: "0.29.1"))
    }

    @Test func recordsBecomeBuildRecords() async throws {
        let cli = FakeDockerCLI()
        cli.on(list, DockerCLIResult(exitCode: 0, stdout: lsLines))
        let host = UUID()
        let records = try await BuildxHistoryService.records(runner: cli, hostID: host)
        #expect(records.count == 2)
        let failed = try #require(records.first)
        #expect(failed.source == .buildx)
        #expect(failed.hostID == host)
        #expect(failed.status == .failed)
        #expect(failed.summary.total == 6)
        #expect(failed.summary.cached == 1)
        #expect(records[1].status == .succeeded)
        #expect(records[1].summary.cached == 3)
        #expect((failed.duration ?? 0) > 0.2)
    }

    @Test func listErrorGivesTheMessage() async {
        let cli = FakeDockerCLI()
        cli.on(list, DockerCLIResult(exitCode: 1, stdout: "", stderr: "ERROR: failed to get history: Cannot connect\n"))
        await #expect(throws: BuildxCommandError(message: "failed to get history: Cannot connect")) {
            try await BuildxHistoryService.records(runner: cli, hostID: UUID())
        }
    }

    @Test func detailJoinsInspectAndLogs() async throws {
        let cli = FakeDockerCLI()
        cli.on(list, DockerCLIResult(exitCode: 0, stdout: lsLines))
        cli.on(["buildx", "history", "inspect", "--format", "json", "o4kn3a8tluispaxrrvdsh5ypt"],
               DockerCLIResult(exitCode: 0, stdout: inspectFailed))
        // buildx prints the logs on stderr.
        cli.on(["buildx", "history", "logs", "o4kn3a8tluispaxrrvdsh5ypt"],
               DockerCLIResult(exitCode: 0, stdout: "", stderr: logsFailed))
        let record = try #require(try await BuildxHistoryService.records(runner: cli, hostID: UUID()).first)
        let detail = try await BuildxHistoryService.detail(of: record, runner: cli)
        #expect(detail.dockerfile == "Dockerfile.fail")
        #expect(detail.errorMessage?.contains("exit code: 3") == true)
        #expect(detail.steps.count == 3)
        #expect(detail.steps.last?.state == .failed)
        #expect(detail.log.contains("RUN exit 3"))
        // The counts from `ls` stay the summary.
        #expect(detail.summary.total == 6)
        #expect(detail.summary.cached == 1)
        #expect(detail.summary.failed == 1)
    }

    @Test func badReferenceRunsNoCommand() async {
        let cli = FakeDockerCLI()
        let record = BuildRecord(id: "default/default/x;rm -rf ~", hostID: UUID(), source: .buildx, name: "x",
                                 status: .succeeded, startedAt: Date())
        await #expect(throws: BuildxCommandError.self) { try await BuildxHistoryService.detail(of: record, runner: cli) }
        #expect(cli.calls.isEmpty)
    }

    @Test func safeIDs() {
        #expect(BuildxHistoryService.isSafeID("o4kn3a8tluispaxrrvdsh5ypt"))
        #expect(!BuildxHistoryService.isSafeID(""))
        #expect(!BuildxHistoryService.isSafeID("a b"))
        #expect(!BuildxHistoryService.isSafeID("--format"))
    }

    @Test func localCLISearch() {
        let path = LocalDockerCLIRunner.cliPath(environment: [:]) { $0 == "/opt/homebrew/bin/docker" }
        #expect(path == "/opt/homebrew/bin/docker")
        let override = LocalDockerCLIRunner.cliPath(environment: ["GANTRY_DOCKER": "/x/docker"]) { _ in true }
        #expect(override == "/x/docker")
        #expect(LocalDockerCLIRunner.cliPath(environment: [:]) { _ in false } == nil)
    }

    @MainActor
    @Test func appleHostsHaveNoBuildx() async {
        let session = HostSession(host: DockerHost(name: "Apple", kind: .appleContainer))
        #expect(session.dockerCLIRunner() == nil)
        #expect(await session.buildxAvailability() == .notDockerHost)
    }
}
