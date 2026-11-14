---

description: "Task list for the fleet activity table"
---

<!-- STE deviation: spec-kit template headings, task format (one line per task, long, with semicolons), product names, Swift names, CLI flags and paths stay verbatim. -->
# Tasks: Fleet Activity Table

**Input**: Design documents from `/specs/006-fleet-activity/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: Required for the logic in AppCore, DockerKit and GantryMCP (constitution principle II). The view gets a live check with `scripts/gantry-ctl`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: The user story of the task (US1 to US6)

## Phase 1: Setup <!-- slop: spec-kit template heading -->

- [x] T001 Set `.specify/feature.json` to `specs/006-fleet-activity` and check that `/Volumes/SanDisk2Tb/builds/gantry/fleet-activity/` is on the external disk with more than 10 GB free

## Phase 2: Foundational (uptime for both host kinds)

- [x] T002 [P] Add `DockerHumanDuration.string(_:)` with the table of data-model.md in Packages/DockerKit/Sources/DockerKit/Models/DockerHumanDuration.swift
- [x] T003 [P] Add tests for each row of the duration table in Packages/DockerKit/Tests/DockerKitTests/DockerHumanDurationTests.swift
- [x] T004 In Packages/DockerKit/Sources/DockerKit/AppleContainer/AppleContainerJSON.swift, write the Status "Up <duration>" for a running container from `startedDate` (with an injectable `now`); keep "Up" when the date is missing
- [x] T005 Update the expectations and add a `startedDate` case in Packages/DockerKit/Tests/DockerKitTests/AppleContainerJSONTests.swift and AppleContainer1_0JSONTests.swift
- [x] T006 [P] Add `ContainerUptime.seconds(fromStatus:)` in Packages/AppCore/Sources/AppCore/ContainerUptime.swift: "Up 3 hours", "(healthy)" and "(Paused)" suffixes, "About a minute", "About an hour", "Less than a second"; nil for "Up", "Exited (0) 2 hours ago" and ""
- [x] T007 [P] Add tests with real Docker status strings in Packages/AppCore/Tests/AppCoreTests/ContainerUptimeTests.swift

## Phase 3: User Story 1 - One table of all running containers (P1) MVP

**Goal**: the table shows the running containers of all connected hosts with live values.

**Independent Test**: two hosts with running containers show all rows; values change after the next 5-second sample.

- [x] T008 [US1] Add `FleetActivity.HostInput`, `Row`, `UnavailableHost`, `Snapshot` and `snapshot(hosts:)` in Packages/AppCore/Sources/AppCore/FleetActivity.swift. Rows only for "a running, user-visible container of a connected host"; row id `"<hostID>/<containerID>"`
- [x] T009 [US1] Add `HostSession.activityInput` (visible containers, `containerLoadHistory` latest points, state) in Packages/AppCore/Sources/AppCore/FleetActivity.swift
- [x] T010 [US1] Add snapshot tests (stopped, builder and sidecar containers left out; rows of two hosts; a row without a sample has nil load) in Packages/AppCore/Tests/AppCoreTests/FleetActivityTests.swift
- [x] T011 [US1] Add `SidebarItem.usage`, the sidebar row "Resource Usage" under Dashboard, the content case and the full-width layout in App/Views/ContentView.swift
- [x] T012 [US1] Add the `Table` with the columns host, name, image, CPU, memory, network I/O, disk I/O and uptime, dash for missing values and accessibility labels in App/Views/Usage/FleetActivityView.swift (small helper views for the cells)

## Phase 4: User Story 2 - Sort and filter (P1)

**Goal**: sort by each column; filter by text and host.

**Independent Test**: sort by CPU puts the busiest first; text and host filters combine.

- [x] T013 [US2] Add `FleetActivity.Column`, `Comparator: SortComparator` ("a nil value is after each non-nil value, in both orders"; ties by host name, container name, id) and `Filter` in Packages/AppCore/Sources/AppCore/FleetActivity.swift
- [x] T014 [US2] Add comparator and filter tests (each column both orders, nil last, stable ties, case-insensitive text on name, image and host, host filter, combined filters) in Packages/AppCore/Tests/AppCoreTests/FleetActivityTests.swift
- [x] T015 [US2] Wire `sortOrder` (default CPU descending), `.searchable` and a host `Picker` in the toolbar, the reset of a removed host, and the "no match" empty state with Clear Filters in App/Views/Usage/FleetActivityView.swift

## Phase 5: User Story 3 - Open a container (P2)

- [ ] T016 [US3] Add `contextMenu(forSelectionType:)` with primary action (double-click, Return) to the Containers section, and the items Show in Containers, Show Stats and Copy Name in App/Views/Usage/FleetActivityView.swift; route through `navigate` in App/Views/ContentView.swift

## Phase 6: User Story 4 - Hosts that are not connected (P2)

- [x] T017 [US4] Add tests for `unavailableHosts` (failed with reason, connecting, disconnected, sidebar order) in Packages/AppCore/Tests/AppCoreTests/FleetActivityTests.swift
- [ ] T018 [US4] Show one line for each unavailable host (status symbol and text, reason, Retry for failed and disconnected) and the empty states "no host connected" and "no container runs" in App/Views/Usage/FleetActivityView.swift

## Phase 7: User Story 5 - Palette and link (P3)

- [x] T019 [P] [US5] Add `usage` to `AppLink.globalTargets` in Packages/AppCore/Sources/AppCore/AppLink.swift and a parse test in Packages/AppCore/Tests/AppCoreTests/AppLinkTests.swift
- [x] T020 [US5] Handle `open/usage` in `apply(_:)` in App/Views/ContentView.swift; add the palette item with keywords "activity", "top", "stats", "cpu", "memory" in App/Views/Palette/PaletteRunner.swift; document the link in docs/automation.md

## Phase 8: User Story 6 - MCP tool (P3)

- [x] T021 [US6] Add `fleet_activity` (arguments `host_id`, `sort`, `ascending`, `limit`; two one-shot samples one second apart; error entry for each failed host) in Packages/GantryMCP/Sources/gantry-mcp/GantryTools+Activity.swift and the dispatch in GantryTools.swift
- [x] T022 [US6] Add tool tests (definition present, argument validation, rows sorted and limited from a fake input) in Packages/GantryMCP/Tests/GantryMCPTests/FleetActivityToolTests.swift

## Phase 9: Polish and cross-cutting

- [x] T023 Add all new strings with 28 languages to App/Localizable.xcstrings and run `python3 scripts/check-localization.py` (0 problems)
- [x] T024 Run the AppCore, DockerKit and GantryMCP tests on the external disk and build the app with `xcodebuild -jobs 3`
- [ ] T025 Live check of a Debug build with `scripts/gantry-ctl` as quickstart.md says (rows, sort, link, snapshot in light and dark); remove the `gfa-` test containers
- [x] T026 Rebase on `origin/main`, re-add catalog keys with a script on conflict, and open the pull request "feat: show a sortable activity table for all containers"

## Status (2026-11-14)

- Full suites pass: DockerKit 326 tests, AppCore 736, GantryMCP 96 (live tests skipped without a Docker socket).
- Checked by tests: DockerKit (`DockerHumanDurationTests`, apple JSON tests), AppCore (`FleetActivityTests`, `ContainerUptimeTests`, `AppLinkTests`), GantryMCP (`FleetActivityToolTests`). `scripts/check-localization.py`: 0 problems.
- Checked live on a Debug build with the automation socket: `open/usage` selects the table and closes the palette; rows of the apple/container host with CPU, memory, rates and uptime; default sort CPU, highest first; light and dark snapshots; all 8 columns fit the default window. `fleet_activity` checked live over stdio (about 5 s with apple/container, sorted rows, no errors).
- The screen was locked during the live check, so no clicks or typing were possible. Not checked live: header clicks, the search field and the host menu (T015 is ticked for the code and the unit tests only), double-click, Return and the row menu (T016), the unavailable-host lines (T018, no failed host was available without a change to the user's host list), the palette search (T020 is ticked for the link and the code).
- T016 and T018: the code exists and builds. They stay open until a live check with an unlocked screen.

## Dependencies

- Phase 2 before US1 (the uptime column) and US6.
- US1 before US2, US3 and US4 (same view).
- US5 and US6 depend only on Phase 2 and T008 and T013.

## Parallel Example

T002, T003, T006 and T007 are in different files. T019 can run at any time.

## Implementation Strategy

MVP is US1 and US2: the table with sort. Then US3 and US4, then US5 and US6, then the polish phase.
