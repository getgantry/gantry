---

description: "Task list for full Apple container 1.7.1 support"
---

<!-- STE deviation: spec-kit template headings, task format, product names and paths stay verbatim. -->
# Tasks: Full Support for Apple container 1.7.1

**Input**: Design documents from `/specs/001-apple-container-1-7-1/`

**Prerequisites**: plan.md, spec.md

**Tests**: Required. Constitution principle II asks for Swift Testing tests for every change to logic, with fixtures from the real tool.

**Organization**: Tasks are grouped by user story.

**Status note**: The implementation started before this list was written. The code was checked against this list on 2026-11-11, during the review of PR #63 (apple/container 1.7.1). T035 stays open (see the note under it).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: The user story of the task (US1 to US5)

## Phase 1: Setup (Shared Infrastructure)

- [x] T001 Check out the 1.7.1 source at /Volumes/SanDisk2Tb/builds/gantry-027/ac17/upstream/c171 (read only) and list the changes from `gh api repos/apple/container/compare/1.6.1...1.7.1`
- [x] T002 [P] Capture live 1.7.1 fixtures with read-only commands (`container system property ls`, `container stats --no-stream --format json`, `container cluster --help`) into /Volumes/SanDisk2Tb/builds/gantry-027/ac171/live-1.7.1/

---

## Phase 2: Foundational (Blocking Prerequisites)

- [x] T003 Add `Features.containerDNSDefaults` (1.7.0) in Packages/AppCore/Sources/AppCore/ContainerTooling.swift
- [x] T004 [P] Add the live 1.7.1 fixtures to Packages/AppCore/Tests/AppCoreTests/AppleContainer171Tests.swift

**Checkpoint**: Version gate and fixtures are ready.

---

## Phase 3: User Story 1 - Understand why clusters do not work (Priority: P1) (MVP)

**Goal**: A clear message and a fix when the cluster services are absent or do not run.

**Independent Test**: Diagnosis tests with fake layouts. Clusters section on a host with failing cluster services.

### Tests for User Story 1

- [x] T005 [P] [US1] Tests for error recognition ("cluster service unavailable", "Connection invalid") in Packages/AppCore/Tests/AppCoreTests/AppleContainer171Tests.swift
- [x] T006 [P] [US1] Tests for the layouts (Homebrew without plugin, bottle revision `1.7.1_1`, package without plugin, complete install, symbolic link) in Packages/AppCore/Tests/AppCoreTests/AppleContainer171Tests.swift

### Implementation for User Story 1

- [x] T007 [US1] Implement `ClusterServiceDiagnosis` with an injectable layout probe in Packages/AppCore/Sources/AppCore/ClusterServiceDiagnosis.swift
- [x] T008 [US1] Set and clear `HostSession.clusterServiceProblem` from list, action and create failures in Packages/AppCore/Sources/AppCore/HostSession.swift
- [x] T009 [P] [US1] Create the notice view with the Download Installer link and Restart Services action in App/Views/Clusters/ClusterServiceProblemView.swift
- [x] T010 [US1] Show the notice as the empty state and above the rows in App/Views/Clusters/ClusterListView.swift
- [x] T011 [US1] Show the notice in App/Views/Clusters/CreateClusterSheet.swift
- [x] T012 [US1] Show the notice in the Kubernetes flows for clusters of the container tool in App/Views/Kubernetes/KubernetesBrowserView.swift
- [x] T013 [US1] Add the new strings to Packages/AppCore/Sources/AppCore/Resources/Localizable.xcstrings and App/Localizable.xcstrings

**Checkpoint**: User Story 1 works on its own.

---

## Phase 4: User Story 2 - Edit the DNS defaults (Priority: P2)

**Goal**: Show and edit `[container.dns]` lists on 1.7.0 and later.

**Independent Test**: TOML round-trip tests. Edit a list in System properties on a 1.7.1 host.

### Tests for User Story 2

- [x] T014 [P] [US2] Round-trip tests for string arrays (one line, several lines, trailing comment, comment inside, non-string array, scalar over array) in Packages/AppCore/Tests/AppCoreTests/AppleContainer171Tests.swift
- [x] T015 [P] [US2] Tests for row validation and for the version gate in Packages/AppCore/Tests/AppCoreTests/AppleContainer171Tests.swift

### Implementation for User Story 2

- [x] T016 [US2] Read and write plain string arrays in place, with the verify step, in Packages/AppCore/Sources/AppCore/ConfigTOML.swift
- [x] T017 [US2] Add `AppleSystemPropertyValue.strings`, the list kinds, the DNS keys, row validation and `setUserList` in Packages/AppCore/Sources/AppCore/AppleContainerProperties.swift
- [x] T018 [P] [US2] Create the list editor sheet (add and remove rows, row errors) in App/Views/AppleSystem/AppleSystemListEditor.swift
- [x] T019 [US2] Show the DNS lists, the footer and the row descriptions in App/Views/AppleSystem/AppleSystemPropertiesPane.swift
- [x] T020 [P] [US2] Accept comma-separated lists in `apple_set_property` in Packages/GantryMCP/Sources/gantry-mcp/GantryTools+AppleSystem.swift and update its tests in Packages/GantryMCP/Tests
- [x] T021 [US2] Add the new strings to App/Localizable.xcstrings and the AppCore catalog

