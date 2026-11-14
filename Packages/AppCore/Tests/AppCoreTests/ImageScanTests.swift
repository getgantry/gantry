import Foundation
import Testing
@testable import AppCore

// MARK: - Fakes

/// An in-memory file system that records what the scan does.
final class FakeScanFiles: ScanFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var _files: [String: Data] = [:]
    private var _folders: Set<String> = []
    private var _removed: [String] = []
    private var counter = 0

    var files: [String: Data] { lock.withLock { _files } }
    var folders: Set<String> { lock.withLock { _folders } }
    var removed: [String] { lock.withLock { _removed } }

    func write(_ path: String, _ data: Data) { lock.withLock { _files[path] = data } }

    func makeTemporaryFolder() throws -> String {
        lock.withLock {
            counter += 1
            let path = "/tmp-scan-\(counter)"
            _folders.insert(path)
            return path
        }
    }

    func createFolder(_ path: String) throws { _ = lock.withLock { _folders.insert(path) } }

    func remove(_ path: String) {
        lock.withLock {
            _removed.append(path)
            _folders = _folders.filter { $0 != path && !$0.hasPrefix(path + "/") }
            _files = _files.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
        }
    }

    func read(_ path: String) throws -> Data {
        guard let data = files[path] else { throw CocoaError(.fileNoSuchFile) }
        return data
    }

    func move(_ source: String, to destination: String) throws {
        try lock.withLock {
            guard let data = _files.removeValue(forKey: source) else { throw CocoaError(.fileNoSuchFile) }
            _files[destination] = data
        }
    }
}

/// A process runner with canned answers. A scanner run writes `report` to
/// the output path. `blockScanner` makes the scanner wait for cancellation.
final class FakeScanRunner: ScanProcessRunning, @unchecked Sendable {
    let files: FakeScanFiles
    var report = Data()
    var scannerStatus: Int32 = 0
    var scannerStderr = Data()
    var blockScanner = false
    private let lock = NSLock()
    private var _calls: [(String, [String])] = []
    let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation

    init(files: FakeScanFiles) {
        self.files = files
        (started, startedContinuation) = AsyncStream<Void>.makeStream()
    }

    var calls: [(String, [String])] { lock.withLock { _calls } }

    func run(_ executable: String, _ arguments: [String]) async throws -> ScanProcessResult {
        lock.withLock { _calls.append((executable, arguments)) }
        if arguments == ["--version"] { return ScanProcessResult(status: 0, stdout: Data("Version: 0.76.2\n".utf8)) }
        if arguments == ["version"] { return ScanProcessResult(status: 0, stdout: Data("Application: grype\nVersion:             0.121.3\n".utf8)) }
        if executable == ScanCommand.tarPath { return ScanProcessResult(status: 0) }
        if blockScanner {
            startedContinuation.yield()
            try await Self.waitForCancellation()
        }
        guard scannerStatus == 0 else { return ScanProcessResult(status: scannerStatus, stderr: scannerStderr) }
        if let index = arguments.firstIndex(where: { $0 == "--output" || $0 == "--file" }) {
            files.write(arguments[index + 1], report)
        }
        return ScanProcessResult(status: 0)
    }

    private static func waitForCancellation() async throws {
        let gate = CancelGate()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.set(continuation)
            }
        } onCancel: {
            gate.cancel()
        }
    }
}

/// Resumes a waiting continuation once, on cancel, also when the cancel
/// comes before the continuation is stored.
private final class CancelGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false

    func set(_ continuation: CheckedContinuation<Void, Error>) {
        let resumeNow = lock.withLock { () -> Bool in
            if cancelled { return true }
            self.continuation = continuation
            return false
        }
        if resumeNow { continuation.resume(throwing: CancellationError()) }
    }

    func cancel() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            cancelled = true
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(throwing: CancellationError())
    }
}

// MARK: - Detection

@Suite("Image scan: scanner detection")
struct ScannerDetectionTests {
    @Test func overrideComesFirst() {
        let env = ["GANTRY_TRIVY": "/custom/trivy", "PATH": "/usr/bin:/opt/homebrew/bin"]
        let found = ScannerLocator.locate(.trivy, environment: env) { ["/custom/trivy", "/opt/homebrew/bin/trivy"].contains($0) }
        #expect(found == "/custom/trivy")
    }

