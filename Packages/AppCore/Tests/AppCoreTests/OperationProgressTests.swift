import Foundation
import Testing
@testable import AppCore

@MainActor
@Suite struct OperationProgressTests {
    @Test func fractionPrefersBytesThenItems() {
        let both = OperationProgress(items: .init(done: 1, total: 4, unit: .layers), bytes: .init(done: 50, total: 100))
        #expect(both.fraction == 0.5)
        let items = OperationProgress(items: .init(done: 1, total: 4, unit: .steps))
        #expect(items.fraction == 0.25)
        #expect(OperationProgress.none.fraction == nil)
        #expect(OperationProgress.none.detailText == nil)
    }

    @Test func valuesAreClamped() {
        let items = OperationProgress.Items(done: 9, total: 3, unit: .items)
        #expect(items.done == 3)
        let bytes = OperationProgress.Bytes(done: -5, total: 10)
        #expect(bytes.done == 0)
        #expect(OperationProgress.Items(done: 0, total: 0, unit: .items).fraction == nil)
    }

    @Test func detailTextJoinsItemsAndBytes() {
        let progress = OperationProgress(items: .init(done: 3, total: 7, unit: .layers), bytes: .init(done: 1_000, total: 2_000))
        let text = progress.detailText ?? ""
        #expect(text.hasPrefix("Layers: 3 of 7 · "))
        #expect(OperationProgress(items: .init(done: 2, total: 5, unit: .steps)).detailText == "Step 2 of 5")
        #expect(OperationProgress(items: .init(done: 1, total: 2, unit: .services)).detailText == "Services: 1 of 2")
        #expect(OperationProgress(items: .init(done: 4, total: 9, unit: .items)).detailText == "4 of 9")
    }

    @Test func reportSetsProgressAndStopsAfterFinish() {
        let center = OperationCenter()
        let operation = center.begin(.pull, title: "Pull")
        operation.report(.init(items: .init(done: 1, total: 2, unit: .layers)), status: "Downloading")
        #expect(operation.fraction == 0.5)
        #expect(operation.progressText == "Downloading")
        // Without a structured fraction the given one counts.
        operation.report(.none, fraction: 0.3)
        #expect(operation.fraction == 0.3)
        #expect(operation.progressText == "Downloading")
        center.finish(operation, .succeeded(nil))
        operation.report(.init(items: .init(done: 2, total: 2, unit: .layers)))
        #expect(operation.progress == .none)
    }

    @Test func everyFeatureKindReachesTheFinishHook() {
        let center = OperationCenter()
        var finished: [OperationKind] = []
        center.onFinish = { finished.append($0.kind) }
        let kinds: [OperationKind] = [.pull, .build, .composeUp, .composeDown, .composePull]
        for kind in kinds {
            center.finish(center.begin(kind, title: kind.rawValue), .succeeded(nil))
        }
        #expect(finished == kinds)
    }

    @Test func cancelEndsAsCancelled() async {
        let center = OperationCenter()
        var states: [OperationState] = []
        center.onFinish = { states.append($0.state) }
        let operation = center.run(.composePull, title: "pull") { _ in
            try await Task.sleep(for: .seconds(60))
            return nil
        }
        center.cancel(operation)
        await operation.wait()
        #expect(states == [.cancelled])
    }
}
