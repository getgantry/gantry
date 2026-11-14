import Foundation
import Observation
import DockerKit

/// The result of one child process of a scan.
public struct ScanProcessResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public init(status: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { status == 0 }
}

/// Runs the child processes of a scan. Cancelling the calling task must stop
/// the process and throw `CancellationError`.
public protocol ScanProcessRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) async throws -> ScanProcessResult
}

/// Runs processes with `ChildProcess`, which sends SIGTERM on cancel.
public struct ChildProcessScanRunner: ScanProcessRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) async throws -> ScanProcessResult {
        let result = try await ChildProcess.run(executable, arguments)
        let status = result.exit.signaled ? -result.exit.status : result.exit.status
        return ScanProcessResult(status: status, stdout: result.stdout, stderr: result.stderr)
    }
}

/// The file operations of a scan, so that tests do not touch the disk.
public protocol ScanFileSystem: Sendable {
    func makeTemporaryFolder() throws -> String
    func createFolder(_ path: String) throws
    func remove(_ path: String)
    func read(_ path: String) throws -> Data
    /// Moves `source` to `destination` and replaces a file that is there.
    func move(_ source: String, to destination: String) throws
}

public struct LocalScanFileSystem: ScanFileSystem {
    public init() {}

    public func makeTemporaryFolder() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gantry-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    public func createFolder(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    public func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    public func read(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    public func move(_ source: String, to destination: String) throws {
        let target = URL(fileURLWithPath: destination)
        if FileManager.default.fileExists(atPath: destination) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: URL(fileURLWithPath: source))
        } else {
            try FileManager.default.moveItem(atPath: source, toPath: destination)
        }
    }
}

/// Writes the image archive of an export plan to the given path.
public typealias ImageScanExport = @MainActor (_ archivePath: String) async throws -> Void

/// The state of the scan sheet: scanner detection, export, scan, SBOM.
@MainActor
@Observable
public final class ImageScanModel {
    public enum Step: Sendable, Equatable {
        case exporting
        case unpacking
        case scanning
    }

    public enum State: Sendable, Equatable {
        case detecting
        case noScanner
        case ready
        case running(Step, startedAt: Date)
        case finished(ScanReport)
        case failed(String)
        case cancelled
    }

    public enum SBOMState: Sendable, Equatable {
        case idle
        case running(SBOMFormat, startedAt: Date)
        case failed(String)
        case saved(String)
    }

    public let plan: ImageScanPlan
    public private(set) var scanners: [InstalledScanner] = []
    public var selectedKind: ScannerKind?
    public private(set) var state: State = .detecting
    public private(set) var sbomState: SBOMState = .idle

    @ObservationIgnored private let runner: ScanProcessRunning
    @ObservationIgnored private let files: ScanFileSystem
    @ObservationIgnored private let export: ImageScanExport?
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private let isExecutable: @Sendable (String) -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var workspace: String?
    @ObservationIgnored private var preparedSource: ScanSource?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var detection: Task<Void, Never>?