    @Test func pathFolderBeforeHomebrew() {
        let env = ["PATH": "/Users/me/bin:/usr/bin"]
        let found = ScannerLocator.locate(.grype, environment: env) { ["/Users/me/bin/grype", "/opt/homebrew/bin/grype"].contains($0) }
        #expect(found == "/Users/me/bin/grype")
    }

    @Test func homebrewFoldersWhenPathIsShort() {
        let env = ["PATH": "/usr/bin:/bin"]
        #expect(ScannerLocator.locate(.trivy, environment: env) { $0 == "/usr/local/bin/trivy" } == "/usr/local/bin/trivy")
        #expect(ScannerLocator.locate(.trivy, environment: env) { _ in false } == nil)
    }

    @Test func overrideThatIsNotExecutableIsIgnored() {
        let env = ["GANTRY_GRYPE": "/missing/grype", "PATH": ""]
        #expect(ScannerLocator.locate(.grype, environment: env) { $0 == "/opt/homebrew/bin/grype" } == "/opt/homebrew/bin/grype")
    }

    @Test func versionParse() {
        #expect(ScannerLocator.parseVersion("Version: 0.76.2\nVulnerability DB:\n  Version: 2\n") == "0.76.2")
        #expect(ScannerLocator.parseVersion("Application:         grype\nVersion:             0.121.3\n") == "0.121.3")
        #expect(ScannerLocator.parseVersion("Version: v0.50.1") == "0.50.1")
        #expect(ScannerLocator.parseVersion("garbage") == nil)
    }

    @Test func minimumVersions() {
        #expect(InstalledScanner(kind: .trivy, path: "/t", version: "0.76.2").isSupported)
        #expect(!InstalledScanner(kind: .trivy, path: "/t", version: "0.49.9").isSupported)
        #expect(InstalledScanner(kind: .grype, path: "/g", version: "0.74.0").isSupported)
        #expect(!InstalledScanner(kind: .grype, path: "/g", version: "0.73.5").isSupported)
        #expect(InstalledScanner(kind: .grype, path: "/g", version: nil).isSupported)
    }

    @Test func grypeHasNoSPDX() {
        #expect(ScannerKind.trivy.sbomFormats == [.cycloneDX, .spdx])
        #expect(ScannerKind.grype.sbomFormats == [.cycloneDX])
    }
}

// MARK: - Plan and commands

@Suite("Image scan: plan and commands")
struct ImageScanPlanTests {
    @Test func appleTaggedImageExportsWithPlatform() {
        let plan = ImageScanPlan.make(host: .apple, id: "sha256:1", repoTags: ["postgres:16-alpine"], os: "linux", architecture: "arm64")
        #expect(plan == .appleArchive(reference: "postgres:16-alpine", platform: "linux/arm64"))
    }

    @Test func appleUntaggedImageHasNoPlan() {
        #expect(ImageScanPlan.make(host: .apple, id: "sha256:1", repoTags: ["<none>:<none>"], os: "linux", architecture: "arm64") == nil)
        #expect(ImageScanPlan.make(host: .remoteDocker, id: "sha256:1", repoTags: [], os: "", architecture: "") == nil)
    }

    @Test func localDockerUsesIDWhenUntagged() {
        #expect(ImageScanPlan.make(host: .localDocker, id: "sha256:abc", repoTags: [], os: "", architecture: "") == .dockerArchive(reference: "sha256:abc"))
        #expect(ImageScanPlan.make(host: .localDocker, id: "sha256:abc", repoTags: ["web:1"], os: "", architecture: "") == .dockerArchive(reference: "web:1"))
    }

    @Test func remoteDockerScansRegistryCopy() {
        let plan = ImageScanPlan.make(host: .remoteDocker, id: "sha256:1", repoTags: ["alpine:3.20"], os: "linux", architecture: "amd64")
        #expect(plan == .registry(reference: "alpine:3.20", platform: "linux/amd64"))
        #expect(plan?.scansRegistryCopy == true)
    }

