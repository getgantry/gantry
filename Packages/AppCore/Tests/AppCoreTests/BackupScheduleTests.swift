import Foundation
import Testing
@testable import AppCore

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func date(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

private func schedule(
    interval: BackupInterval = .daily, hour: Int = 3, minute: Int = 0, keep: Int = 2,
    created: String = "2026-11-01T00:00:00Z", lastRun: String? = nil, files: [String] = []
) -> BackupSchedule {
    BackupSchedule(
        hostID: UUID(), hostName: "nettop", volume: "bak-data", folder: "/Volumes/Backup/gantry/",
        interval: interval, hour: hour, minute: minute, keep: keep,
        createdAt: date(created), lastRun: lastRun.map(date), files: files
    )
}

@Suite("Backup schedule plan")
struct BackupSchedulePlanTests {
    @Test func dailyOccurrences() {
        let item = schedule()
        let now = date("2026-11-21T10:00:00Z")
        #expect(BackupSchedulePlan.latestOccurrence(of: item, atOrBefore: now, calendar: utc) == date("2026-11-21T03:00:00Z"))
        #expect(BackupSchedulePlan.nextOccurrence(of: item, after: now, calendar: utc) == date("2026-11-22T03:00:00Z"))
    }

    @Test func weeklyOccurrences() {
        // 2026-11-21 is a Saturday; weekday 2 is Monday.
        let item = schedule(interval: .weekly(weekday: 2), hour: 22, minute: 30)
        let now = date("2026-11-21T10:00:00Z")
        #expect(BackupSchedulePlan.latestOccurrence(of: item, atOrBefore: now, calendar: utc) == date("2026-11-16T22:30:00Z"))
        #expect(BackupSchedulePlan.nextOccurrence(of: item, after: now, calendar: utc) == date("2026-11-23T22:30:00Z"))
    }

    @Test func dueAfterAMissedTime() {
        let now = date("2026-11-21T10:00:00Z")
        #expect(BackupSchedulePlan.isDue(schedule(lastRun: "2026-11-19T03:00:05Z"), now: now, calendar: utc))
        #expect(!BackupSchedulePlan.isDue(schedule(lastRun: "2026-11-21T03:00:05Z"), now: now, calendar: utc))
        // A new schedule waits for its first time.
        #expect(!BackupSchedulePlan.isDue(schedule(created: "2026-11-21T09:00:00Z"), now: now, calendar: utc))
        #expect(BackupSchedulePlan.nextRun(of: schedule(lastRun: "2026-11-19T03:00:00Z"), now: now, calendar: utc) == now)
    }

    @Test func fileNameMatchesTheExportName() {
        let name = BackupSchedulePlan.fileName(volume: "bak-data", date: date("2026-11-21T03:00:00Z"))
        #expect(name == "bak-data-20261121-030000.tar")
        #expect(BackupSchedulePlan.archiveDate(of: name, volume: "bak-data") == date("2026-11-21T03:00:00Z"))
        #expect(BackupSchedulePlan.partialName(for: name) == ".bak-data-20261121-030000.tar.partial")
    }

    @Test func patternIsExact() {
        let volume = "bak-data"
        #expect(BackupSchedulePlan.archiveDate(of: "bak-data-1-20261121-030000.tar", volume: volume) == nil)
        #expect(BackupSchedulePlan.archiveDate(of: "bak-data-20261121-030000.tar.partial", volume: volume) == nil)
        #expect(BackupSchedulePlan.archiveDate(of: "bak-data-20261121030000.tar", volume: volume) == nil)
        #expect(BackupSchedulePlan.archiveDate(of: "bak-data-2026112a-030000.tar", volume: volume) == nil)
        #expect(BackupSchedulePlan.archiveDate(of: "notes.tar", volume: volume) == nil)
        #expect(BackupSchedulePlan.archiveDate(of: "bak-data-20261121-030000.tar", volume: "bak") == nil)
    }

    @Test func deletesOnlyOldRecordedArchives() {
        let existing = [
            "bak-data-20261118-030000.tar", "bak-data-20261119-030000.tar",
            "bak-data-20261120-030000.tar", "bak-data-20261121-030000.tar",
            "bak-data-20261101-120000.tar", "notes.tar"
        ]
        let recorded = Array(existing.prefix(4)) + ["notes.tar"]
        let delete = BackupSchedulePlan.filesToDelete(existing: existing, recorded: recorded, volume: "bak-data", keep: 2)
        #expect(Set(delete) == ["bak-data-20261118-030000.tar", "bak-data-20261119-030000.tar"])
    }

    @Test func tarCheck() {
        var header = Data(count: 512)
        header.replaceSubrange(257..<262, with: Data("ustar".utf8))
        #expect(BackupSchedulePlan.looksLikeTar(size: 10_240, header: header))
        #expect(!BackupSchedulePlan.looksLikeTar(size: 512, header: header))
        #expect(!BackupSchedulePlan.looksLikeTar(size: 10_240, header: Data(count: 512)))
    }

    @Test func shortMessageDropsProgressLines() {
        let raw = "[0/6] [0s]\n[6/6] Starting container [0s]\n[6/6] Starting container [1s]\nError: failed to bootstrap container"
        #expect(BackupSchedulePlan.shortMessage(raw) == "Error: failed to bootstrap container")
        #expect(BackupSchedulePlan.shortMessage("The host nettop is offline.") == "The host nettop is offline.")
        #expect(BackupSchedulePlan.shortMessage(String(repeating: "x", count: 500)).count == 401)
    }

    @Test func keepIsClamped() {
        #expect(schedule(keep: 0).keep == 1)
        #expect(schedule(keep: 500).keep == 100)
    }
}

@MainActor
@Suite("Backup schedule store")
struct BackupScheduleStoreTests {
    @Test func savesAndLoads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bak-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var item = schedule(interval: .weekly(weekday: 3))
        item.lastResult = .failed(message: "offline")
        try BackupScheduleStore(fileURL: url).upsert(item)
        let loaded = BackupScheduleStore(fileURL: url)
        #expect(loaded.schedules == [item])
        try loaded.remove(id: item.id)
        #expect(BackupScheduleStore(fileURL: url).schedules.isEmpty)
    }
}

