import SwiftUI

extension Binding where Value == Bool {
    /// A `Bool` binding that reads `true` when an optional source holds a value
    /// and, when set to `false`, clears the source to `nil`. Setting it to
    /// `true` is a no-op (there is nothing to invent).
    ///
    /// Collapses the recurring
    /// `Binding(get: { x != nil }, set: { if !$0 { x = nil } })` boilerplate
    /// used to drive `.alert`/`.confirmationDialog`/`.sheet(isPresented:)` from
    /// optional state.
    @MainActor
    init<Wrapped>(presence source: Binding<Wrapped?>) {
        self.init(
            get: { source.wrappedValue != nil },
            set: { if !$0 { source.wrappedValue = nil } }
        )
    }
}
