<!-- STE deviation: spec-kit template headings, product names, Apple API names, Swift type names, CLI flags and paths stay verbatim. -->
# Implementation Plan: Progress of Pull, Build and Compose in the Menu Bar

**Branch**: `feat/menu-bar-progress` | **Date**: 2026-11-14 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/013-menu-bar-progress/spec.md`

## Summary <!-- slop: spec-kit template heading -->

The menu bar panel gets an Activity section that reads the existing `OperationCenter`
(`model.operations`). No new operation model. The work has four parts:

1. AppCore: structured progress on `LongOperation` (`OperationProgress`: items done of a
   total with a unit, and bytes done of a total), a `PullProgressTracker` for pull lines, a
   `BuildStepParser` for build output, and a `MenuBarActivity` summary that selects the rows
   for the panel and the count for the icon. Two new `OperationKind` cases: `composeDown`
   and `composePull`.
2. AppCore: `HostSession.composeDown(project:)` and `composePull(project:)`. They reuse the
   bulk engine (`performBulk`) with their own kind and title, so progress, cancel, failure
   reports and the refresh are the same as for bulk actions. Down then removes the networks
   with the label `com.docker.compose.project=<project>`. A new `DestructiveAction.Kind`
   `composeDown` gives the shared confirmation.
3. App: `MenuBarActivitySection` in `App/Views/MenuBar`, a label view for the
   `MenuBarExtra` with the running count, structured progress from the pull sheet, the
   build sheet and the Compose up sheet, the detail line in the Activity list rows, and two
   buttons on the Compose group header.
4. Debug automation for the live check: `gantry://debug/activity?path=` (the menu bar
   summary as JSON), `gantry://debug/menubar?path=` (PNG of the panel drawn off screen),
   `gantry://debug/pull?ref=&host=` (start a pull operation without the sheet) and
   `gantry://debug/cancel` (cancel the newest running operation).

Notifications need no new code path: `OperationCenter.onFinish` already posts
"Done: …" or "Failed: …" with the Show action for every kind, and posts nothing for a cancel.
The plan keeps it and adds a test that the new kinds go through `finish`.

## Technical Context

**Language/Version**: Swift 6, Xcode 27 SDK (macOS 27.2 SDK)

**Primary Dependencies**: SwiftUI, UserNotifications, AppCore, DockerKit

**Storage**: none

**Testing**: Swift Testing in `Packages/AppCore/Tests/AppCoreTests` (new
`MenuBarActivityTests`, `PullProgressTrackerTests`, `BuildStepParserTests`,
`ComposeProjectActionsTests`, additions to `AppLinkTests`). Live check of a Debug build with
`scripts/gantry-ctl`.

**Target Platform**: macOS 26 or later

**Project Type**: Desktop app (SwiftUI) with local Swift packages

**Performance Goals**: the panel updates at the rate of the operation updates; the elapsed
time uses `Text(timerInterval:)`, so no timer runs in the model.

**Constraints**: builds go to `/Volumes/SanDisk2Tb/builds/gantry/menu-bar-progress/`, with
`-jobs 3`. Shared machine.

**Scale/Scope**: about 10 changed app files, 6 new AppCore files, about 40 new strings.

## Constitution Check

- I. HIG first: the menu bar item uses an image and a short number, the format that
  macOS menu bar extras use. Cancel asks in the row, because an alert closes the panel.
  Pass.
- II. Logic in packages: row selection, progress folding, step parsing, Compose down and
  pull are in AppCore with tests. The views only show state. Pass.
- III. No required dependencies: Compose down and pull use the engine API through
  `DockerClient`, so they work on Docker and on apple/container. No new CLI use. Pass.
- IV. Safety: Compose down uses `DestructiveAction` (`.composeDown`) with the shared
  confirmation and Touch ID. It removes no volumes and no images. Pass.
- V. Strings: all new strings go to `App/Localizable.xcstrings` or the AppCore catalog with
  28 languages. Counts use plural variations. Pass.
- Accessibility: the menu bar label has an accessibility label with the count; state icons
  have labels; Cancel is a text button. Pass.

## Project Structure

### Documentation (this feature)

```text
specs/013-menu-bar-progress/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── checklists/requirements.md
└── tasks.md
```

### Source Code (repository root)

```text
Packages/AppCore/Sources/AppCore/OperationCenter.swift          # OperationKind cases, OperationProgress on LongOperation
Packages/AppCore/Sources/AppCore/OperationProgress.swift        # new: items, bytes, detail text, fraction
Packages/AppCore/Sources/AppCore/PullProgressTracker.swift      # new
Packages/AppCore/Sources/AppCore/BuildStepParser.swift          # new
Packages/AppCore/Sources/AppCore/MenuBarActivity.swift          # new
Packages/AppCore/Sources/AppCore/HostSession+Compose.swift      # new: composeDown, composePull
Packages/AppCore/Sources/AppCore/HostSession+Bulk.swift         # kind, title and unit parameters
Packages/AppCore/Sources/AppCore/DestructiveAction.swift        # .composeDown
Packages/AppCore/Sources/AppCore/AppLink.swift                  # debug activity, menubar, pull, cancel
Packages/AppCore/Sources/AppCore/Resources/Localizable.xcstrings
Packages/AppCore/Tests/AppCoreTests/*                           # new tests
App/GantryApp.swift                                             # MenuBarExtra label
App/Views/MenuBar/MenuBarView.swift                             # inserts the section
App/Views/MenuBar/MenuBarActivitySection.swift                  # new
App/Views/Shared/ActivityView.swift                             # detail line in rows
App/Views/Shared/DestructiveActionText.swift                    # .composeDown texts
App/Views/Images/PullImageSheet.swift                           # tracker
App/Views/Images/BuildImageSheet.swift                          # step parser
App/Views/Compose/ComposeUpSheet.swift                          # services progress
App/Views/Containers/ContainerListView.swift                    # Pull Images, Compose Down buttons
App/Views/Explain/ExplainEntryPoints.swift                      # new kinds can be explained
App/AppLinks/AppLinkHandler.swift                               # debug links
App/Localizable.xcstrings
docs/automation.md                                              # debug links
```

**Structure Decision**: the existing app and package layout. No new target.

## Complexity Tracking

No constitution violations.
