---

description: "Task list for the Apple HIG and Liquid Glass design pass"
---

<!-- STE deviation: spec-kit template headings, task format, product names, Apple API names and paths stay verbatim. -->
# Tasks: Apple HIG and Liquid Glass Design Pass

**Input**: Design documents from `/specs/003-hig-design-pass/`

**Prerequisites**: plan.md, spec.md, research in /Volumes/SanDisk2Tb/builds/gantry-027/hig/SPEC.md

**Tests**: Required for logic (constitution principle II). Views are checked with snapshots.

**Organization**: Tasks are grouped by user story.

**Status note**: The implementation started before this list. All tasks are open, because nobody checked the code against this list yet. Tick a task only after you check its code on branch `feat/hig-design-pass`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: The user story of the task (US1 to US5)

## Phase 1: Setup (Shared Infrastructure)

- [ ] T001 Write the HIG audit per screen in /Volumes/SanDisk2Tb/builds/gantry-027/hig/SPEC.md before code changes
- [ ] T002 [P] Keep the before screenshots in /Volumes/SanDisk2Tb/builds/gantry-027/hig/

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Shared components and the load history. All stories use them.

- [ ] T003 [P] Tests for counter rates, counter reset, bounded history, removed containers, `top(by:limit:)` and `MetricSummary` in Packages/AppCore/Tests/AppCoreTests/LoadHistoryTests.swift
- [ ] T004 Implement `ContainerCounters`, `LoadMath.rates`, `ContainerLoadHistory` and `MetricSummary` in Packages/AppCore/Sources/AppCore/LoadHistory.swift
- [ ] T005 Record per-container points and host network and disk rates in `LoadSample` in Packages/AppCore/Sources/AppCore/HostSession.swift
- [ ] T006 [P] Add `Spacing`, `DashboardCard` (contrast border), `StatusBadge` and `CopyableValue` in App/Views/Shared/DesignSystem.swift
- [ ] T007 [P] Add `MetricChartCard` (fixed or dynamic range, summary, accessibility) and `Sparkline` in App/Views/Shared/MetricChart.swift
- [ ] T008 [P] Add monospaced and copyable values to `FactGrid` in App/Views/Shared/DetailComponents.swift
- [ ] T009 [P] Add secondary actions to App/Views/Shared/ListEmptyState.swift

**Checkpoint**: Components and history are ready.

---

## Phase 3: User Story 1 - State of a host at a glance (Priority: P1) (MVP)

**Goal**: Dashboard and Overview with live charts that fill the window.

**Independent Test**: Open both screens with running containers at wide and narrow widths.

- [ ] T010 [US1] Rebuild the host cards as an adaptive grid with charts, state bar, top containers and quick actions in App/Views/Dashboard/FleetDashboardView.swift
- [ ] T011 [US1] Add the Recent Activity card from `OperationCenter` in App/Views/Dashboard/FleetDashboardView.swift
- [ ] T012 [US1] Add the four metric chart cards, stat tiles, Top Containers and the disk and facts layout in App/Views/HostOverviewView.swift
- [ ] T013 [US1] Check VoiceOver labels and values of the charts

---

## Phase 4: User Story 2 - No cut toolbar text (Priority: P1)

**Goal**: Icon toolbar items and More menus in detail panes.

**Independent Test**: Every detail pane at minimum window width.

- [ ] T014 [P] [US2] Move the cluster actions to Browse Resources and a More menu in App/Views/Clusters/ClusterListView.swift
- [ ] T015 [P] [US2] Move Shell, Start or Stop and Set Default to the toolbar in App/Views/Machines/MachineListView.swift
- [ ] T016 [P] [US2] Move Scale, Restart, Forward Port and Delete to the toolbar and a More menu in App/Views/Kubernetes/KubeResourceDetailView.swift (presentation only)
- [ ] T017 [P] [US2] Group the System header actions in a `ControlGroup` in App/Views/AppleSystem/AppleSystemOverviewPane.swift
- [ ] T018 [US2] Check that each moved action is still in the context menu and the command palette

---

## Phase 5: User Story 3 - Richer lists and detail panes (Priority: P2)