/// A folder in memory and a scripted export.
@MainActor
private final class FakeBackupEnvironment: BackupEnvironment {
    var files: [String: Data] = [:]
    var problem: String?
    var exportError: Error?
    var writesTar = true
    var exports = 0

    static var tar: Data {
        var data = Data(count: 2048)
        data.replaceSubrange(257..<262, with: Data("ustar".utf8))
        return data
    }

    func folderProblem(_ folder: String) async -> String? { problem }

    func export(_ schedule: BackupSchedule, fileName: String) async throws {
        exports += 1
        if let exportError { throw exportError }
        files[schedule.folder + "/" + fileName] = writesTar ? Self.tar : Data("oops".utf8)
    }

    func listFiles(in folder: String) async throws -> [String] {
        files.keys.filter { ($0 as NSString).deletingLastPathComponent == folder }
            .map { ($0 as NSString).lastPathComponent }
    }

    func fileHeader(_ path: String) async throws -> (size: Int64, header: Data) {
        let data = files[path] ?? Data()
        return (Int64(data.count), data.prefix(512))
    }

    func moveFile(_ from: String, to: String) async throws {
        files[to] = files.removeValue(forKey: from)
    }

    func removeFile(_ path: String) async throws {
        guard files.removeValue(forKey: path) != nil else { throw CocoaError(.fileNoSuchFile) }
    }
}

@MainActor
@Suite("Backup scheduler")
struct BackupSchedulerTests {
    let folder = "/Volumes/Backup/gantry"

    private func make(_ item: BackupSchedule) throws -> (BackupScheduler, FakeBackupEnvironment, BackupScheduleStore) {
        let store = BackupScheduleStore(fileURL: nil)
        try store.upsert(item)
        let environment = FakeBackupEnvironment()
        return (BackupScheduler(store: store, environment: environment, calendar: utc), environment, store)
    }