    @Test func platformNames() {
        #expect(ImageScanPlan.platformString(os: "", architecture: "aarch64") == "linux/arm64")
        #expect(ImageScanPlan.platformString(os: "linux", architecture: "x86_64") == "linux/amd64")
        #expect(ImageScanPlan.platformString(os: "linux", architecture: "") == nil)
        let plan = ImageScanPlan.make(host: .apple, id: "1", repoTags: ["a:1"], os: "", architecture: "", fallbackArchitecture: "aarch64")
        #expect(plan == .appleArchive(reference: "a:1", platform: "linux/arm64"))
    }

    @Test func trivyArguments() {
        #expect(ScanCommand.arguments(.trivy, source: .ociLayout(path: "/w/oci"), output: .report, outputPath: "/w/r.json") == [
            "image", "--quiet", "--timeout", "30m", "--scanners", "vuln", "--format", "json", "--output", "/w/r.json", "--input", "/w/oci",
        ])
        #expect(ScanCommand.arguments(.trivy, source: .registry(reference: "alpine:3.20", platform: "linux/arm64"), output: .sbom(.spdx), outputPath: "/w/s.json") == [
            "image", "--quiet", "--timeout", "30m", "--format", "spdx-json", "--output", "/w/s.json",
            "--image-src", "remote", "--platform", "linux/arm64", "alpine:3.20",
        ])
        #expect(ScanCommand.arguments(.trivy, source: .dockerArchive(path: "/w/i.tar"), output: .sbom(.cycloneDX), outputPath: "/w/c.json").contains("cyclonedx"))
    }

    @Test func grypeArguments() {
        #expect(ScanCommand.arguments(.grype, source: .ociLayout(path: "/w/oci"), output: .report, outputPath: "/w/r.json") == [
            "oci-dir:/w/oci", "-q", "-o", "json", "--file", "/w/r.json",
        ])
        #expect(ScanCommand.arguments(.grype, source: .dockerArchive(path: "/w/i.tar"), output: .sbom(.cycloneDX), outputPath: "/w/c.json") == [
            "docker-archive:/w/i.tar", "-q", "-o", "cyclonedx-json", "--file", "/w/c.json",
        ])
        #expect(ScanCommand.arguments(.grype, source: .registry(reference: "alpine:3.20", platform: "linux/amd64"), output: .report, outputPath: "/w/r.json") == [
            "registry:alpine:3.20", "--platform", "linux/amd64", "-q", "-o", "json", "--file", "/w/r.json",
        ])
    }

    @Test func appleExportArguments() {
        #expect(ScanCommand.appleSaveArguments(reference: "postgres:16-alpine", platform: "linux/arm64", to: "/w/image.tar") == [
            "image", "save", "--platform", "linux/arm64", "--output", "/w/image.tar", "postgres:16-alpine",
        ])
        #expect(ScanCommand.appleSaveArguments(reference: "a:1", platform: nil, to: "/w/i.tar") == ["image", "save", "--output", "/w/i.tar", "a:1"])
        #expect(ScanCommand.unpackArguments(archive: "/w/image.tar", into: "/w/oci") == ["-xf", "/w/image.tar", "-C", "/w/oci"])
    }
}

// MARK: - Parsers

@Suite("Image scan: report parsers")
struct ScanReportParserTests {
    @Test func trivyPostgres() throws {
        let report = try TrivyReportParser.parse(Data(ImageScanFixtures.trivyPostgres.utf8))
        #expect(report.scanner == .trivy)
        #expect(report.scannerVersion == "0.76.2")
        #expect(report.total == 7)
        #expect(report.count(of: .critical) == 1)
        #expect(report.count(of: .high) == 3)
        #expect(report.count(of: .medium) == 2)
        #expect(report.count(of: .unknown) == 1)
        #expect(report.groups.map(\.severity) == [.critical, .high, .medium, .unknown])

        let critical = try #require(report.groups.first?.findings.first)
        #expect(critical.vulnerabilityID == "CVE-2025-68121")
        #expect(critical.packageName == "stdlib")
        #expect(critical.packageType == "gobinary")
        #expect(critical.installedVersion == "v1.24.6")
        #expect(critical.fixedVersions == ["1.24.13", "1.25.7", "1.26.0-rc.3"])
        #expect(critical.fixState == .fixed)
        #expect(critical.url?.absoluteString == "https://avd.aquasec.com/nvd/cve-2025-68121")
        #expect(critical.title.hasPrefix("crypto/tls"))

        let high = try #require(report.groups.first { $0.severity == .high }).findings
        #expect(high.map(\.packageName) == ["krb5-libs", "krb5-libs", "stdlib"])
    }

