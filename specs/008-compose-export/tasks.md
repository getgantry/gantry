---

description: "Task list for the Compose export of containers"
---

<!-- STE deviation: spec-kit template headings, task format, Swift identifiers, Compose keys, CLI flags and paths stay verbatim. -->
# Tasks: Export a Running Container as a Compose File

**Input**: Design documents from `/specs/008-compose-export/`

**Prerequisites**: plan.md, spec.md

**Tests**: Required for the logic in AppCore (constitution principle II). The sheet gets a live check with `scripts/gantry-ctl`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: The user story of the task (US1 to US5)

## Phase 1: Setup

- [ ] T001 Create the spec folder `specs/008-compose-export/` with spec.md, plan.md and tasks.md, and point `.specify/feature.json` at it
- [ ] T002 Capture a live `container inspect` (CLI 1.7.1) of a `gce-` test container with a port, a named volume, a read-only bind, a tmpfs mount, a network, labels, limits and a capability, for the Apple fixture

## Phase 2: Foundational

- [ ] T003 Add the public types `ComposeExportSource`, `ComposeExportOptions`, `ComposeExportSecret`, `ComposeExportWarning`, `ComposeExportResult` and `ComposeExporter` in Packages/AppCore/Sources/AppCore/Compose/ComposeExport.swift
- [ ] T004 Add the service draft and the YAML node builder with fixed key order, safe quoting and `$` escaping in Packages/AppCore/Sources/AppCore/Compose/ComposeExport.swift (FR-008)

## Phase 3: User Story 1 - Export one container (P1)

- [ ] T005 [US1] Map a Docker inspect body to a service draft in Packages/AppCore/Sources/AppCore/Compose/ComposeExport+Docker.swift: image, process (R3), env and labels without image defaults, ports, binds, named and anonymous volumes, tmpfs, networks with aliases and static IPv4, network mode, restart policy, healthcheck, resources, and the other host settings of FR-004
- [ ] T006 [US1] Declare named volumes and networks at the top level as `external: true` (FR-005)
- [ ] T007 [US1] Add `HostSession.composeExportSources(for:)` in Packages/AppCore/Sources/AppCore/Compose/ComposeExport+Session.swift
- [ ] T008 [P] [US1] Add the Docker fixture and tests in Packages/AppCore/Tests/AppCoreTests/ComposeExportFixtures.swift and ComposeExportTests.swift: field mapping, image defaults removed, healthcheck, quoting, `$$`, round-trip parse with `ComposeParser` (FR-012)
- [ ] T009 [US1] Add App/Views/Compose/ComposeExportSheet.swift: loading state, YAML view, Copy, Save… with `NSSavePanel` (`docker-compose.yml`), Done, error state (FR-011)
- [ ] T010 [US1] Add "Export as Compose…" to the container context menu (App/Views/Containers/ContainerListView.swift) and to the More menu of the detail view (App/Views/Containers/ContainerDetailView.swift) (FR-001)

## Phase 4: User Story 2 - Secrets (P1)

- [ ] T011 [US2] Mask secret-like environment values as `${NAME}` unless the option includes them; list the masked variables in the result (FR-006)
- [ ] T012 [US2] In the sheet, show a toggle for each masked variable; write the file with `0600` when the result includes a secret value (FR-007)
- [ ] T013 [P] [US2] Tests: a masked value is not in the YAML; an included value is; `includesSecretValues` is correct (SC-003)

## Phase 5: User Story 3 - Several containers (P2)

- [ ] T014 [US3] Unique service names, Compose labels removed, service names and project name from Compose labels, `depends_on` from the Compose label when the dependency is in the export, `network_mode: service:<name>` between exported containers
- [ ] T015 [US3] Add "Export as Compose…" to the context menu of several selected containers in App/Views/Containers/ContainerListView.swift
- [ ] T016 [P] [US3] Tests: two services share one top-level network and volume; duplicate names; Compose labels; `service:` network mode

## Phase 6: User Story 4 - Warnings (P2)

- [ ] T017 [US4] Add the warnings of research R6 for Docker sources (FR-009)
- [ ] T018 [US4] Show the warnings in the sheet with an SF Symbol and text, one accessibility element each, and "No warnings" when the list is empty
- [ ] T019 [P] [US4] Tests: `--rm` and an anonymous volume give two warnings; an image that was not inspected gives a warning

## Phase 7: User Story 5 - Apple container hosts (P2)

- [ ] T020 [US5] Map the original Apple object in Packages/AppCore/Sources/AppCore/Compose/ComposeExport+Apple.swift: image reference, process (R2), env, user, working directory, ports, volume names, binds with `ro`, tmpfs, networks, labels without Gantry labels, capabilities, read-only root, init, shared memory size, sysctls, ulimits, DNS, CPU and memory (FR-010)
- [ ] T021 [US5] Add the Apple warnings of research R6
- [ ] T022 [P] [US5] Tests with the live Apple 1.7.1 fixture: mapping, the process cases of R2, the warnings, round-trip parse

## Phase 8: Polish

- [ ] T023 Add the new strings with translations for 28 languages; `scripts/check-localization.py` reports 0 problems (FR-014, SC-004)
- [ ] T024 Run the AppCore tests of the feature and the full AppCore test suite one time
- [ ] T025 Build the Debug app into /Volumes/SanDisk2Tb/builds/gantry/compose-export/DerivedData
- [ ] T026 Live check with `scripts/gantry-ctl` on the Apple host: open the sheet for the `gce-web` container, read the YAML and the warnings, Copy; then remove the `gce-` test resources
- [ ] T027 Rebase on `origin/main`, open the pull request "feat: export a running container as a compose file"
