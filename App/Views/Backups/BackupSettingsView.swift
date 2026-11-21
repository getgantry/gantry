import SwiftUI
import AppCore

/// Settings → Backups: every schedule with its last run, result and next run.
struct BackupSettingsView: View {
    @State private var editing: BackupSchedule?
    private var store: BackupScheduleStore { .shared }

    var body: some View {
        Group {
            if store.schedules.isEmpty {
                ContentUnavailableView(
                    "No Backup Schedules",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Open the menu of a volume and choose Back Up on a Schedule….")
                )
            } else {
                List(store.schedules) { schedule in
                    BackupScheduleRow(schedule: schedule, editing: $editing)
                }
            }
        }
        .sheet(item: $editing) { BackupScheduleSheet(initial: $0) }
    }
}

private struct BackupScheduleRow: View {
    let schedule: BackupSchedule
    @Binding var editing: BackupSchedule?

    private var scheduler: BackupScheduler? { BackupSchedulerHost.shared }
    private var isRunning: Bool { scheduler?.running.contains(schedule.id) == true }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(schedule.volume) on \(schedule.hostName)").font(.headline)
                Text(schedule.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(BackupScheduleText.interval(schedule)).font(.caption)
                Text("Last run: \(BackupScheduleText.date(schedule.lastRun))").font(.caption)
                resultLabel
                Text("Next run: \(BackupScheduleText.date(scheduler?.nextRun(of: schedule)))").font(.caption)
            }
            Spacer()
            actions
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var resultLabel: some View {
        if isRunning {
            Label(String(localized: "Backing up…"), systemImage: "arrow.triangle.2.circlepath").font(.caption)
        } else if let result = schedule.lastResult {
            switch result {
            case .succeeded(let file):
                Label(String(localized: "Saved \(file)"), systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        Menu {
            Button(String(localized: "Back Up Now")) {
                Task { await scheduler?.run(id: schedule.id) }
            }
            .disabled(isRunning)
            Button(String(localized: "Edit…")) { editing = schedule }
            Divider()
            Button(String(localized: "Remove Schedule"), role: .destructive) {
                try? BackupScheduleStore.shared.remove(id: schedule.id)
            }
        } label: {
            Label(String(localized: "Actions"), systemImage: "ellipsis.circle")
        }
        .labelStyle(.iconOnly)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Removing a schedule keeps its archives in the folder."))
    }
}
