import SwiftUI
import AppCore
import DockerKit

/// The mark of a container whose tag has a newer image in the registry.
struct ImageUpdateBadge: View {
    /// A symbol only, for list rows where the name needs the width.
    var compact = false

    var body: some View {
        if compact {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(Text("Update Available"))
                .help("The registry has a newer image for this tag.")
        } else {
            pill
        }
    }

    private var pill: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 9))
            Text("Update Available")
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.16), in: .capsule)
        .foregroundStyle(Color.accentColor)
        .accessibilityElement(children: .combine)
        .help("The registry has a newer image for this tag.")
    }
}

/// "Update Container…" for a container with the mark.
struct ContainerUpdateMenuItem: View {
    let container: ContainerSummary
    let session: HostSession
    @Binding var target: ContainerSummary?

    var body: some View {
        if session.imageUpdateStatus(for: container) == .updateAvailable,
           session.clusterNodeCluster(container.id) == nil {
            Button {
                target = container
            } label: {
                Label("Update Container…", systemImage: "arrow.down.circle")
            }
        }
    }
}

/// "Check for Image Updates": asks the registry now for every container.
struct CheckImageUpdatesButton: View {
    let session: HostSession

    var body: some View {
        Button {
            Task { await session.checkImageUpdates(force: true) }
        } label: {
            Label("Check for Image Updates", systemImage: "arrow.triangle.2.circlepath.circle")
        }
    }
}

/// Asks before an update: the shared confirmation for a standalone
/// container, an explanation with Pull Images for a Compose container.
private struct ContainerUpdateConfirmation: ViewModifier {
    @Binding var target: ContainerSummary?
    let session: HostSession
    @State private var action: DestructiveAction?
    @State private var composeTarget: ContainerSummary?

    func body(content: Content) -> some View {
        content
            .onChange(of: target) { _, new in
                guard let new else { return }
                target = nil
                if new.composeProject != nil { composeTarget = new } else { action = .updateContainer(new) }
            }
            .destructiveConfirmation($action) { action, _ in
                guard let id = action.targets.first,
                      let container = session.containers.first(where: { $0.id == id }) else { return }
                session.updateContainer(container)
            }
            .alert("Update the Compose Project", isPresented: Binding(presence: $composeTarget), presenting: composeTarget) { container in
                Button("Pull Images") { _ = session.composePull(project: container.composeProject ?? "") }
                Button("Cancel", role: .cancel) {}
            } message: { container in
                Text("“\(container.displayName)” is a service of the Compose project “\(container.composeProject ?? "")”. Pull the images of the project, then run Compose up for the project again.")
            }
    }
}

extension View {
    func containerUpdateConfirmation(_ target: Binding<ContainerSummary?>, session: HostSession) -> some View {
        modifier(ContainerUpdateConfirmation(target: target, session: session))
    }
}
