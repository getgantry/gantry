---

description: "Task list for the build history"
---

<!-- STE deviation: spec-kit template headings, task format, type names, product names, CLI flags and paths stay verbatim. -->
# Tasks: Build History

**Input**: Design documents from `/specs/010-build-history/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/buildx-cli.md

**Tests**: Required for the logic in DockerKit and AppCore (constitution principle II). The views get a live check with `scripts/gantry-ctl`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: The user story of the task (US1 to US3)

## Phase 1: Setup <!-- slop: spec-kit template heading -->

- [x] T001 Copy the live fixtures (container 1.7.1 build output, Docker 28.5.2 classic stream, buildx 0.29.1 `ls`, `inspect`, `logs`, `version`) into Packages/DockerKit/Tests/DockerKitTests/BuildHistoryFixtures.swift as string constants (as the other fixture tests do, so Package.swift does not change) and remove the `Error.Stack` field from the inspect fixtures

## Phase 2: Foundational (parsers)

- [x] T002 [P] Add `BuildStep`, `BuildStepState` (`run`, `cached`, `failed`, `unknown`), `BuildStepSummary` and `BuildProgressParser` (BuildKit plain progress, merge by vertex number; classic `Step i/n :` stream; auto-detect) in Packages/DockerKit/Sources/DockerKit/Models/BuildProgress.swift
- [x] T003 [P] Add `BuildxRecord`, `BuildxInspect` and `BuildxHistoryParser` (JSON lines or array, `created_at` and `CreatedAt` keys, nanosecond dates, `buildx version` text) in Packages/DockerKit/Sources/DockerKit/Models/BuildxHistory.swift
- [x] T004 [P] Add fixture tests in Packages/DockerKit/Tests/DockerKitTests/BuildProgressTests.swift: Apple first build (9 vertices, 0 cached), Apple cached (3 cached), Apple failed (step `[linux/arm64 2/3] RUN exit 3` failed), classic first, cached and failed, buildx logs of the cached build give 9 and 3 as `ls` gives (SC-002)
- [x] T005 [P] Add fixture tests in Packages/DockerKit/Tests/DockerKitTests/BuildxHistoryTests.swift: `ls` lines, array form with `ID`/`CreatedAt`, inspect of the failed build, version parse and gate (0.22.9 no, 0.23.0 yes, 0.29.1 yes)

## Phase 3: User Story 1 - See the builds that Gantry started (P1) MVP

**Goal**: Each build that Gantry starts shows in the Builds section with status, start, duration, steps and log, on every host kind.

**Independent Test**: Build three times on an Apple host (first, cached, failed) and see three correct records, also after a restart.

- [x] T006 [US1] Add `BuildRecord`, `BuildStatus` (`running`, `succeeded`, `failed`, `cancelled`, `interrupted`), `BuildSource` (`gantry`, `buildx`) and the log cap "at most 512 KB, the end" with `logTruncated` in Packages/AppCore/Sources/AppCore/Builds/BuildRecord.swift
- [x] T007 [US1] Add `BuildHistoryStore` (`@MainActor @Observable`; `begin`, `finish`, `records(for:)`, `clear(hostID:)`, `removeHost`; "at most 100 records per host"; `running` to `interrupted` on load; JSON file mode 0600; `GANTRY_BUILD_HISTORY_PATH` seam; in-memory when the URL is nil) in Packages/AppCore/Sources/AppCore/Builds/BuildHistoryStore.swift
- [x] T008 [US1] Record builds in `HostSession.buildImageStream` and `buildImage` (start, log, image ID, end status, cancel, error text as the log when the log is empty) with a `buildHistory` property, in Packages/AppCore/Sources/AppCore/Builds/HostSession+Builds.swift and Packages/AppCore/Sources/AppCore/HostSession.swift
- [x] T009 [US1] Give `AppModel` a `buildHistory` store, set it on each new `HostSession`, and remove the records of a removed host, in Packages/AppCore/Sources/AppCore/AppModel.swift
- [x] T010 [US1] Add tests in Packages/AppCore/Tests/AppCoreTests/BuildHistoryStoreTests.swift: begin and finish, cap of 100, log cap, interrupted on load, file has no build argument value (SC-005), file mode 0600, clear one host keeps the other, recording through `HostSession` with `MockTransport` (success and failure)
- [x] T011 [US1] Add `HostSection.builds` (after Images, symbol `hammer`, full width) in App/Views/ContentView.swift and the section name `builds` in Packages/AppCore/Sources/AppCore/AppLink.swift with a test in Packages/AppCore/Tests/AppCoreTests/AppLinkTests.swift
- [x] T012 [P] [US1] Add `BuildHistoryView` (split view, empty state, toolbar Refresh) in App/Views/Builds/BuildHistoryView.swift
- [x] T013 [P] [US1] Add `BuildRowView` (status icon and text, name, source, start, duration, cached and total steps with plural variations) in App/Views/Builds/BuildRowView.swift
- [x] T014 [P] [US1] Add `BuildDetailView` (summary, error, step list with state, log with text selection) in App/Views/Builds/BuildDetailView.swift

## Phase 4: User Story 2 - See BuildKit builds on a Docker host (P2)

**Goal**: Docker hosts also show the `docker buildx history` records, gated on the CLI and the version.

**Independent Test**: The service tests with a fake runner give records, a detail, and each unavailable reason.

- [x] T015 [US2] Add `BuildxCommandRunner`, `LocalDockerCLIRunner` (CLI search paths and `GANTRY_DOCKER`, `DOCKER_HOST=unix://<socket>`), `SSHDockerCLIRunner` (Citadel `executeCommand` on a new client), `BuildxAvailability` and `BuildxHistoryService` (`availability`, `records`, `detail` with the `[A-Za-z0-9]` ref check) in Packages/AppCore/Sources/AppCore/Builds/BuildxHistory.swift
- [x] T016 [US2] Add `HostSession.buildxRunner()` (local: socket; SSH: the session client factory; Apple: nil) in Packages/AppCore/Sources/AppCore/Builds/HostSession+Builds.swift
- [x] T017 [US2] Add tests in Packages/AppCore/Tests/AppCoreTests/BuildxHistoryServiceTests.swift: no CLI, no buildx (exit 1, `unknown command`), too old, `ls` failure text, records mapped to `BuildRecord` with status and counts, detail joins inspect and logs, a bad ref runs no command
- [x] T018 [US2] Show buildx records next to the Gantry records (newest first, source label), the availability note, and the on-demand detail load, in App/Views/Builds/BuildHistoryView.swift and App/Views/Builds/BuildDetailView.swift

