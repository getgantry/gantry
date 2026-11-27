<!-- STE deviation: spec-kit template headings, task format, product names, Swift names, CLI flags and paths stay verbatim. -->
# Tasks: Edit the Resources of a Container

**Input**: `/specs/021-live-limits/`

## Phase 1: Foundational

- [x] T001 Decode `MemoryReservation` and `MemorySwap` in `ContainerDetails.HostConfig` (`Packages/DockerKit/Sources/DockerKit/Models/ContainerDetails.swift`)
- [x] T002 Add `ContainerResourceUpdate` and `DockerClient.updateContainer(id:update:)`; encode only the set keys (`Packages/DockerKit/Sources/DockerKit/Models/ContainerResourceUpdate.swift`, `Endpoints/ContainersExtended.swift`)
- [x] T003 DockerKit test of the update body (`Packages/DockerKit/Tests/DockerKitTests/EndpointCoverageTests.swift`)

## Phase 2: User Story 3 - Validation (P1)

- [x] T004 [US3] Add `MemorySize.parse` and `MemorySize.format` (units b, k, m, g, t, optional "i" and "b"; no unit is MiB; "-1" and "unlimited" for swap) in `Packages/AppCore/Sources/AppCore/ContainerResources.swift`
- [x] T005 [US3] Add `ContainerResources` (values from `ContainerDetails`), `ContainerResourceForm` with field errors (positive, CPU above host count, Docker cannot remove a limit, Apple integer CPUs and 200 MiB minimum) and `dockerUpdate()` that holds only the changed fields
- [x] T006 [US3] Unit tests in `Packages/AppCore/Tests/AppCoreTests/ContainerResourcesTests.swift`

## Phase 3: User Story 1 and 2 - Apply (P1)

- [x] T007 [US2] Add `HostSession.recreate(_:adjust:)` and make the volume recreate use it; keep `Memory` and `NanoCpus` in `recreationRequest` (`ContainerRecreate.swift`, `Storage/HostSession+Storage.swift`)
- [x] T008 [US1] [US2] Add `HostSession.updateResources(of:form:)`: Docker update or Apple recreate, then refresh the inspect cache and the list, and increment `resourceRevision` (`Packages/AppCore/Sources/AppCore/HostSession+Resources.swift`)
- [x] T009 [US1] [US2] Tests: the recreate request keeps the limits; the Apple request gets the new values
- [x] T010 [US1] [US2] Add `EditResourcesSheet` with the field errors, the daemon error, and the confirmation for "Apply and Recreate…" (`App/Views/Containers/EditResourcesSheet.swift`)
- [x] T011 [US1] Add "Edit Resources…" to `ContainerActionsMenu` and to the More menu of `ContainerDetailView`
- [x] T012 [US1] Use `resourceRevision` in the `.task(id:)` of the Overview and the Stats tab; show a Resources group (CPU, memory, reservation, swap) in the Overview

## Phase 4: Polish

- [x] T013 Add the new strings in 28 languages to `App/Localizable.xcstrings` and the AppCore catalog; `python3 scripts/check-localization.py` shows 0 problems
- [x] T014 Run the DockerKit and AppCore test suites; build the app
- [x] T015 Check SC-001 on `nettop.local` with a `lim-` container: the update body of the form changes `Memory`, `StartedAt` stays, the daemon error comes back as text (checked with curl on the Docker socket and the same body, not through the app)
- [x] T016 Check SC-002 on this Mac with a `lim-` container: `container create` with the recreate arguments gives the new `cpus` and `memoryInBytes`
- [x] T017 Check the Overview Resources group in a running Debug build with `scripts/gantry-ctl` (`lim-ui` with 3 CPUs and 768 MB shows these values)
- [ ] T018 Check the sheet itself in a running Debug build: open, field errors, daemon error, recreate confirmation. Open: `gantry-ctl` has no link that opens a sheet, and the GUI is not available to this work
- [x] T019 Add the gated live test `liveAppleResourcesRecreate` (`Packages/AppCore/Tests/AppCoreTests/LiveResourcesTests.swift`); it passed on apple/container 1.7.1
