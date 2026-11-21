import Foundation
import AppCore

/// The one scheduler of the app. It starts with the notifications.
@MainActor
enum BackupSchedulerHost {
    private(set) static var shared: BackupScheduler?

    static func start(model: AppModel, onFailure: @escaping (BackupAlert) -> Void) {
        guard shared == nil else { return }
        let scheduler = BackupScheduler(store: .shared, environment: LiveBackupEnvironment(model: model))
        scheduler.onFailure = onFailure
        shared = scheduler
        scheduler.start()
    }
}

/// Texts for a schedule, shared by the sheet and the Settings list.
enum BackupScheduleText {
    static func time(hour: Int, minute: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func weekdayName(_ weekday: Int) -> String {
        let names = Calendar.current.weekdaySymbols
        return names.indices.contains(weekday - 1) ? names[weekday - 1] : ""
    }

    static func interval(_ schedule: BackupSchedule) -> String {
        let time = time(hour: schedule.hour, minute: schedule.minute)
        switch schedule.interval {
        case .daily:
            return String(localized: "Daily at \(time)")
        case .weekly(let weekday):
            return String(localized: "Weekly on \(weekdayName(weekday)) at \(time)")
        }
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return String(localized: "Never") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
