<!-- STE deviation: spec-kit task format, Swift names, links and paths stay verbatim. -->
# Tasks: Progress of Pull, Build and Compose in the Menu Bar

**Input**: Design documents from `/specs/013-menu-bar-progress/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md

**Tests**: the constitution requires Swift Testing tests for all AppCore logic.

## Phase 1: Setup

- [x] T001 Record in research.md that ActivityKit is unavailable on macOS in the installed SDK (`specs/013-menu-bar-progress/research.md`, R1)

## Phase 2: Foundational

- [ ] T002 Add `OperationProgress` (items with unit `layers`, `steps`, `services`, `items`; bytes; `fraction`; `detailText`) in `Packages/AppCore/Sources/AppCore/OperationProgress.swift`
- [ ] T003 Add `progress` and `report(_:status:)` to `LongOperation`, and the kinds `composeDown`, `composePull`, in `Packages/AppCore/Sources/AppCore/OperationCenter.swift`
- [ ] T004 [P] Tests for `OperationProgress` and `report` (fraction from bytes first, then items; no change after finish) in `Packages/AppCore/Tests/AppCoreTests/OperationProgressTests.swift`

## Phase 3: User Story 1 - See running operations in the menu bar (P1)

**Goal**: the panel shows running and recent operations with progress, detail and elapsed time.

**Independent Test**: start a pull, read `debug/activity` and `debug/menubar`.

- [ ] T005 [P] [US1] `PullProgressTracker` in `Packages/AppCore/Sources/AppCore/PullProgressTracker.swift`, tests with Docker and apple/container lines in `Packages/AppCore/Tests/AppCoreTests/PullProgressTrackerTests.swift`
- [ ] T006 [P] [US1] `BuildStepParser` (classic `Step x/y :`, BuildKit `#n [x/y]` and `#n [stage x/y]`) in `Packages/AppCore/Sources/AppCore/BuildStepParser.swift`, tests in `Packages/AppCore/Tests/AppCoreTests/BuildStepParserTests.swift`
- [ ] T007 [P] [US1] `MenuBarActivity` (running newest first, at most 5; recent finished in the last 600 s, at most 3; hidden count; elapsed text) in `Packages/AppCore/Sources/AppCore/MenuBarActivity.swift`, tests in `Packages/AppCore/Tests/AppCoreTests/MenuBarActivityTests.swift`
- [ ] T008 [US1] Report structured progress from the pull sheet in `App/Views/Images/PullImageSheet.swift`
- [ ] T009 [US1] Report steps from the build sheet in `App/Views/Images/BuildImageSheet.swift`
- [ ] T010 [US1] Report services started of all from Compose up in `App/Views/Compose/ComposeUpSheet.swift`
- [ ] T011 [US1] Report items done of all from the bulk engine in `Packages/AppCore/Sources/AppCore/HostSession+Bulk.swift`
- [ ] T012 [US1] `MenuBarActivitySection` (rows, Show All) in `App/Views/MenuBar/MenuBarActivitySection.swift`, inserted in `App/Views/MenuBar/MenuBarView.swift`
- [ ] T013 [US1] Show the detail line in the Activity list rows in `App/Views/Shared/ActivityView.swift`

## Phase 4: User Story 2 - Cancel from the menu bar (P1)

- [ ] T014 [US2] Cancel button and in-row confirmation ("Stop", "Keep Running") in `App/Views/MenuBar/MenuBarActivitySection.swift`, through `OperationCenter.cancel`

## Phase 5: User Story 3 - The menu bar icon shows activity (P2)

- [ ] T015 [US3] `MenuBarExtra` label with the icon, the running count and an accessibility label in `App/GantryApp.swift`

## Phase 6: User Story 4 - Notification at the end (P2)

- [ ] T016 [US4] Test that `onFinish` runs for the kinds `pull`, `build`, `composeUp`, `composeDown`, `composePull`, and that the state is `cancelled` after a cancel, in `Packages/AppCore/Tests/AppCoreTests/OperationProgressTests.swift`
- [ ] T017 [US4] Allow Explain for failed `composeDown` and `composePull` in `App/Views/Explain/ExplainEntryPoints.swift`

## Phase 7: User Story 5 - Compose down and Compose pull (P3)

- [ ] T018 [US5] `DestructiveAction.Kind.composeDown` and `DestructiveAction.composeDown(project:containers:)` in `Packages/AppCore/Sources/AppCore/DestructiveAction.swift`, texts in `App/Views/Shared/DestructiveActionText.swift`
- [ ] T019 [US5] `HostSession.composeDown(project:)` and `composePull(project:)` with plans `ComposeProjectPlan` in `Packages/AppCore/Sources/AppCore/HostSession+Compose.swift`
- [ ] T020 [US5] Tests for the plans (project members, skipped `sha256:` references, unique references, project networks only) in `Packages/AppCore/Tests/AppCoreTests/ComposeProjectActionsTests.swift`
- [ ] T021 [US5] Pull Images and Compose Down buttons on the Compose group header in `App/Views/Containers/ContainerListView.swift`

## Phase 8: Polish and cross-cutting

- [ ] T022 Debug links `debug/activity`, `debug/menubar`, `debug/pull`, `debug/cancel` in `Packages/AppCore/Sources/AppCore/AppLink.swift` (tests in `AppLinkTests.swift`) and `App/AppLinks/AppLinkHandler.swift`; document in `docs/automation.md` and `scripts/gantry-ctl`
- [ ] T023 All new strings in 28 languages in `App/Localizable.xcstrings` and `Packages/AppCore/Sources/AppCore/Resources/Localizable.xcstrings`; `scripts/check-localization.py` reports 0 problems
- [ ] T024 AppCore tests pass (`swift test` with the scratch path on the external disk)
- [ ] T025 Debug build of the app succeeds (`xcodebuild -jobs 3`)
- [ ] T026 Live check per `quickstart.md` with `scripts/gantry-ctl` on a Docker-free apple/container host; remove test containers `gmbp-*`

## Dependencies

- T002 and T003 block all stories. T005 to T007 can run in parallel.
- US2 and US3 need T012. US5 needs T011.
- T022 to T026 come last.

## Implementation Strategy

MVP is US1 and US2: the panel with progress and Cancel. Then US3 (icon), US4 (checks of the existing notification), then US5 (new Compose actions).
