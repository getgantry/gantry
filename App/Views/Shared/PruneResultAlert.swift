import SwiftUI
import DockerKit

/// The outcome of a prune operation, used to drive a result alert. Identifiable
/// so it can back an `.alert(item:)` presentation.
struct PruneOutcome: Identifiable {
    let id = UUID()
    let title: String
    let result: PruneResult

    /// "N deleted, X freed" with a byte-count formatted reclaimed size.
    var summary: String {
        let freed = Formatters.bytes(result.spaceReclaimed, style: .file)
        let noun = result.deletedCount == 1 ? "item" : "items"
        return "\(result.deletedCount) \(noun) deleted, \(freed) freed"
    }
}

extension View {
    /// Presents a standard "prune complete" alert for a `PruneOutcome` binding.
    func pruneResultAlert(_ outcome: Binding<PruneOutcome?>) -> some View {
        alert(
            outcome.wrappedValue?.title ?? "Prune Complete",
            isPresented: Binding(presence: outcome),
            presenting: outcome.wrappedValue
        ) { _ in
            Button("OK", role: .cancel) { outcome.wrappedValue = nil }
        } message: { value in
            Text(value.summary)
        }
    }
}
