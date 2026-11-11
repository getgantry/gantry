---

description: "Task list for the polish fixes of 0.27.1"
---

<!-- STE deviation: spec-kit template headings, task format, product names, CLI flags and paths stay verbatim. -->
# Tasks: Polish Fixes for 0.27.1

**Input**: Design documents from `/specs/005-polish-0-27-1/`

**Prerequisites**: plan.md, spec.md

**Tests**: Required for the logic in AppCore (constitution principle II). The view fixes get live checks with `scripts/gantry-ctl`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: The user story of the task (US1 to US4)

## Phase 1: Setup

- [x] T001 Create the branch `fix/polish-0-27-1` from main and build the Debug app into /Volumes/SanDisk2Tb/builds/gantry/polish-0-27-1/DerivedData

## Phase 2: User Story 4 - gantry-ctl finds the app (P3, first because the other checks use it)

- [x] T002 [US4] In scripts/gantry-ctl, collect all pids from `pgrep -f`, remove `$$` and its parent pids, and keep the newest pid with an automation socket
- [x] T003 [US4] Live check: run gantry-ctl 20 times from `zsh -c` with the pattern in the command line while a newer decoy process with the pattern runs (SC-004), and once with two Debug builds and `GANTRY_APP`

## Phase 3: User Story 1 - Explain button label (P1)

- [ ] T004 [P] [US1] Add `.accessibilityLabel` and `.accessibilityHint` to `ExplainFailureButton` and `ExplainOperationButton` in App/Views/Explain/ExplainEntryPoints.swift
- [ ] T005 [US1] Live check: a failed `gfix-` container, read the accessibility tree of the header in English and Russian (SC-001)

## Phase 4: User Story 3 - A link closes the palette (P2)

- [ ] T006 [P] [US3] Add `AppLink.closesPalette` in Packages/AppCore/Sources/AppCore/AppLink.swift (true for `.open` and `.settings`)
- [ ] T007 [P] [US3] Add tests for `closesPalette` for each case in Packages/AppCore/Tests/AppCoreTests/AppLinkTests.swift
- [ ] T008 [US3] In `apply(_:)` of App/Views/ContentView.swift, set `showingPalette = false` when `link.closesPalette`
- [ ] T015 [US3] In App/AppLinks/AppLinkHandler.swift, make `WindowReader` report the window from `viewDidMoveToWindow` and never nil, so `gantry-ctl state` answers after a link changes the split view layout (FR-008)
- [ ] T009 [US3] Live check: palette, link, state, 10 times (SC-003); a debug link keeps the palette open

## Phase 5: User Story 2 - Clear time labels (P2)

- [ ] T010 [P] [US2] Add `StatsTimeAxis` (step from the sample span, at most 4 labels) with tests in Packages/AppCore/Sources/AppCore/StatsTimeAxis.swift and Packages/AppCore/Tests/AppCoreTests/StatsTimeAxisTests.swift; use it in `TimeAxis` in App/Views/Containers/StatsView.swift (stride marks, `hour().minute()` for steps of 1 min or more)
- [ ] T011 [US2] Live check: snapshots of Stats at the minimum, medium and wide window width, with 10 s and 1 min of samples (SC-002)

## Phase 6: Polish

- [ ] T012 Run `swift test` for AppCore with `--scratch-path /Volumes/SanDisk2Tb/builds/gantry/polish-0-27-1/AppCore` and `scripts/check-localization.py`
- [ ] T013 Remove the `gfix-` test containers and the Debug app process
- [ ] T014 Open the pull request `fix: polish accessibility, charts, links and gantry-ctl for 0.27.1`

## Dependencies

- T002 before T005, T009 and T011 (the live checks use gantry-ctl).
- T006 before T007 and T008.
- T015 before T009 (the check reads `state` after a navigation).
- US1, US2 and US3 are independent of each other.
