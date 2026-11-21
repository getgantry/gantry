<!-- STE deviation: spec-kit template headings, task format, product names, Swift names, CLI flags and paths stay verbatim. -->
# Tasks: Scheduled Volume Backups

**Input**: `/specs/019-volume-backups/`

**Tests**: Swift Testing in AppCore (constitution principle II). Live checks on `nettop.local` (Docker) and on this Mac (Apple `container`) with the prefix `bak-`.

## Phase 1: Setup

- [x] T001 Set `.specify/feature.json` to `specs/019-volume-backups`; build output in `/Volumes/SanDisk2Tb/builds/gantry/volume-backups/`

## Phase 2: Model and plan (US1, US2)

- [x] T002 [US1] Add `BackupSchedule`, `BackupInterval`, `BackupResult` and `BackupAlert` in Packages/AppCore/Sources/AppCore/Backups/BackupSchedule.swift
- [x] T003 [US1] Add `BackupSchedulePlan`: latest and next time, `isDue`, file name, in Packages/AppCore/Sources/AppCore/Backups/BackupSchedulePlan.swift
- [x] T004 [US2] Add the exact name pattern match, `filesToDelete(existing:recorded:volume:keep:)` and the tar check in the same file
- [x] T005 [US1] Add `BackupScheduleStore` (JSON file, `GANTRY_BACKUPS_PATH`) in Packages/AppCore/Sources/AppCore/Backups/BackupScheduleStore.swift
- [x] T006 [US1] [US2] Unit tests for the plan and the store in Packages/AppCore/Tests/AppCoreTests/BackupScheduleTests.swift

## Phase 3: Run (US1, US2, US3)

- [x] T007 [US1] Add `BackupScheduler` (tick each 60 s and at start; partial file, check, rename; record; prune; failure callback) and the `BackupEnvironment` protocol in Packages/AppCore/Sources/AppCore/Backups/BackupScheduler.swift
- [x] T008 [US1] Add `HostSession.backUpVolume` (wait for the connection, free space, Apple helper job, Docker archive stream) in Packages/AppCore/Sources/AppCore/Backups/HostSession+Backup.swift
- [x] T009 [US3] Add `LiveBackupEnvironment` (host lookup, disk not connected, folder missing, file work) in Packages/AppCore/Sources/AppCore/Backups/LiveBackupEnvironment.swift
- [x] T010 [US1] [US2] [US3] Scheduler tests with a fake environment (due run, missed run at start, no rerun after a failure, prune only recorded files, no prune after a failure, partial file removed, alert on failure) in Packages/AppCore/Tests/AppCoreTests/BackupScheduleTests.swift

## Phase 4: App (US1, US3)

- [x] T011 [US3] Add `ContainerNotifier.presentBackupFailure(_:)` and start the scheduler in App/GantryApp.swift
- [x] T012 [US1] Add `BackupScheduleSheet` and the menu item "Back Up on a Schedule…" in App/Views/Backups/BackupScheduleSheet.swift and App/Views/Volumes/VolumeListView.swift
- [x] T013 [US3] Add the Settings tab "Backups" with last run, result and next run in App/Views/Backups/BackupSettingsView.swift
- [x] T014 Add all new strings with 28 languages; `python3 scripts/check-localization.py` shows 0 problems

## Phase 5: Checks

- [x] T023 Fix in Packages/SSHKit/Sources/SSHKit/SSHDialStdioTransport.swift: a streamed response that ends in the first chunks (a small archive) finished never; `StreamHead` records the end, and tests are in Packages/SSHKit/Tests/SSHKitTests/StreamHeadTests.swift
- [x] T024 Short failure text: `BackupSchedulePlan.shortMessage` removes the CLI progress lines

- [x] T015 Run the AppCore tests (934 passed) and the SSHKit tests without the live suites (51 passed)
- [x] T016 Build the app (Debug)
- [x] T017 SC-001: live run of a Debug build on `nettop.local` (Docker over SSH) writes the archive on this Mac
- [x] T018 SC-002: live run of a Debug build on the Apple `container` host writes the archive (folder on the internal disk; see T022 for the external disk)
- [x] T019 SC-003: keep = 2 deletes only the oldest recorded archives; other files stay
- [x] T020 Failure result: a folder on a disk that is not connected gives "The disk “bak-missing-disk” is not connected." in the stored result
- [ ] T021 Look at the failure banner and the Backups tab on the screen (not done: the GUI was not given to this work)
- [ ] T022 Apple host, folder on an external disk, from the app: the helper VM failed with "Failed to issue Fuse sandbox extension" after about 3 minutes. The same `container run` from Terminal works. Probably the macOS access of Gantry to the disk (TCC); check on a build that the user starts
