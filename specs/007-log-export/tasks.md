<!-- STE deviation: spec-kit template headings, task IDs, type names, menu titles and paths stay verbatim. A task is one checklist line, and the tasks generator quotes the constraints of data-model.md in it, so a task line can be longer than 25 words. -->
# Tasks: Export Container Logs with the Current Filter

**Input**: Design documents from `/specs/007-log-export/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/ui.md, quickstart.md

**Tests**: The constitution (principle II) requires Swift Testing tests for all AppCore logic.

## Phase 1: Setup <!-- slop: spec-kit template heading -->

- [x] T001 Set `.specify/feature.json` to `specs/007-log-export` and check that `/Volumes/SanDisk2Tb/builds/gantry/log-export/` is the build folder

## Phase 2: Foundational (AppCore logic, blocks all stories)

- [x] T002 Add `LogExportLine`, `LogTimeRange`, `LogLineFilter`, `LogExportFormat`, `LogExportSink`, `FileHandleSink`, `LogExportWriter` and `LogExportFileName` in `Packages/AppCore/Sources/AppCore/LogExport.swift` as `data-model.md` tells. Rules to keep: "a line with no level fails when `minLevel` is set"; "`contains` is true for nil dates and for `all`"; query only filters when `matchesOnly` is true; timestamp format RFC 3339 UTC with milliseconds; source prefix `<source> | `; chunk size 65 536 bytes; file name `<safe base>-yyyy-MM-dd-HHmm.<ext>` with `/ \ : * ? " < > |` and control characters replaced by `-`, `logs` for an empty base
- [x] T003 Add the time range titles to `Packages/AppCore/Sources/AppCore/Resources/Localizable.xcstrings` with 28 languages
- [x] T004 [P] Add tests in `Packages/AppCore/Tests/AppCoreTests/LogExportTests.swift`: filter rules and order, invalid regex, time range with nil dates, format with and without timestamps and sources, writer chunking (more than one flush, no line split, exact bytes), line count, empty input, file name sanitizing, 50 000-line write with a counting sink
- [x] T005 Run the AppCore tests with `--filter LogExport` and the scratch path `/Volumes/SanDisk2Tb/builds/gantry/log-export/appcore`

## Phase 3: User Story 1 - Export the visible log lines to a file (P1)

**Goal**: The Logs tab exports its visible lines through the save panel.

**Independent Test**: Filter the Logs tab, export, compare the file with the view.

- [x] T006 [US1] Add `LogExportItem` (`Transferable`, representations `.log` and `.plainText`) and `LogExportButton` in `App/Views/Containers/LogExportControls.swift`
- [x] T007 [US1] Make `LogsView` keep `timestamp` in `DisplayLine`, compute `visibleLines` with `LogLineFilter`, and add the Export button, the `fileExporter` and the error banner for a failed export in `App/Views/Containers/LogsView.swift`

## Phase 4: User Story 2 - Copy the visible lines (P1)

**Goal**: Copy Visible Lines puts the export text on the pasteboard.

**Independent Test**: Filter, copy, paste, compare.

- [x] T008 [US2] Replace Copy all with Copy Visible Lines (`LogExportFormat.text`) and disable it with 0 visible lines in `App/Views/Containers/LogsView.swift`

## Phase 5: User Story 3 - Timestamps and time range (P2)

**Goal**: The display menu turns timestamps on and sets the time range. Apple hosts get disabled items with a reason.

**Independent Test**: On a Docker host, turn on timestamps, export, check prefixes. On an Apple host, check the disabled items and the help text.

- [x] T009 [US3] Add `LogDisplayMenu` (Show Timestamps toggle, Time Range picker, disabled with help "This host does not report log times" when no line has a timestamp) in `App/Views/Containers/LogExportControls.swift`
- [x] T010 [US3] Add the display menu and the timestamp column (local `HH:mm:ss.SSS`) to `App/Views/Containers/LogsView.swift`

## Phase 6: User Story 4 - Export the logs of a Compose project (P2)

**Goal**: Stack logs export with the service prefix and the hidden services left out.

**Independent Test**: Hide a service, export, check the file.

- [x] T011 [US4] Make `StackLogsView` keep `timestamp`, use `LogLineFilter` (with `matchesOnly: true` and `hiddenSources`), add the display menu, Copy Visible Lines, the Export button and the `fileExporter` with `sources: true` in `App/Views/Containers/StackLogsView.swift`

## Phase 7: User Story 5 - Menu, shortcut and command palette (P3)

**Goal**: File > Export Logs… (Shift-Command-E), Edit > Copy Visible Log Lines and the palette action.

**Independent Test**: Press Shift-Command-E in a Logs tab. Run Export Logs… from the palette.