## Phase 5: User Story 3 - Manage the recorded history (P3)

**Goal**: The user removes the Gantry records of one host after a confirmation.

**Independent Test**: Clear History asks, removes the Gantry records of the host, and keeps the others.

- [x] T019 [US3] Add `DestructiveAction.Kind.clearBuildHistory` and a builder in Packages/AppCore/Sources/AppCore/DestructiveAction.swift, and its title, message and confirm label in App/Views/Shared/DestructiveActionText.swift
- [x] T020 [US3] Add the Clear History toolbar button with `destructiveConfirmation` in App/Views/Builds/BuildHistoryView.swift

## Phase 6: Polish

- [x] T021 Add the translations of all new strings for 28 languages in App/Localizable.xcstrings and Packages/AppCore/Sources/AppCore/Resources/Localizable.xcstrings; `scripts/check-localization.py` reports 0 problems
- [x] T022 Run the DockerKit and AppCore tests with `--scratch-path /Volumes/SanDisk2Tb/builds/gantry/build-history/<package>` and build the app with `xcodebuild -jobs 3 -derivedDataPath /Volumes/SanDisk2Tb/builds/gantry/build-history/DerivedData`
- [x] T023 Live check on the Apple host with `scripts/gantry-ctl` (quickstart.md): three records, restart keeps them, Clear History. Result on 2026-11-14 (Debug build, test host list): the Build Image sheet made two `gbh-live:1` records (Succeeded; the second has its `RUN` step cached) and failed `gbh-live-fail` records with the `RUN exit 3` step marked. After a restart, the records were there. Clear History asked for confirmation and removed all records of the host. The SSH Docker host showed its BuildKit records. T030 found a defect.
- [x] T026 [US1] Make a relative Dockerfile path absolute against the context before `container build --file` in Packages/DockerKit/Sources/DockerKit/AppleContainer/AppleContainerTransport.swift, with tests in Packages/DockerKit/Tests/DockerKitTests/AppleContainerTransportTests.swift (found by T027: the CLI resolves `--file` against the working directory of the process, so each Build Image sheet build on an Apple host failed)
- [x] T027 [US1] Add the gated live test `LiveBuildHistoryTests` (`GANTRY_BUILD_HISTORY_LIVE=1`) in Packages/AppCore/Tests/AppCoreTests/LiveBuildHistoryTests.swift: three real `container build` runs give a failed, a cached and a succeeded record
- [x] T028 [US2] Read the logs of `docker buildx history logs` from stderr when stdout is empty. Code in Packages/AppCore/Sources/AppCore/Builds/BuildxHistory.swift. Test in Packages/AppCore/Tests/AppCoreTests/BuildxHistoryServiceTests.swift. T029 found it: buildx 0.35.0 prints the progress on stderr.
- [x] T030 [US1] Record the output of a failed Apple build without the "Docker API error (500):" prefix. Before, the prefix hid step #1 and gave a wrong Executed count. Code in Packages/AppCore/Sources/AppCore/Builds/HostSession+Builds.swift (`buildErrorText`). Test `anAppleBuildErrorBecomesTheLogWithoutThePrefix` in Packages/AppCore/Tests/AppCoreTests/BuildHistoryStoreTests.swift. T023 found it.
- [x] T029 [US2] Add the gated live test `LiveBuildxSSHTests` (`GANTRY_BUILDX_SSH_HOST=user@host`) in Packages/AppCore/Tests/AppCoreTests/LiveBuildxSSHTests.swift. On an SSH Docker host (Docker 29.6.2, buildx 0.35.0) it checks the buildx gate, the list, the detail counts and the record of a Gantry classic build. It removes its `gbh-live-*` images and buildx records.
- [x] T024 Remove the `gbh-` containers and images (no Debug app process was started)
- [x] T025 Open the pull request `feat: show the build history with steps and cache use` (#73)

## Dependencies

- T001 before T004 and T005.
- T002 and T003 before T006 to T018.
- T006 before T007, T007 before T008 to T010.
- T011 before T012 to T014 (the section must exist).
- US2 needs T006 (the record type) and T012 (the view). US3 needs T007 and T012.
- T021 after all view tasks. T023 after T022.

## Parallel Example

```text
T002, T003 (two DockerKit files), then T004, T005 (two test files).
T012, T013, T014 (three view files).
```

## Implementation Strategy

MVP is US1: the parsers, the store, the recording and the views. US2 adds the buildx source. US3 adds Clear History.
