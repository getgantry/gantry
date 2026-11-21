<!-- STE deviation: spec-kit template headings, Given-When-Then scenarios, product names, file names and paths stay verbatim. -->
# Feature Specification: Scheduled Volume Backups

**Feature Branch**: `feat/volume-backups`
**Created**: 2026-11-21
**Status**: Implemented (live checks: see tasks.md)

**Input**: Add schedules for the volume export of spec 004 (`Export to Archive…`).

## User Scenarios and Testing

### User Story 1 - Back up a volume on a schedule (Priority: P1)

A user opens the menu of a volume and selects "Back Up on a Schedule…". The user selects a folder (it can be on an external disk), daily or weekly with a day, a time, and the number of copies to keep. While Gantry runs, it writes a tar archive of the volume into the folder at that time.

**Why this priority**: This is the feature.

**Independent Test**: Make a schedule for a test volume with a time in the past. Start Gantry. The archive `<volume>-<yyyyMMdd-HHmmss>.tar` is in the folder, and `tar -tf` lists the files of the volume.

**Acceptance Scenarios**:

1. **Given** a schedule that is due, **When** Gantry runs, **Then** Gantry writes the archive and records the last run and the result.
2. **Given** Gantry did not run at the time of a schedule, **When** Gantry starts, **Then** Gantry runs that backup one time.
3. **Given** a Docker host (local or over SSH) or an Apple `container` host, **When** the backup runs, **Then** the archive is in the folder on this Mac.

### User Story 2 - Keep only the last copies (Priority: P1)

After each successful run, Gantry deletes the oldest archives of that schedule above the number to keep.

**Independent Test**: Keep 2. Put three older archives of the schedule and one file `notes.tar` in the folder. Run the backup. Two archives of the schedule and `notes.tar` stay.

**Acceptance Scenarios**:

1. **Given** more archives than the number to keep, **When** a run succeeds, **Then** Gantry deletes the oldest ones.
2. **Given** files that do not match the name pattern of the schedule, or that the schedule did not write, **When** Gantry deletes old copies, **Then** these files stay.
3. **Given** a run failed, **When** the run ends, **Then** Gantry deletes nothing.

### User Story 3 - Know when a backup fails (Priority: P2)

When a backup fails (the disk is not connected, not enough free space, the host is offline), Gantry sends a macOS notification. The list of schedules in Settings shows the last run, the result and the next run of each schedule.

**Independent Test**: Make a schedule with a folder on a disk that is not connected. Start Gantry. The result is "The disk … is not connected", and a notification comes.

## Edge Cases

- A manual export of the same volume into the same folder has the same name pattern. Gantry deletes only names that the schedule recorded, so the manual export stays.
- Two hosts with the same volume name back up into one folder. Each schedule deletes only its own recorded files.
- A run fails in the middle. Gantry writes into a hidden `.partial` file first and removes it on a failure, so no broken archive gets the name of a backup.
- At launch the host is still connecting. Gantry waits up to 60 seconds before it says that the host is offline.
- On an Apple host, a volume that a running container uses cannot attach to the helper container (one volume per running VM). The run fails with the CLI error, and Gantry notifies the user.
- On an Apple host, the helper VM needs the macOS access of Gantry to the folder. Without it the run fails after a wait, and Gantry notifies the user.
- The host was removed. The run fails with "The host is not in Gantry".
- A failed run does not run again each minute. It runs again at the next scheduled time or with "Back Up Now".

## Requirements

- **FR-001**: A schedule MUST have the host, the volume, a folder, the interval (daily, or weekly on a day), a time, and the number of copies to keep (1 to 100).
- **FR-002**: The file name MUST be the archive name of the export with the date: `<volume>-<yyyyMMdd-HHmmss>.tar` (UTC).
- **FR-003**: Gantry MUST run a due backup while it runs, and MUST run a missed backup at launch. Gantry MUST NOT add a launchd agent or a helper tool.
- **FR-004**: After a successful run, Gantry MUST delete the oldest files of the schedule above the number to keep. It MUST delete only files whose names match the pattern of the schedule exactly and that the schedule wrote.
- **FR-005**: Gantry MUST use the disk checks of spec 004: disk not connected and free space.
- **FR-006**: When a run fails, Gantry MUST post a macOS notification with the notification code of the container failure alerts.
- **FR-007**: Gantry MUST show the last run, the result and the next run of each schedule.
- **FR-008**: Gantry MUST store the schedules in `~/Library/Application Support/Gantry/backup-schedules.json`, next to the other settings files. The file MUST NOT hold secrets.
- **FR-009**: Backups MUST work on Docker hosts (local and over SSH) and on Apple `container` hosts. The folder is always on this Mac.
- **FR-010**: Gantry MUST check the archive (a tar header and at least 1024 bytes) before it gives it the final name and before it deletes old copies.

## Success Criteria

- **SC-001**: A schedule on the Docker host `nettop.local` writes an archive into a folder on this Mac, and the archive holds the files of the volume.
- **SC-002**: A schedule on the Apple `container` host writes an archive with the files of the volume.
- **SC-003**: With keep = 2, the folder holds 2 archives of the schedule after the run, and other files stay.
