import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

// Live, with the real `container` CLI and a real scanner. Gated:
//   GANTRY_SCAN_LIVE=1 TMPDIR=/Volumes/Disk/tmp TRIVY_CACHE_DIR=… GRYPE_DB_CACHE_DIR=… \
//   GANTRY_TRIVY=… GANTRY_GRYPE=… swift test --filter LiveImageScan
// It needs `alpine:latest` (linux/arm64) in the local image store.

private let liveEnabled = ProcessInfo.processInfo.environment["GANTRY_SCAN_LIVE"] == "1"
    && AppleContainerCLIDiscovery.discover() != nil

@MainActor
@Suite(.serialized, .enabled(if: liveEnabled))
struct LiveImageScanTests {
    private func model() -> ImageScanModel {
        ImageScanModel(
            plan: .appleArchive(reference: "alpine:latest", platform: "linux/arm64"),
            export: ImageScanModel.appleExport(reference: "alpine:latest", platform: "linux/arm64")
        )
    }

    @Test(arguments: ScannerKind.allCases)
    func scansAnAppleImage(_ kind: ScannerKind) async throws {
        let model = model()
        await model.detect()
        try #require(model.scanners.contains { $0.kind == kind })
        model.selectedKind = kind
        model.scan()
        await model.waitUntilIdle()
        guard case .finished(let report) = model.state else {
            Issue.record("state is \(model.state)")
            return
        }
        #expect(report.scanner == kind)
        #expect(report.scannerVersion != nil)

        let sbom = FileManager.default.temporaryDirectory.appendingPathComponent("gantry-live-\(UUID().uuidString).cdx.json").path
        defer { try? FileManager.default.removeItem(atPath: sbom) }
        model.exportSBOM(.cycloneDX, to: sbom)
        await model.waitUntilIdle()
        #expect(model.sbomState == .saved(sbom))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: sbom))) as? [String: Any]
        #expect(json?["bomFormat"] as? String == "CycloneDX")
        model.close()
    }

    @Test func trivyWritesSPDX() async throws {
        let model = model()
        await model.detect()
        try #require(model.scanners.contains { $0.kind == .trivy })
        model.selectedKind = .trivy
        let sbom = FileManager.default.temporaryDirectory.appendingPathComponent("gantry-live-\(UUID().uuidString).spdx.json").path
        defer { try? FileManager.default.removeItem(atPath: sbom) }
        model.exportSBOM(.spdx, to: sbom)
        await model.waitUntilIdle()
        #expect(model.sbomState == .saved(sbom))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: sbom))) as? [String: Any]
        #expect((json?["spdxVersion"] as? String)?.hasPrefix("SPDX-") == true)
        model.close()
    }

    @Test func cancelStopsARealScan() async throws {
        let model = ImageScanModel(
            plan: .appleArchive(reference: "alpine:latest", platform: "linux/arm64"),
            export: { path in
                try await ImageScanModel.appleExport(reference: "alpine:latest", platform: "linux/arm64")(path)
                // Cancel after the export, while the scan step starts.
                withUnsafeCurrentTask { $0?.cancel() }
            }
        )
        await model.detect()
        try #require(!model.scanners.isEmpty)
        model.scan()
        await model.waitUntilIdle()
        #expect(model.state == .cancelled)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("gantry-scan-") }
        #expect(leftovers.isEmpty)
    }
}

// Live, with a real Docker engine over SSH. Gated:
//   GANTRY_SCAN_DOCKER_SSH=user@host GANTRY_SCAN_DOCKER_IMAGE=gis-scan-test:alpine \
//   GANTRY_SCAN_DOCKER_REGISTRY_IMAGE=alpine:3.20 (plus the scanner variables above) \
//   swift test --filter LiveDockerImageScan
// Both images must be on the engine. The second one must also be in a registry.

private let dockerTarget = ProcessInfo.processInfo.environment["GANTRY_SCAN_DOCKER_SSH"] ?? ""
private let dockerImage = ProcessInfo.processInfo.environment["GANTRY_SCAN_DOCKER_IMAGE"] ?? ""
private let registryImage = ProcessInfo.processInfo.environment["GANTRY_SCAN_DOCKER_REGISTRY_IMAGE"] ?? ""

@MainActor
@Suite(.serialized, .enabled(if: !dockerTarget.isEmpty && !dockerImage.isEmpty))
struct LiveDockerImageScanTests {
    private func session() async throws -> HostSession {
        let parts = dockerTarget.split(separator: "@", maxSplits: 1).map(String.init)
        let endpoint = parts.count == 2
            ? SSHEndpoint(host: parts[1], username: parts[0])
            : SSHEndpoint(host: dockerTarget)
        let session = HostSession(host: DockerHost(name: "gis-scan", kind: .ssh(endpoint)))
        await session.connect()
        await session.refreshImages()
        try #require(!session.images.isEmpty, "no images on \(dockerTarget)")
        return session
    }

    private func image(_ reference: String, in session: HostSession) throws -> ImageSummary {
        try #require(session.images.first { $0.repoTags.contains(reference) }, "\(reference) is missing")
    }

    @Test(arguments: ScannerKind.allCases)
    func scansADockerArchive(_ kind: ScannerKind) async throws {
        let session = try await session()
        defer { Task { await session.disconnect() } }
        _ = try image(dockerImage, in: session)
        let plan = ImageScanPlan.dockerArchive(reference: dockerImage)
        let model = ImageScanModel(plan: plan, export: session.imageScanExport(for: plan))
        await model.detect()
        try #require(model.scanners.contains { $0.kind == kind })
        model.selectedKind = kind
        model.scan()
        await model.waitUntilIdle()
        guard case .finished(let report) = model.state else {
            Issue.record("state is \(model.state)")
            return
        }
        #expect(report.scanner == kind)

        let sbom = FileManager.default.temporaryDirectory.appendingPathComponent("gantry-live-\(UUID().uuidString).cdx.json").path
        defer { try? FileManager.default.removeItem(atPath: sbom) }
        model.exportSBOM(.cycloneDX, to: sbom)
        await model.waitUntilIdle()
        #expect(model.sbomState == .saved(sbom))
        model.close()
    }

    @Test(.enabled(if: !registryImage.isEmpty), arguments: ScannerKind.allCases)
    func scansTheRegistryCopyForAnSSHHost(_ kind: ScannerKind) async throws {
        let session = try await session()
        defer { Task { await session.disconnect() } }
        let summary = try image(registryImage, in: session)
        let plan = try #require(session.imageScanPlan(for: summary))
        #expect(plan.scansRegistryCopy)
        guard case .registry(_, let platform) = plan else {
            Issue.record("plan is \(plan)")
            return
        }
        #expect(platform == "linux/amd64" || platform == "linux/arm64")
        let model = try #require(session.makeImageScanModel(for: summary))
        await model.detect()
        try #require(model.scanners.contains { $0.kind == kind })
        model.selectedKind = kind
        model.scan()
        await model.waitUntilIdle()
        guard case .finished(let report) = model.state else {
            Issue.record("state is \(model.state)")
            return
        }
        #expect(report.scanner == kind)
        model.close()
    }
}
