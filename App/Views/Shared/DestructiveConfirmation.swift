import SwiftUI
import AppCore

/// One confirmation for every remove, delete and service stop: the impact
/// text, a Force button where the engine has one, Touch ID when it is on in
/// Settings, and the Delete key to start it.
struct DestructiveConfirmation: ViewModifier {
    @Binding var action: DestructiveAction?
    /// Builds the action for the Delete key from the current selection.
    let onDelete: (() -> DestructiveAction?)?
    let perform: @MainActor (DestructiveAction, _ force: Bool) async -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                action.map(DestructiveActionText.title) ?? "",
                isPresented: Binding(presence: $action),
                titleVisibility: .visible,
                presenting: action
            ) { action in
                buttons(for: action)
            } message: { action in
                Text(DestructiveActionText.message(action))
            }
            .modifier(DeleteCommand(handler: onDelete.map { make in { self.action = make() } }))
    }

    @ViewBuilder
    private func buttons(for action: DestructiveAction) -> some View {
        Button(DestructiveActionText.confirmLabel(action), role: .destructive) {
            run(action, force: false)
        }
        if action.forceAvailable {
            Button(DestructiveActionText.forceLabel(action), role: .destructive) {
                run(action, force: true)
            }
        }
        Button(String(localized: "Cancel"), role: .cancel) {}
    }

    private func run(_ action: DestructiveAction, force: Bool) {
        self.action = nil
        Task { @MainActor in
            if action.isGated {
                guard await BiometricGate.confirm(DestructiveActionText.reason(action)) else { return }
            }
            await perform(action, force)
        }
    }
}

/// Adds `onDeleteCommand` only when there is a handler, so a list without
/// a selection keeps its Delete menu item disabled.
private struct DeleteCommand: ViewModifier {
    let handler: (() -> Void)?

    func body(content: Content) -> some View {
        if let handler {
            content.onDeleteCommand(perform: handler)
        } else {
            content
        }
    }
}

extension View {
    /// Presents `action` with the shared destructive confirmation.
    func destructiveConfirmation(
        _ action: Binding<DestructiveAction?>,
        onDelete: (() -> DestructiveAction?)? = nil,
        perform: @escaping @MainActor (DestructiveAction, _ force: Bool) async -> Void
    ) -> some View {
        modifier(DestructiveConfirmation(action: action, onDelete: onDelete, perform: perform))
    }
}