    @Test func missedRunAtStartWritesTheArchive() async throws {
        let item = schedule(lastRun: "2026-11-19T03:00:00Z")
        let (scheduler, environment, store) = try make(item)
        let now = date("2026-11-21T10:00:00Z")
        await scheduler.tick(now: now)
        let name = "bak-data-20261121-100000.tar"
        #expect(environment.files.keys.sorted() == [folder + "/" + name])
        let saved = try #require(store.schedule(id: item.id))
        #expect(saved.lastRun == now)
        #expect(saved.lastResult == .succeeded(file: name))
        #expect(saved.files == [name])
        // The next tick in the same day does nothing.
        await scheduler.tick(now: now.addingTimeInterval(60))
        #expect(environment.exports == 1)
    }

    @Test func keepsTheNewestAndOtherFiles() async throws {
        let old = ["bak-data-20261118-030000.tar", "bak-data-20261119-030000.tar", "bak-data-20261120-030000.tar"]
        let item = schedule(lastRun: "2026-11-20T03:00:00Z", files: old)
        let (scheduler, environment, store) = try make(item)
        for name in old + ["notes.tar", "bak-data-20261101-120000.tar"] { environment.files[folder + "/" + name] = Data() }
        await scheduler.tick(now: date("2026-11-21T03:00:10Z"))
        let names = Set(environment.files.keys.map { ($0 as NSString).lastPathComponent })
        #expect(names == ["bak-data-20261120-030000.tar", "bak-data-20261121-030010.tar", "notes.tar", "bak-data-20261101-120000.tar"])
        #expect(store.schedule(id: item.id)?.files == ["bak-data-20261120-030000.tar", "bak-data-20261121-030010.tar"])
    }

    @Test func failureNotifiesAndDeletesNothing() async throws {
        let old = ["bak-data-20261118-030000.tar", "bak-data-20261119-030000.tar", "bak-data-20261120-030000.tar"]
        let item = schedule(keep: 1, lastRun: "2026-11-20T03:00:00Z", files: old)
        let (scheduler, environment, store) = try make(item)
        for name in old { environment.files[folder + "/" + name] = Data() }
        environment.exportError = BackupFailure.hostOffline("nettop")
        var alerts: [BackupAlert] = []
        scheduler.onFailure = { alerts.append($0) }
        let now = date("2026-11-21T03:00:10Z")
        await scheduler.tick(now: now)
        #expect(environment.files.count == 3)
        #expect(alerts.count == 1)
        #expect(alerts.first?.message == BackupFailure.hostOffline("nettop").errorDescription)
        #expect(store.schedule(id: item.id)?.lastResult?.isFailure == true)
        // No new attempt each minute after a failure.
        await scheduler.tick(now: now.addingTimeInterval(60))
        #expect(environment.exports == 1)
    }

    @Test func missingDiskFailsBeforeTheExport() async throws {
        let (scheduler, environment, store) = try make(schedule(lastRun: "2026-11-19T03:00:00Z"))
        environment.problem = StorageIssue.missing("Backup").message
        await scheduler.tick(now: date("2026-11-21T10:00:00Z"))
        #expect(environment.exports == 0)
        #expect(store.schedules.first?.lastResult == .failed(message: StorageIssue.missing("Backup").message))
    }

    @Test func brokenArchiveIsRemoved() async throws {
        let (scheduler, environment, store) = try make(schedule(lastRun: "2026-11-19T03:00:00Z"))
        environment.writesTar = false
        await scheduler.tick(now: date("2026-11-21T10:00:00Z"))
        #expect(environment.files.isEmpty)
        #expect(store.schedules.first?.lastResult == .failed(message: BackupFailure.notAnArchive.errorDescription!))
        #expect(store.schedules.first?.files.isEmpty == true)
    }

    @Test func runNowIgnoresTheTime() async throws {
        let item = schedule(created: "2026-11-21T09:00:00Z")
        let (scheduler, environment, _) = try make(item)
        await scheduler.run(id: item.id, now: date("2026-11-21T10:00:00Z"))
        #expect(environment.exports == 1)
    }

    @Test func alertText() {
        let alert = BackupAlert(scheduleID: UUID(), hostName: "nettop", volume: "bak-data", message: "The host nettop is offline.")
        #expect(alert.title == "Backup failed")
        #expect(alert.body.contains("bak-data") && alert.body.contains("nettop"))
    }
}
