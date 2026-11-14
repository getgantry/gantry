---

description: "Task list for the Apple container mounts fix"
---

<!-- STE deviation: spec-kit template headings, task format, product names, CLI flags and paths stay verbatim. -->
# Tasks: Apple Container Mounts in Overview

**Input**: Design documents from `/specs/014-apple-overview-mounts/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md

**Tests**: Required (constitution principle II: parsers of CLI output have tests with fixtures from the real tool).

## Format: `[ID] [P?] [Story] Description`

## Phase 1: Setup

- [x] T001 Capture live `container inspect` (1.7.1) of a container with a read-only bind, a read-write bind, a named volume and a tmpfs; put the `mounts` array (home paths replaced) in `Packages/DockerKit/Tests/DockerKitTests/AppleContainerMountsTests.swift` as the fixture

## Phase 2: Foundational

- [x] T002 Rewrite `mountJSON(fromAppleMount:)` in `Packages/DockerKit/Sources/DockerKit/AppleContainer/AppleContainerJSON.swift` per data-model.md: `virtiofs` → `bind`; `Name` from `type.volume.name`, else `name`; `RW = !readOnly` where read-only is "`options` contains `ro`, or `readOnly`/`readonly` is true", always set

## Phase 3: User Story 1 - The Overview tab shows mounts as they are (P1)

**Goal**: Overview shows `ro` for read-only binds and the volume name for named volumes.

**Independent Test**: translate the T001 fixture and check type, name, source, target and RW of each mount.

- [x] T003 [US1] Add `MountPoint.displaySource` in `Packages/DockerKit/Sources/DockerKit/Models/Container.swift` (name for a named volume, else source, else name)
- [x] T004 [US1] Use `displaySource` in `mountsSection` in `App/Views/Containers/ContainerDetailView.swift`
- [x] T005 [P] [US1] Tests in `Packages/DockerKit/Tests/DockerKitTests/AppleContainerMountsTests.swift`: the fixture through the inspect body and the list row; old `readOnly` bool; string type; volume `options: ["ro"]`; unknown type passes through; `displaySource` for Apple and Docker mounts
- [x] T006 [US1] Docker side: `docker inspect` of a test container with a named volume and a read-only bind on `nettop.local`; decode its `Mounts` in a fixture test of `displaySource` and `rw`
- [x] T007 [US1] Build the app (`xcodebuild -jobs 3`, DerivedData on the external disk)
- [ ] T008 [US1] GUI live check: start the Debug build with a test host list, open the fixture container and read the Overview mounts with `scripts/gantry-ctl` (needs "GUI is yours"). Open: the screen is shared and GUI control was not given.

## Phase 4: User Story 2 - Other features read the correct mounts (P2)

**Goal**: copy-as-run, Explain and the volume users count get the read-only flag and the volume name.

**Independent Test**: AppCore tests from the translated fixture.

- [x] T009 [P] [US2] Tests in `Packages/AppCore/Tests/AppCoreTests/AppleMountsConsumerTests.swift`: `ContainerRecipe.volumes(details:)` gives `/Users/me/project/bindro:/ro:ro`, `/Users/me/project/bindrw:/rw`, `gaom-data:/data` and no tmpfs; `VolumeTransferPlan.users(of: .named("gaom-data"))` and `DestructiveAction.removeVolume` count the container; `ExplainInspectText.render(.mounts)` names the volume and `ro`
- [x] T010 [US2] Run the existing mount-related tests (`ContainerRecipeTests`, DockerKit Apple JSON tests) and fix regressions from the `virtiofs` → `bind` change (no regressions: DockerKit 311 and AppCore 704 tests pass; the old `virtiofs` recipe test still passes)

## Phase 5: Polish

- [x] T011 `scripts/check-localization.py` reports 0 problems (no new strings expected)
- [x] T012 Remove the test containers and volumes (`gaom-*`) on this Mac and on `nettop.local`
- [x] T013 Update the status line of spec.md

## Dependencies

T001 → T002 → T003 → T004/T005/T006/T009 → T007 → T008. US2 needs only T002.

## Parallel Example

T005 (DockerKit tests) and T009 (AppCore tests) are in different packages and can run at the same time.

## Implementation Strategy

MVP is US1 (T001–T007). US2 is tests of consumers that already read the fields; no code change is expected there.