    @Test func trivyReportWithoutResults() throws {
        let report = try TrivyReportParser.parse(Data(ImageScanFixtures.trivyNoResults.utf8))
        #expect(report.total == 0)
        #expect(report.groups.isEmpty)
        #expect(report.scannerVersion == "0.76.2")
    }

    @Test func trivyAlpineWithPackageList() throws {
        let report = try TrivyReportParser.parse(Data(ImageScanFixtures.trivyAlpine.utf8))
        #expect(report.total == 1)
        #expect(report.findings.first?.vulnerabilityID == "CVE-2026-4738")
        #expect(report.findings.first?.severity == .medium)
    }

    @Test func grypePostgres() throws {
        let report = try GrypeReportParser.parse(Data(ImageScanFixtures.grypePostgres.utf8))
        #expect(report.scanner == .grype)
        #expect(report.scannerVersion == "0.121.3")
        #expect(report.total == 7)
        #expect(report.count(of: .critical) == 1)
        #expect(report.count(of: .high) == 2)
        #expect(report.count(of: .medium) == 3)
        #expect(report.count(of: .unknown) == 1)

        let noFix = try #require(report.findings.first { $0.vulnerabilityID == "CVE-2025-60876" })
        #expect(noFix.fixedVersions.isEmpty)
        #expect(noFix.fixState == .unknown)
        #expect(noFix.fixedDisplay == "No fix")
        #expect(noFix.url?.absoluteString == "https://nvd.nist.gov/vuln/detail/CVE-2025-60876")

        let go = try #require(report.findings.first { $0.packageType == "go-module" })
        #expect(go.vulnerabilityID == "GHSA-mjcv-p78q-w5fw")
        #expect(go.fixedVersions == ["0.4.1"])
        #expect(go.url?.absoluteString == "https://github.com/advisories/GHSA-mjcv-p78q-w5fw")

        let zlib = try #require(report.findings.first { $0.packageName == "zlib" })
        #expect(zlib.severity == .critical)
        #expect(zlib.installedVersion == "1.3.2-r1")
        #expect(!zlib.title.isEmpty)
    }

    @Test func grypeSameIDInThreePackagesGivesThreeRows() throws {
        let report = try GrypeReportParser.parse(Data(ImageScanFixtures.grypeAlpine.utf8))
        let rows = report.findings.filter { $0.vulnerabilityID == "CVE-2025-60876" }
        #expect(rows.map(\.packageName).sorted() == ["busybox", "busybox-binsh", "ssl_client"])
        #expect(Set(report.findings.map(\.id)).count == report.findings.count)
    }

    @Test func invalidReportThrows() {
        #expect(throws: ScanReportError(scanner: .trivy)) { try TrivyReportParser.parse(Data("not json".utf8)) }
        #expect(throws: ScanReportError(scanner: .grype)) { try GrypeReportParser.parse(Data("{}".utf8)) }
    }

    @Test func severityAndFixStateMapping() {
        #expect(VulnerabilitySeverity(parsing: "HIGH") == .high)
        #expect(VulnerabilitySeverity(parsing: "Negligible") == .negligible)
        #expect(VulnerabilitySeverity(parsing: "bogus") == .unknown)
        #expect(VulnerabilitySeverity.critical < .low)
        #expect(FixState.trivy("will_not_fix", fixedVersions: []) == .wontFix)
        #expect(FixState.trivy("affected", fixedVersions: []) == .notFixed)
        #expect(FixState.trivy(nil, fixedVersions: ["1.0"]) == .fixed)
        #expect(FixState.grype("wont-fix", fixedVersions: []) == .wontFix)
        #expect(FixState.grype("not-fixed", fixedVersions: []) == .notFixed)
    }

