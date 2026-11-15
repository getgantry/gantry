<!-- STE deviation: spec-kit template headings, product names, Apple API names, type names, menu titles and paths stay verbatim. -->
# Implementation Plan: Export Container Logs with the Current Filter

**Branch**: `feat/log-export` | **Date**: 2026-11-14 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/007-log-export/spec.md`

## Summary <!-- slop: spec-kit template heading -->

The filter, the text format and the chunked file write go to a new AppCore file `LogExport.swift`. Both log views use the AppCore filter for their visible lines. Thus the view, the copy and the export show the same lines.

The views get a display menu (Show Timestamps, time range), an Export Logs button and a Copy Visible Lines button. The export uses the SwiftUI `fileExporter` with a `Transferable` item. Its `FileRepresentation` writes the visible lines to a temporary file in chunks of 64 KiB. The save panel moves that file to the destination. A focused scene value gives the File and Edit menu items their target. The palette gets the action `exportLogs` on containers.

## Technical Context

**Language/Version**: Swift 6, Xcode 27 SDK

**Primary Dependencies**: SwiftUI, CoreTransferable, UniformTypeIdentifiers, AppCore, DockerKit. No new package.

**Storage**: A temporary file in the app's temporary directory for each export. The save panel moves it to the destination.

**Testing**: Swift Testing in `Packages/AppCore/Tests/AppCoreTests/LogExportTests.swift` and `CommandPaletteTests.swift`. Live checks of a Debug build with `scripts/gantry-ctl` on the local Apple `container` host.

**Target Platform**: macOS 26 or later

**Project Type**: Desktop app (SwiftUI) with local Swift packages

**Performance Goals**: 50 000 lines exported in less than 2 s.

**Constraints**: The write holds at most one chunk of formatted text in memory. Builds go to `/Volumes/SanDisk2Tb/builds/gantry/log-export/` with `-jobs 3`.

**Scale/Scope**: 2 views, 1 AppCore file, 1 palette action, 2 menu items, about 25 new strings.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- I. HIG first: Export in the File menu with Shift-Command-E, Copy in the Edit menu, the standard save panel, SF Symbols `square.and.arrow.up` and `clock`. Icon-only buttons get labels and help. Pass.
- II. Logic in packages: filter, time range, format, file name and chunked write are in AppCore with tests. The writer writes to a `LogExportSink` protocol, so tests use memory. The views only hold state. Pass.
- III. No required dependencies, version gates: the feature adds no tool and no CLI call. Apple hosts send lines without timestamps. On these hosts the timestamp controls are disabled with a reason, and the export works. Pass.
- IV. Data and secrets: the export writes only the file that the user selects in the save panel. It deletes nothing. Log text stays on the Mac. Pass.
- V. Every string in every language: all new strings go to `App/Localizable.xcstrings` or the AppCore catalog with 28 languages, plural forms for counts. Pass.
- Accessibility: each new icon-only control has a label. The disabled timestamp state has a help text, not only a gray color. Pass.

Re-check after Phase 1: no change. Pass.

## Project Structure

### Documentation (this feature)

```text
specs/007-log-export/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/ui.md
├── checklists/requirements.md
└── tasks.md
```

### Source Code (repository root)

```text
Packages/AppCore/Sources/AppCore/LogExport.swift          # new: filter, time range, format, file name, writer
Packages/AppCore/Sources/AppCore/Palette/PaletteItem.swift # new action exportLogs
Packages/AppCore/Sources/AppCore/Palette/PaletteCatalog.swift
Packages/AppCore/Sources/AppCore/Resources/Localizable.xcstrings
Packages/AppCore/Tests/AppCoreTests/LogExportTests.swift  # new
Packages/AppCore/Tests/AppCoreTests/CommandPaletteTests.swift
App/Views/Containers/LogExportControls.swift              # new: display menu, export item, focused target, commands
App/Views/Containers/LogsView.swift
App/Views/Containers/StackLogsView.swift
App/Views/Containers/ContainerFormComponents.swift        # ContainerTabRequest.Tab.exportLogs
App/Views/Containers/ContainerDetailView.swift
App/Views/Palette/PaletteRunner.swift
App/GantryApp.swift                                       # LogCommands
App/Localizable.xcstrings
```

**Structure Decision**: Use the existing app and package layout. New logic goes to one AppCore file. New view parts go to one app file next to the log views, so `LogsView` and `StackLogsView` stay small for the type checker.

## Complexity Tracking

No violations.
