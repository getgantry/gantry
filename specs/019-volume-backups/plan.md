<!-- STE deviation: spec-kit template headings, product names, Swift names, CLI flags and paths stay verbatim. -->
# Implementation Plan: Scheduled Volume Backups

**Branch**: `feat/volume-backups` | **Date**: 2026-11-21 | **Spec**: [spec.md](spec.md)

## Summary

The logic is in AppCore, in the new folder `Packages/AppCore/Sources/AppCore/Backups/`:

- `BackupSchedule.swift`: the `BackupSchedule` model (settings and run state), `BackupInterval`, `BackupResult`.
- `BackupSchedulePlan.swift`: pure functions. The latest and the next time of a schedule, "is due", the file name, the name pattern match, the files to delete, and the tar check.
- `BackupScheduleStore.swift`: an `@Observable` store of a JSON file, like `FolderVolumeStore`. `GANTRY_BACKUPS_PATH` replaces the path for tests of Debug builds.
- `BackupScheduler.swift`: an `@MainActor` scheduler. One task calls `tick(now:)` each 60 seconds and one time at start. This also gives the missed run at launch. Side effects go through the `BackupEnvironment` protocol, so the tests use a fake.
- `LiveBackupEnvironment.swift`: the live environment. It finds the `HostSession` in `AppModel`, does the disk checks (`DiskPresence`, `SystemStorageDiskReader`) and the file work.
- `HostSession+Backup.swift`: `backUpVolume(_:toFolder:fileName:)`. It waits for the connection (60 s at most), checks the free space against `volumeSizes`, and writes the archive.
  - Apple hosts: the helper job `VolumeTransferPlan.exportTar` of spec 004 (`container run … tar -cf`).
  - Docker hosts: Gantry creates the helper container with the volume at `/from` (read-only) and does not start it. It reads `GET /containers/{id}/archive?path=/from/.` and writes the stream to the local file. The entries are `./…`, the same as `tar -C /from .`, so "Import from Archive…" reads both. This works over SSH, because the bytes come through the Docker connection.
- SSHKit: `SSHDialStdioTransport.stream` now finishes a response that ends in the same chunks as its head. Before, the archive of a small volume over SSH never finished (found in the live check).
- `BackupAlert` in `BackupSchedule.swift`: the title and body of a failure notification.

The app:

- `ContainerNotifier.presentBackupFailure(_:)` posts the notification with the same `UNUserNotificationCenter` code as the container alerts.
- `App/Views/Backups/BackupScheduleSheet.swift`: the form. `VolumeListView` adds "Back Up on a Schedule…" to the menu of a volume, for all host kinds.
- `App/Views/Backups/BackupSettingsView.swift`: a "Backups" tab in Settings with the list, last run, result, next run, and the actions Back Up Now, Edit and Remove.
- `GantryApp.configureNotifications()` starts the scheduler.

## Constitution Check

- I (HIG): a standard sheet with a `Form`; a Settings tab with a `List`. Status uses text and a symbol, not only color.
- II (logic in packages): plan, store, scheduler and the Docker stream are in AppCore with Swift Testing tests. The views only present state.
- III (no required dependencies): it uses the helper image of spec 004 (`alpine`). No new CLI features.
- IV (data safety): Gantry deletes only recorded files that match the pattern, only after a checked new archive. Removing a schedule does not delete files. The schedules hold no secrets.
- V (strings): all new strings go into the catalogs with 28 languages.

## Files

- `Packages/AppCore/Sources/AppCore/Backups/*.swift`
- `Packages/AppCore/Sources/AppCore/Storage/HostSession+Storage.swift` (shared helper container create)
- `Packages/AppCore/Tests/AppCoreTests/BackupScheduleTests.swift`
- `Packages/SSHKit/Sources/SSHKit/SSHDialStdioTransport.swift`, `Packages/SSHKit/Tests/SSHKitTests/StreamHeadTests.swift`
- `App/Notifications/ContainerNotifier.swift`, `App/GantryApp.swift`
- `App/Views/Backups/*.swift`, `App/Views/Volumes/VolumeListView.swift`, `App/Views/SettingsView.swift`, `App/Views/Shared/AppleSettingsLink.swift`
- `App/Localizable.xcstrings`, `Packages/AppCore/Sources/AppCore/Resources/Localizable.xcstrings`