**Checkpoint**: User Stories 1 and 2 work on their own.

---

## Phase 5: User Story 3 - CPU use from the tool (Priority: P2)

**Goal**: Use `cpuUtilization` when present.

**Independent Test**: DockerKit stats tests with live 1.7.1 and 1.6.1 output.

- [x] T022 [P] [US3] Stats tests with the live 1.7.1 JSON, the 1.6.1 JSON and values that are not valid in Packages/DockerKit/Tests/DockerKitTests/AppleContainerJSONTests.swift
- [x] T023 [US3] Use `cpuUtilization` (1.0 is one core) in the stats body, with the counter fallback, in Packages/DockerKit/Sources/DockerKit/AppleContainer/AppleContainerJSON.swift
- [x] T024 [US3] Test that stats rows for cluster node containers create no rows in the container list, in Packages/DockerKit/Tests/DockerKitTests/AppleContainerJSONTests.swift

---

## Phase 6: User Story 4 - Recommended kernel (Priority: P3)

**Goal**: The kernel install follows the tool.

- [x] T025 [US4] Check that Packages/AppCore/Sources/AppCore/AppleContainerKernel.swift holds no kernel version and runs `system kernel set --recommended`
- [x] T026 [P] [US4] Add a test with the live 1.7.1 kernel properties in Packages/AppCore/Tests/AppCoreTests/AppleContainer171Tests.swift

---

## Phase 7: User Story 5 - Old builder image (Priority: P3)

**Goal**: Tell the user when the builder image is old.

- [x] T027 [P] [US5] Tests for `AppleBuilderStatus.imageUpdate(configuredImage:)` in Packages/AppCore/Tests/AppCoreTests/AppleContainer171Tests.swift
- [x] T028 [US5] Implement the image comparison in Packages/AppCore/Sources/AppCore/AppleContainerBuilder.swift
- [x] T029 [US5] Show the "Builder image is outdated" card and Recreate Builder with confirmation in App/Views/AppleSystem/AppleBuilderPane.swift

---

## Phase 8: Polish & Cross-Cutting Concerns

- [x] T030 Write the review of every other 1.6.1 to 1.7.1 change in /Volumes/SanDisk2Tb/builds/gantry-027/ac171/REPORT.md
- [x] T031 [P] Write the list of new string keys to /Volumes/SanDisk2Tb/builds/gantry-027/ac171/new-strings.txt
- [x] T032 Translate the new strings into all supported UI languages with the reviewed glossaries and run scripts/check-localization.py
- [x] T033 Run `swift test` in AppCore, DockerKit, GantryMCP, SSHKit and GantryShared with `--scratch-path /Volumes/SanDisk2Tb/builds/gantry-027/ac171/<Package>`
- [x] T034 Build the Debug app with `-derivedDataPath /Volumes/SanDisk2Tb/builds/gantry-027/ac171/DerivedData`
- [ ] T035 Check the Clusters notice, the DNS list editor and the Builder card in the running Debug app with scripts/gantry-ctl, in light and dark mode
  - 2026-11-11, live CLI 1.7.1: the Builder card "Builder image is outdated" (0.13.2 to 0.13.3) shows correctly in light and dark mode. System Properties shows the `[container.dns]` section. The CPU value of a busy container is 98 % when the CLI reports `cpuUtilization` 1.0.
  - Open: the DNS list editor sheet was not opened, because `gantry-ctl` cannot click. The Clusters notice was not seen, because the cluster services on this Mac work. To check it, use a host with a broken cluster setup.
- [x] T036 Check that a 1.6.1 host shows no DNS keys and keeps the old stats calculation (fixtures)
- [x] T037 Add the 1.7.1 features (DNS defaults, outdated builder image, cluster services check, CPU utilization) to the apple/container section of README.md

---

## Dependencies & Execution Order

- Phase 1 and Phase 2 come first. T003 blocks US2.
- US1, US2, US3, US4 and US5 are independent of each other after Phase 2.
- In each story, the tests come before the implementation.
- Phase 8 comes after the stories. T032 blocks the merge (constitution principle V).

## Parallel Example: User Story 2

```bash
Task: "Round-trip tests for string arrays in AppleContainer171Tests.swift"
Task: "Create the list editor sheet in App/Views/AppleSystem/AppleSystemListEditor.swift"
Task: "Accept list values in GantryTools+AppleSystem.swift"
```

## Implementation Strategy

1. MVP: Phase 1, Phase 2 and User Story 1. Validate the notice.
2. Add User Story 2 and User Story 3. Validate each.
3. Add User Stories 4 and 5. Then Phase 8.