    /// - Parameter export: writes the image archive; nil for a registry plan.
    public init(
        plan: ImageScanPlan,
        export: ImageScanExport?,
        runner: ScanProcessRunning = ChildProcessScanRunner(),
        files: ScanFileSystem = LocalScanFileSystem(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.plan = plan
        self.export = export
        self.runner = runner
        self.files = files
        self.environment = environment
        self.isExecutable = isExecutable
        self.now = now
    }

    /// The selected scanner, or the first one.
    public var selectedScanner: InstalledScanner? {
        scanners.first { $0.kind == selectedKind } ?? scanners.first
    }

    /// True while a scan or an SBOM export runs.
    public var isBusy: Bool {
        if case .running = state { return true }
        if case .running = sbomState { return true }
        return false
    }

    /// The SBOM formats of the selected scanner.
    public var sbomFormats: [SBOMFormat] { selectedScanner?.kind.sbomFormats ?? [] }

    // MARK: - Detection

    /// Finds the scanners. Also the Check Again action of the install help.
    public func detect() async {
        guard !isBusy else { return }
        state = .detecting
        scanners = await ScannerLocator.detect(runner: runner, environment: environment, isExecutable: isExecutable)
        if selectedKind == nil || !scanners.contains(where: { $0.kind == selectedKind }) {
            selectedKind = (scanners.first(where: \.isSupported) ?? scanners.first)?.kind
        }
        state = scanners.isEmpty ? .noScanner : .ready
    }

    /// Starts the detection one time. The sheet calls it when it makes the
    /// model, so the detection does not depend on the view lifecycle.
    public func startDetection() {
        guard detection == nil else { return }
        detection = Task { await detect() }
    }

    // MARK: - Scan

    /// Starts a scan with the selected scanner.
    public func scan() {
        guard !isBusy, !closed, let scanner = selectedScanner, scanner.isSupported else { return }
        task = Task { await performScan(with: scanner) }
    }

    /// Stops the running scan or SBOM export. The task removes the
    /// temporary files and sets the cancelled state.
    public func cancel() {
        task?.cancel()
    }

    /// Waits for the running task. For tests and for the sheet's close.
    public func waitUntilIdle() async {
        await detection?.value
        await task?.value
    }

    /// Stops the work and removes the temporary folder. Call it when the
    /// sheet goes away.
    public func close() {
        closed = true
        if let task, isBusy {
            task.cancel()
        } else {
            removeWorkspace()
        }
    }

    private func performScan(with scanner: InstalledScanner) async {
        do {
            let source = try await prepareSource()
            state = .running(.scanning, startedAt: now())
            let output = try outputPath("report-\(scanner.kind.rawValue).json")
            defer { files.remove(output) }
            try await runScanner(scanner, source: source, output: .report, outputPath: output)
            let data = try files.read(output)
            let report = try scanner.kind == .trivy ? TrivyReportParser.parse(data) : GrypeReportParser.parse(data)
            state = .finished(report)
        } catch {
            if Task.isCancelled || error is CancellationError {
                discardPreparedSource()
                state = .cancelled
            } else {
                state = .failed(Self.message(for: error))
            }
        }
        task = nil
        if closed { removeWorkspace() }
    }

    // MARK: - SBOM

    /// Writes an SBOM of the image to `destination`. The scanner writes a
    /// temporary file; Gantry moves it only after the scanner succeeds.
    public func exportSBOM(_ format: SBOMFormat, to destination: String) {
        guard !isBusy, !closed, let scanner = selectedScanner, scanner.isSupported,
              scanner.kind.sbomFormats.contains(format) else { return }
        task = Task { await performSBOM(format, scanner: scanner, destination: destination) }
    }

    private func performSBOM(_ format: SBOMFormat, scanner: InstalledScanner, destination: String) async {
        sbomState = .running(format, startedAt: now())
        var temporary: String?
        do {
            let source = try await prepareSource(reportSteps: false)
            let output = try outputPath("sbom-\(UUID().uuidString)\(format.fileSuffix)")
            temporary = output
            try await runScanner(scanner, source: source, output: .sbom(format), outputPath: output)
            try Task.checkCancellation()
            try files.move(output, to: destination)
            temporary = nil
            sbomState = .saved(destination)
        } catch {
            if let temporary { files.remove(temporary) }
            if Task.isCancelled || error is CancellationError {
                discardPreparedSource()
                sbomState = .idle
            } else {
                sbomState = .failed(Self.message(for: error))
            }
        }
        task = nil
        if closed { removeWorkspace() }
    }

    /// Clears a failed or saved SBOM state.
    public func dismissSBOMState() {
        if case .running = sbomState { return }
        sbomState = .idle
    }

    // MARK: - Steps

    /// The source of the plan. An export result stays for the next scan and
    /// for SBOM exports until `close()`.
    private func prepareSource(reportSteps: Bool = true) async throws -> ScanSource {
        if let preparedSource { return preparedSource }
        let folder = try workspaceFolder()
        let source: ScanSource
        switch plan {
        case .registry(let reference, let platform):
            source = .registry(reference: reference, platform: platform)
        case .dockerArchive:
            let archive = (folder as NSString).appendingPathComponent("image.tar")
            if reportSteps { state = .running(.exporting, startedAt: now()) }
            try await runExport(to: archive)
            source = .dockerArchive(path: archive)
        case .appleArchive:
            let archive = (folder as NSString).appendingPathComponent("image.tar")
            let layout = (folder as NSString).appendingPathComponent("oci")
            if reportSteps { state = .running(.exporting, startedAt: now()) }
            try await runExport(to: archive)
            try Task.checkCancellation()
            if reportSteps { state = .running(.unpacking, startedAt: now()) }
            try files.createFolder(layout)
            let result = try await runner.run(ScanCommand.tarPath, ScanCommand.unpackArguments(archive: archive, into: layout))
            files.remove(archive)
            guard result.succeeded else { throw ScanStepFailure(Self.tail(of: result.stderr)) }
            source = .ociLayout(path: layout)
        }
        try Task.checkCancellation()
        preparedSource = source
        return source
    }

    private func runExport(to archive: String) async throws {
        guard let export else { throw ScanStepFailure(String(localized: "This image cannot be exported for a scan.", bundle: .module)) }
        do {
            try await export(archive)
        } catch {
            files.remove(archive)
            throw error
        }
    }

    private func runScanner(
        _ scanner: InstalledScanner, source: ScanSource, output: ScanOutput, outputPath: String
    ) async throws {
        let arguments = ScanCommand.arguments(scanner.kind, source: source, output: output, outputPath: outputPath)
        let result = try await runner.run(scanner.path, arguments)
        try Task.checkCancellation()
        guard result.succeeded else {
            let detail = Self.tail(of: result.stderr)
            throw ScanStepFailure(
                detail.isEmpty
                    ? String(localized: "\(scanner.kind.displayName) exited with status \(Int(result.status)).", bundle: .module)
                    : detail
            )
        }
    }

    private func workspaceFolder() throws -> String {
        if let workspace { return workspace }
        let folder = try files.makeTemporaryFolder()
        workspace = folder
        return folder
    }

    private func outputPath(_ name: String) throws -> String {
        (try workspaceFolder() as NSString).appendingPathComponent(name)
    }

    /// A cancelled export can leave a partial archive: start again next time.
    private func discardPreparedSource() {
        preparedSource = nil
        removeWorkspace()
    }

    private func removeWorkspace() {
        if let workspace { files.remove(workspace) }
        workspace = nil
        preparedSource = nil
    }

    // MARK: - Messages

    /// The last lines of a scanner's error output, without terminal colors.
    static func tail(of data: Data, lines: Int = 6) -> String {
        let text = String(decoding: data, as: UTF8.self)
            .replacing(#/\u{1B}\[[0-9;]*[A-Za-z]/#, with: "")
            .replacingOccurrences(of: "\r", with: "\n")
        let kept = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return kept.suffix(lines).joined(separator: "\n")
    }

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// A step of the scan failed; the message is for the user.
public struct ScanStepFailure: LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