    @Test func linkFallback() {
        #expect(VulnerabilityLink.url(id: "CVE-2024-1", toolURL: nil)?.absoluteString == "https://www.cve.org/CVERecord?id=CVE-2024-1")
        #expect(VulnerabilityLink.url(id: "GHSA-abcd", toolURL: "")?.absoluteString == "https://github.com/advisories/GHSA-abcd")
        #expect(VulnerabilityLink.url(id: "ALPINE-1", toolURL: nil) == nil)
        #expect(VulnerabilityLink.url(id: "CVE-2024-1", toolURL: "http://insecure")?.host == "www.cve.org")
    }
}

// MARK: - Model

@MainActor
@Suite("Image scan: model")
struct ImageScanModelTests {
    let files = FakeScanFiles()
    let runner: FakeScanRunner
    var exports = ExportCounter()

    init() {
        runner = FakeScanRunner(files: files)
    }

    @MainActor
    final class ExportCounter {
        var paths: [String] = []
    }

    private func model(
        plan: ImageScanPlan = .appleArchive(reference: "postgres:16-alpine", platform: "linux/arm64"),
        installed: Set<String> = ["/opt/homebrew/bin/trivy"]
    ) -> ImageScanModel {
        let files = files
        let exports = exports
        let export: ImageScanExport = { @MainActor path in
            exports.paths.append(path)
            files.write(path, Data("tar".utf8))
        }
        return ImageScanModel(
            plan: plan,
            export: plan.scansRegistryCopy ? nil : export,
            runner: runner,
            files: files,
            environment: ["PATH": "/usr/bin"],
            isExecutable: { installed.contains($0) }
        )
    }

    @Test func noScanner() async {
        let model = model(installed: [])
        await model.detect()
        #expect(model.state == .noScanner)
        #expect(model.scanners.isEmpty)
    }

    @Test func trivyIsTheDefault() async {
        let model = model(installed: ["/opt/homebrew/bin/trivy", "/opt/homebrew/bin/grype"])
        await model.detect()
        #expect(model.state == .ready)
        #expect(model.scanners.map(\.kind) == [.trivy, .grype])
        #expect(model.selectedKind == .trivy)
        #expect(model.scanners.first?.version == "0.76.2")
        #expect(model.scanners.last?.version == "0.121.3")
    }

    @Test func appleScanExportsUnpacksAndParses() async throws {
        runner.report = Data(ImageScanFixtures.trivyPostgres.utf8)
        let model = model()
        await model.detect()
        model.scan()
        await model.waitUntilIdle()

        guard case .finished(let report) = model.state else {
            Issue.record("state is \(model.state)")
            return
        }
        #expect(report.total == 7)
        #expect(exports.paths == ["/tmp-scan-1/image.tar"])
        let scanCalls = runner.calls.filter { $0.1 != ["--version"] }
        #expect(scanCalls.map(\.0) == [ScanCommand.tarPath, "/opt/homebrew/bin/trivy"])
        #expect(scanCalls[0].1 == ["-xf", "/tmp-scan-1/image.tar", "-C", "/tmp-scan-1/oci"])
        #expect(scanCalls[1].1.suffix(2) == ["--input", "/tmp-scan-1/oci"])
        #expect(files.removed.contains("/tmp-scan-1/image.tar"))
        #expect(files.files["/tmp-scan-1/report-trivy.json"] == nil)

        model.close()
        #expect(files.removed.last == "/tmp-scan-1")
        #expect(files.folders.isEmpty)
    }

    @Test func secondScanReusesTheExport() async {
        runner.report = Data(ImageScanFixtures.trivyNoResults.utf8)
        let model = model()
        await model.detect()
        model.scan()
        await model.waitUntilIdle()
        model.scan()
        await model.waitUntilIdle()
        #expect(exports.paths.count == 1)
        #expect(model.state == .finished(ScanReport(scanner: .trivy, scannerVersion: "0.76.2", findings: [])))
    }

