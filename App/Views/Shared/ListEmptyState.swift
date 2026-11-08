import SwiftUI

/// What a resource list shows over itself when it has no rows: an empty state
/// with the section's create action, or a no-results state for a filter.
struct ListEmptyState {
    var title: LocalizedStringKey
    var systemImage: String
    var description: LocalizedStringKey
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?
    /// More ways in, shown as plain buttons after the main action.
    var secondaryActions: [ListEmptyAction] = []
}

struct ListEmptyAction: Identifiable {
    let title: LocalizedStringKey
    let action: () -> Void
    var id: String { "\(title)" }
}

extension View {
    /// Overlays `empty` when the list has no items at all, and a search or
    /// filter no-results state when items exist but none match.
    /// - Parameters:
    ///   - total: item count before filtering; `filtered`: after filtering.
    ///   - loaded: false until the first listing arrived (shows nothing yet).
    func listEmptyState(
        _ empty: ListEmptyState,
        total: Int,
        filtered: Int,
        search: String,
        loaded: Bool = true
    ) -> some View {
        overlay {
            if !loaded {
                EmptyView()
            } else if total == 0 {
                ListEmptyStateView(state: empty)
            } else if filtered == 0 {
                ListNoResultsView(search: search)
            }
        }
    }

    /// ⌘F focuses this search field. For search fields that are not a
    /// toolbar `.searchable`, which gets ⌘F from the system.
    func findShortcut(_ focus: FocusState<Bool>.Binding) -> some View {
        background {
            Button("Find") { focus.wrappedValue = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
    }
}

struct ListEmptyStateView: View {
    let state: ListEmptyState

    var body: some View {
        ContentUnavailableView {
            Label(state.title, systemImage: state.systemImage)
        } description: {
            Text(state.description)
        } actions: {
            HStack(spacing: Spacing.xs) {
                if let title = state.actionTitle, let action = state.action {
                    Button(title, action: action)
                        .buttonStyle(.borderedProminent)
                }
                ForEach(state.secondaryActions) { item in
                    Button(item.title, action: item.action)
                }
            }
        }
    }
}

struct ListNoResultsView: View {
    let search: String

    var body: some View {
        if search.isEmpty {
            ContentUnavailableView(
                "No Matches",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("No item matches the current filter.")
            )
        } else {
            ContentUnavailableView.search(text: search)
        }
    }
}