- [x] T012 [US5] Add `LogExportTarget`, the `FocusedValues` entry `logExportTarget` and `LogCommands` (File after `.importExport`, Edit after `.pasteboard`) in `App/Views/Containers/LogExportControls.swift`, and add `LogCommands()` in `App/GantryApp.swift`
- [x] T013 [US5] Publish `logExportTarget` with `focusedSceneValue` from `LogsView` and `StackLogsView`
- [x] T014 [US5] Add `PaletteAction.exportLogs` ("Export Logs…", `square.and.arrow.up`) after `.logs` in `containerActions` in `Packages/AppCore/Sources/AppCore/Palette/PaletteItem.swift` and `PaletteCatalog.swift`, with the string in the AppCore catalog
- [x] T015 [P] [US5] Update the palette tests for the new action order in `Packages/AppCore/Tests/AppCoreTests/CommandPaletteTests.swift`
- [x] T016 [US5] Add `ContainerTabRequest.Tab.exportLogs` in `App/Views/Containers/ContainerFormComponents.swift`, open the Logs tab for it in `App/Views/Containers/ContainerDetailView.swift`, take it in `LogsView` and open the save panel, and route `.exportLogs` in `App/Views/Palette/PaletteRunner.swift`

## Phase 8: Polish and cross-cutting

- [x] T017 Add all new app strings with 28 languages to `App/Localizable.xcstrings` and run `scripts/check-localization.py` (0 problems)
- [x] T018 Build the Debug app with `xcodebuild -jobs 3 -derivedDataPath /Volumes/SanDisk2Tb/builds/gantry/log-export/DerivedData`
- [x] T019 Run the AppCore tests that this feature touches (`LogExport`, `CommandPalette`)
- [x] T020 Live check on the Apple host as `quickstart.md` tells: filter, export (file content), copy, disabled timestamp items, palette action, Shift-Command-E. Remove the test containers `gle-*`
- [x] T021 Live check of timestamps and the time range on a Docker host
- [x] T023 Fix the defects of the live check in `App/Views/Containers/LogExportControls.swift` and `App/Views/Containers/LogsView.swift` (see Status)
- [x] T022 Rebase on `origin/main`, push `feat/log-export` and open the pull request "feat: export container logs with the current filter"

## Status (2026-11-14)

- T001 to T019 are done. The code builds (Debug, `xcodebuild`). 54 AppCore tests pass (`LogExport`, `CommandPalette`). `scripts/check-localization.py` reports 0 problems.
- T020 is done on the Apple host with the test container `gle-logs`. The container wrote 300 lines, and the view held the last 100.
  - Error and up shows 4 lines (`ERROR fail 225`, `250`, `275`, `300`). The count label shows "4 lines".
  - Copy Visible Lines puts the same 4 lines on the pasteboard.
  - Shift-Command-E and the Export button open the save panel with `gle-logs-2026-11-14-HHmm` and Log File.
  - Save writes `gle-logs-2026-11-14-1731.log` with the 4 lines.
  - The palette shows Export Logs… after Show Logs on `gle-logs`. It opens the Logs tab and the save panel.
  - The File menu has Export Logs… (enabled). The Edit menu has Copy Visible Log Lines.
  - The display menu (clock) is disabled on the Apple host.
  - The test container and the exported files are removed.
- T023 is done. The live check found four defects. The fixes passed the same live check:
  - Save stopped the app with an `NSFileWrapper` exception. Each `FileRepresentation` now sets `suggestedFileName`.
  - The saved file had no extension. `defaultFilename` now ends with `.log`.
  - After Error and up, the list was empty: the old scroll offset was past the end. The scroll view now starts again when the level or the time range changes.
  - In a window of 1180 points, the header was wider than the detail column, and the pane was cut on the two sides. The search field can now shrink to 80 points, and the line count gets less space first.
- T021 is done on the SSH Docker host `nettop.local` (Docker 29.6.2), with a test host list for the Debug build only (`GANTRY_HOSTS_PATH`). The test container `gle-logs` wrote the same 300 lines.
  - The display menu is enabled. Show Timestamps adds a column with the local time (`18:19:41.926`).
  - With Error and up and timestamps on, Copy Visible Lines and the export give `2026-11-14T17:19:41.926Z ERROR fail 225` and the 3 other lines.
  - The Text format of the save panel changes the name to `.txt`. The saved file has the same 4 lines.
  - A new line was written 8 minutes after the first lines. Last 5 minutes then shows only this line, and the copy has only this line.
  - The test container and the exported files are removed. The `alpine:3.22` image was on the host before the check, so it stays.
- The stack logs sheet of a Compose project was not checked live.
- T022 is done: pull request #66.

## Dependencies

- Phase 2 blocks all stories.
- US1 (T006, T007) comes before US2, US3, US4 and US5, because they use `LogExportControls.swift` and the changed `LogsView`.
- US5 T013 needs T011 for `StackLogsView`.
- T017 to T022 come last.

## Parallel Opportunities

- T004 can run with T003.
- T015 can run with T012 and T013.

## Implementation Strategy

MVP is Phase 2 plus US1 and US2: filter, export and copy in the Logs tab. Then US3 and US4, then the menus and the palette.
