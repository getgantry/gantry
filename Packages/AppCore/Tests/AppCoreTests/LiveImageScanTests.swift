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
