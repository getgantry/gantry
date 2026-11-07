import SwiftUI
import AppCore
import DockerKit

/// Lists the disks that can take the data root, checks the chosen one, and
/// starts the move after a confirmation.
struct MoveDataRootSheet: View {
    let session: HostSession
    let overview: StorageOverview
    let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var targets: [MoveTarget] = []
    @State private var selection: String?
    @State private var loading = true
    @State private var confirm: DestructiveAction?

    struct MoveTarget: Identifiable {
        let disk: StorageDisk
        let plan: Result<DataRootMovePlan, DataRootMoveError>
        var id: String { disk.id }
        var isCurrent: Bool { if case .failure(.sameLocation) = plan { true } else { false } }
    }

    private var size: StorageSize { overview.usage?.total ?? StorageSize() }
    private var selected: MoveTarget? { targets.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move Container Data").font(.title2.weight(.bold))
            Text("Gantry copies \(StorageFormat.bytes(size.allocated)) to the disk you choose, checks the copy, and then uses it. The original stays until you delete it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            diskList
            if let selected { MoveTargetDetail(target: selected) }
            footer
        }
        .padding(20)
        .frame(width: 520)
        .task { await loadTargets() }
        .destructiveConfirmation($confirm) { _, _ in start() }
    }

    private var diskList: some View {
        List(selection: $selection) {
            ForEach(targets) { target in
                MoveTargetRow(target: target).tag(target.id)
            }
        }
        .frame(height: 180)
        .overlay { if loading { ProgressView() } }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Move…")) {
                guard case .success(let plan)? = selected?.plan else { return }
                let running = session.containers.filter { $0.state.isRunning }.count
                confirm = .moveDataRoot(to: plan.destination, runningContainers: running)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canMove)
        }
    }

    private var canMove: Bool {
        if case .success? = selected?.plan { return true }
        return false
    }

    private func loadTargets() async {
        let source = overview.configuredRoot.effectivePath
        targets = await StorageOverview.moveTargets(size: size, source: source)
            .map { MoveTarget(disk: $0.disk, plan: $0.plan) }
        selection = targets.first { if case .success = $0.plan { true } else { false } }?.id
        loading = false
    }

    private func start() {
        guard case .success(let plan)? = selected?.plan, let center = session.operations else { return }
        DataRootMoveOperation.start(
            plan,
            totalBytes: size.allocated,
            center: center,
            hostName: session.host.name,
            environment: LiveDataRootMoveEnvironment(cliOverride: session.appleCLIOverride)
        ) { _ in
            onFinish()
            Task { await session.connect() }
        }
        NotificationCenter.default.post(name: .gantryShowActivity, object: nil)
        dismiss()
    }
}

/// One disk in the move list: name, space, and whether it can be used.
private struct MoveTargetRow: View {
    let target: MoveDataRootSheet.MoveTarget

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: StoragePlacementText.systemImage(target.disk.placement))
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.disk.name).font(.headline)
                Text("\(target.disk.formatDescription) · \(StoragePlacementText.title(target.disk.placement)) · \(StorageFormat.bytes(target.disk.availableBytes)) free")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            status
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var status: some View {
        switch target.plan {
        case .success(let plan) where plan.warnings.isEmpty:
            Label(String(localized: "Ready"), systemImage: "checkmark.circle").foregroundStyle(.green)
        case .success:
            Label(String(localized: "Warning"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .failure where target.isCurrent:
            Label(String(localized: "Current"), systemImage: "smallcircle.filled.circle").foregroundStyle(.secondary)
        case .failure:
            Label(String(localized: "Not usable"), systemImage: "xmark.circle").foregroundStyle(.red)
        }
    }
}

/// The destination and the findings of the selected disk.
private struct MoveTargetDetail: View {
    let target: MoveDataRootSheet.MoveTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch target.plan {
            case .success(let plan):
                LabeledContent(String(localized: "New folder")) {
                    Text(verbatim: plan.destination).font(.callout.monospaced()).textSelection(.enabled)
                }
                LabeledContent(String(localized: "Space needed")) { Text(StorageFormat.bytes(plan.requiredBytes)) }
                ForEach(plan.warnings, id: \.self) { issue in
                    Label(issue.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            case .failure(let error):
                Label(error.errorDescription ?? "", systemImage: "xmark.octagon").foregroundStyle(.red)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}