    @Test func registryPlanDoesNotExport() async {
        runner.report = Data(ImageScanFixtures.grypeAlpine.utf8)
        let model = model(plan: .registry(reference: "alpine:3.20", platform: "linux/amd64"), installed: ["/opt/homebrew/bin/grype"])
        await model.detect()
        model.scan()
        await model.waitUntilIdle()
        #expect(exports.paths.isEmpty)
        let scan = runner.calls.last
        #expect(scan?.1.first == "registry:alpine:3.20")
        if case .finished(let report) = model.state { #expect(report.total == 4) } else { Issue.record("not finished") }
    }

    @Test func failedScanShowsTheErrorTail() async {
        runner.scannerStatus = 1
        runner.scannerStderr = Data("\u{1B}[31mINFO\u{1B}[0m start\r2026 FATAL\tFatal error\tunable to initialize\n".utf8)
        let model = model()
        await model.detect()
        model.scan()
        await model.waitUntilIdle()
        guard case .failed(let message) = model.state else {
            Issue.record("state is \(model.state)")
            return
        }
        #expect(message.contains("FATAL"))
        #expect(!message.contains("\u{1B}"))
    }

    @Test func cancelStopsTheScannerAndRemovesFiles() async {
        runner.blockScanner = true
        let model = model()
        await model.detect()
        model.scan()
        var events = runner.started.makeAsyncIterator()
        _ = await events.next()
        if case .running(.scanning, _) = model.state {} else { Issue.record("state is \(model.state)") }
        model.cancel()
        await model.waitUntilIdle()
        #expect(model.state == .cancelled)
        #expect(files.folders.isEmpty)
        #expect(files.files.isEmpty)
    }

    @Test func closeDuringScanCancelsAndCleansUp() async {
        runner.blockScanner = true
        let model = model()
        await model.detect()
        model.scan()
        var events = runner.started.makeAsyncIterator()
        _ = await events.next()
        model.close()
        await model.waitUntilIdle()
        #expect(model.state == .cancelled)
        #expect(files.folders.isEmpty)
        model.scan()
        #expect(model.state == .cancelled)
    }

    @Test func sbomExportMovesTheFileAfterSuccess() async {
        runner.report = Data(#"{"spdxVersion":"SPDX-2.3"}"#.utf8)
        let model = model()
        await model.detect()
        model.exportSBOM(.spdx, to: "/Users/me/postgres.spdx.json")
        await model.waitUntilIdle()
        #expect(model.sbomState == .saved("/Users/me/postgres.spdx.json"))
        #expect(files.files["/Users/me/postgres.spdx.json"] == Data(#"{"spdxVersion":"SPDX-2.3"}"#.utf8))
        #expect(files.files.keys.filter { $0.hasPrefix("/tmp-scan-1/sbom-") }.isEmpty)
        let sbomCall = runner.calls.last?.1 ?? []
        #expect(sbomCall.contains("spdx-json"))
    }

    @Test func failedSBOMLeavesNoFile() async {
        runner.scannerStatus = 2
        runner.scannerStderr = Data("boom".utf8)
        let model = model()
        await model.detect()
        model.exportSBOM(.cycloneDX, to: "/Users/me/x.cdx.json")
        await model.waitUntilIdle()
        #expect(model.sbomState == .failed("boom"))
        #expect(files.files["/Users/me/x.cdx.json"] == nil)
        #expect(files.files.keys.allSatisfy { !$0.contains("sbom-") })
    }

    @Test func grypeOffersNoSPDX() async {
        let model = model(installed: ["/opt/homebrew/bin/grype"])
        await model.detect()
        #expect(model.sbomFormats == [.cycloneDX])
        model.exportSBOM(.spdx, to: "/Users/me/x.spdx.json")
        #expect(model.sbomState == .idle)
        #expect(!model.isBusy)
    }

    @Test func oldScannerDoesNotRun() async {
        let files = files
        let model = ImageScanModel(
            plan: .registry(reference: "a:1", platform: nil), export: nil,
            runner: OldTrivyRunner(), files: files, environment: ["PATH": ""],
            isExecutable: { $0 == "/opt/homebrew/bin/trivy" }
        )
        await model.detect()
        #expect(model.selectedScanner?.isSupported == false)
        model.scan()
        #expect(model.state == .ready)
    }
}

private struct OldTrivyRunner: ScanProcessRunning {
    func run(_ executable: String, _ arguments: [String]) async throws -> ScanProcessResult {
        ScanProcessResult(status: 0, stdout: Data("Version: 0.40.0".utf8))
    }
}
