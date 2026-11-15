import Foundation
import Testing
import DockerKit
@testable import AppCore

@Suite struct PullProgressTrackerTests {
    private let a = "a1b2c3d4e5f6"
    private let b = "0f9e8d7c6b5a"

    @Test func dockerLinesCountLayersAndBytes() {
        var tracker = PullProgressTracker()
        tracker.apply(PullProgress(id: "17", status: "Pulling from library/postgres"))
        tracker.apply(PullProgress(id: a, status: "Pulling fs layer"))
        tracker.apply(PullProgress(id: b, status: "Already exists"))
        tracker.apply(PullProgress(id: a, status: "Downloading", current: 25, total: 100))
        #expect(tracker.layersTotal == 2)
        #expect(tracker.layersDone == 1)
        #expect(tracker.bytes == OperationProgress.Bytes(done: 25, total: 100))
        #expect(tracker.fraction == 0.25)

        tracker.apply(PullProgress(id: a, status: "Download complete"))
        #expect(tracker.bytes?.done == 100)
        tracker.apply(PullProgress(id: a, status: "Extracting", current: 10, total: 100))
        tracker.apply(PullProgress(id: a, status: "Pull complete"))
        #expect(tracker.layersDone == 2)
        #expect(tracker.progress.items == .init(done: 2, total: 2, unit: .layers))
        tracker.apply(PullProgress(status: "Digest: sha256:abc"))
        #expect(tracker.statusLine == "Digest: sha256:abc")
    }

    @Test func tagLinesAreNotLayers() {
        var tracker = PullProgressTracker()
        tracker.apply(PullProgress(id: "latest", status: "Pulling from library/nginx"))
        #expect(tracker.layersTotal == 0)
        #expect(tracker.progress.isEmpty)
    }

    @Test func appleContainerPercentLines() {
        var tracker = PullProgressTracker()
        // AppleContainerJSON.pullProgressJSON turns "42%" into current 42 of 100.
        tracker.apply(PullProgress(status: "[1/2] Fetching image 42% (3 of 7 blobs)", current: 42, total: 100))
        #expect(tracker.fraction == 0.42)
        #expect(tracker.progress.isEmpty)
        tracker.apply(PullProgress(status: "Pull complete"))
        #expect(tracker.statusLine == "Pull complete")
        #expect(tracker.fraction == 0.42)
    }
}