**Goal**: Rows with symbols, badges, ports and charts. Grouped detail sections.

- [ ] T019 [US3] Add state symbol, image line, port tags (3 and "+n") and the CPU sparkline to rows in App/Views/Containers/ContainerListView.swift
- [ ] T020 [P] [US3] Use the `ellipsis` More symbol and copyable IDs in App/Views/Images/ImageListView.swift
- [ ] T021 [P] [US3] Use the `ellipsis` More symbol and copyable IDs in App/Views/Volumes/VolumeListView.swift
- [ ] T022 [P] [US3] Use the `ellipsis` More symbol and copyable IDs in App/Views/Networks/NetworkListView.swift
- [ ] T023 [US3] Rebuild the cluster overview as grouped cards (Cluster, Nodes, Resources, Reach Services) in App/Views/Clusters/ClusterListView.swift
- [ ] T024 [P] [US3] Make versions, hashes and paths monospaced and show Resources as stat tiles in App/Views/AppleSystem/AppleSystemOverviewPane.swift

---

## Phase 6: User Story 4 - Useful empty states (Priority: P2)

- [ ] T025 [US4] Add Quick Run, New Container and Pull Image to the empty state in App/Views/Containers/ContainerListView.swift
- [ ] T026 [P] [US4] Check the empty states of Images, Volumes, Networks, Machines and Clusters and add one useful action to each empty state that has none

---

## Phase 7: User Story 5 - Kubernetes in the command palette (Priority: P3)

- [ ] T027 [P] [US5] Tests for `PaletteCatalog.kubernetes(contexts:)` in Packages/AppCore/Tests/AppCoreTests/CommandPaletteTests.swift
- [ ] T028 [US5] Add the Kubernetes section item and the context items in Packages/AppCore/Sources/AppCore/Palette/PaletteCatalog.swift
- [ ] T029 [US5] Run the items (select the section and the context) in App/Views/Palette/CommandPaletteView.swift and App/Views/Palette/PaletteRunner.swift

---

## Phase 8: Polish & Cross-Cutting Concerns

- [ ] T030 Check light mode, dark mode, Reduce Transparency and Increase Contrast in every section
- [ ] T031 Check that no `glassEffect` is on content and that macOS 27 APIs are behind `#available`
- [ ] T032 [P] Write the list of new string keys to /Volumes/SanDisk2Tb/builds/gantry-027/hig/new-strings.txt
- [ ] T033 Translate the new strings into all supported UI languages and run scripts/check-localization.py
- [ ] T034 Run `swift test` in AppCore with `--scratch-path /Volumes/SanDisk2Tb/builds/gantry-027/hig/AppCore`
- [ ] T035 Build the Debug app with `-derivedDataPath /Volumes/SanDisk2Tb/builds/gantry-027/hig/DerivedData`
- [ ] T036 Take after screenshots of every section with scripts/gantry-ctl into /Volumes/SanDisk2Tb/builds/gantry-027/hig/after/ and quit the Debug app
- [ ] T037 Write /Volumes/SanDisk2Tb/builds/gantry-027/hig/REPORT.md

---

## Dependencies & Execution Order

- Phase 2 blocks all stories. T004 blocks T005, T010, T012 and T019.
- US1 to US5 are independent after Phase 2. US2 and US3 both change App/Views/Clusters/ClusterListView.swift, so do T014 before T023.
- Merge conflicts are possible with `feat/kubernetes-native` (Kubernetes views) and `feat/apple-container-1-7-1` (Clusters and System panes). Change only presentation in those files.
- T033 blocks the merge (constitution principle V).

## Parallel Example: Phase 2

```bash
Task: "Load history tests in LoadHistoryTests.swift"
Task: "Shared components in App/Views/Shared/DesignSystem.swift"
Task: "Charts in App/Views/Shared/MetricChart.swift"
```

## Implementation Strategy

1. MVP: Phase 2, then User Story 1 and User Story 2.
2. Add User Stories 3 and 4 area by area, one commit each.
3. Add User Story 5. Then Phase 8 with the screenshots.
