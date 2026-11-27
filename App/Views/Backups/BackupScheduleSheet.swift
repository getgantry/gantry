import SwiftUI
import AppCore

/// Makes or edits the backup schedule of one volume.
struct BackupScheduleSheet: View {
    let initial: BackupSchedule

    @Environment(\.dismiss) private var dismiss
    @State private var folder = ""
    @State private var weekly = false
    @State private var weekday = 2
    @State private var time = Date()
    @State private var keep = 7
    @State private var check: StorageCheck?
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Back Up “\(initial.volume)” on a Schedule").font(.title2.weight(.bold))
            Form {
                folderSection
                scheduleSection
            }
            .formStyle(.grouped)
            Text("Gantry runs the backup while it is open. When Gantry was closed at the time of a backup, it runs the backup at the next launch.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let saveError { Label(saveError, systemImage: "xmark.octagon").foregroundStyle(.red) }
            footer
        }
        .padding(20)
        .frame(width: 500)
        .onAppear(perform: load)
        .task(id: folder) { await checkFolder() }
    }

    private var folderSection: some View {
        Section {
            LabeledContent(String(localized: "Folder")) {
                HStack {
                    Text(folder.isEmpty ? String(localized: "None") : folder)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(folder.isEmpty ? .secondary : .primary)
                    Button(String(localized: "Choose…"), action: chooseFolder)
                }
            }
            ForEach(check?.issues ?? [], id: \.self) { issue in
                Label(issue.message, systemImage: issue.isBlocking ? "xmark.octagon" : "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(issue.isBlocking ? .red : .orange)
            }
        }
    }

    private var scheduleSection: some View {
        Section {
            Picker(String(localized: "Repeat"), selection: $weekly) {
                Text("Daily").tag(false)
                Text("Weekly").tag(true)
            }
            if weekly {
                Picker(String(localized: "Day"), selection: $weekday) {
                    ForEach(1...7, id: \.self) { Text(BackupScheduleText.weekdayName($0)).tag($0) }
                }
            }
            DatePicker(String(localized: "Time"), selection: $time, displayedComponents: .hourAndMinute)
            Stepper(value: $keep, in: BackupSchedule.keepRange) {
                Text("Keep \(keep) copies")
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(String(localized: "Save"), action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(folder.isEmpty || check?.isAllowed == false)
        }
    }

    private func load() {
        folder = initial.folder
        keep = initial.keep
        if case .weekly(let day) = initial.interval { weekly = true; weekday = day }
        time = Calendar.current.date(bySettingHour: initial.hour, minute: initial.minute, second: 0, of: Date()) ?? Date()
    }

    private func chooseFolder() {
        if let url = StorageFolderPanel.chooseFolder(prompt: String(localized: "Choose"), start: folder) {
            folder = url.path
        }
    }

    private func checkFolder() async {
        guard !folder.isEmpty else { check = nil; return }
        let result = await StorageCheckLoader.folderVolume(path: folder)
        // A backup folder needs no owners; keep only the useful findings.
        check = StorageCheck(issues: result.issues.filter { $0 != .ignoresOwnership })
    }

    private func save() {
        var schedule = initial
        schedule.folder = StoragePaths.normalized(folder)
        schedule.interval = weekly ? .weekly(weekday: weekday) : .daily
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        schedule.hour = parts.hour ?? 3
        schedule.minute = parts.minute ?? 0
        schedule.keep = keep
        do {
            try BackupScheduleStore.shared.upsert(schedule)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
