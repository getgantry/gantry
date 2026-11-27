<!-- STE deviation: spec-kit template headings, task format, product names, Swift names, CLI flags and paths stay verbatim. -->
# Tasks: Container Changes and Commit Options

**Input**: `/specs/018-container-diff/`

## Phase 1: Setup

- [x] T001 Set `.specify/feature.json` to `specs/018-container-diff`; build output in `/Volumes/SanDisk2Tb/builds/gantry/container-diff/`

## Phase 2: DockerKit

- [x] T002 [US1] Add `ContainerChange` (`path`, `kind`: changed 0, added 1, deleted 2; unknown kinds are changed) in `Packages/DockerKit/Sources/DockerKit/Models/ContainerChange.swift`
- [x] T003 [US1] Add `DockerClient.containerChanges(id:)`; a `null` body is `[]`, in `Packages/DockerKit/Sources/DockerKit/Endpoints/ContainersExtended.swift`
- [x] T004 [US3] Add `author` and `pause` (default `true`) to `DockerClient.commitContainer`
- [x] T005 [US1] Apple transport: `GET /containers/{id}/changes` throws a 501 "File changes" error
- [x] T006 [US1] Tests with a fixture from Docker on nettop in `Packages/DockerKit/Tests/DockerKitTests/EndpointCoverageTests.swift` and `AppleContainerTransportTests.swift`

## Phase 3: AppCore

- [x] T007 [US1] Add `ContainerChanges.Counts`, `filtered(_:kinds:search:)`, `tree(_:)` and `rowLimit` in `Packages/AppCore/Sources/AppCore/ContainerChanges.swift`
- [x] T008 [US1] Add `HostSession.containerChanges(containerID:)` in `Packages/AppCore/Sources/AppCore/HostSession.swift`
- [x] T009 [US3] `HostSession.commit` sends `author` and `pause` and refreshes the images
- [x] T010 [US1] [US3] `HostCapabilities.containerChanges` and `commitOptions` (Docker on, Apple off) in `Packages/AppCore/Sources/AppCore/DockerHost.swift`
- [x] T011 Tests in `Packages/AppCore/Tests/AppCoreTests/ContainerChangesTests.swift` and `HostSessionTests.swift`, including 50,000 entries (SC-003)

## Phase 4: App

- [x] T012 [US1] [US2] `ContainerChangesView`: counts, kind filter, search, flat list and tree, work in `Task.detached`, row limit line
- [x] T013 [US1] Add the Changes tab to `ContainerDetailView`, only when `containerChanges` is on
- [x] T014 [US3] `CommitImageSheet`: message, author, "Pause during commit"; hidden on Apple hosts
- [x] T015 [US4] Badge for added and changed items in `FilesView` (Docker only)
- [x] T016 Strings in `App/Localizable.xcstrings` with 28 languages; `python3 scripts/check-localization.py` shows 0 problems

## Phase 5: Checks

- [x] T017 `swift test` of DockerKit and AppCore
- [x] T018 `xcodebuild` Debug build of the app
- [x] T019 SC-001 and SC-002 live on nettop (Docker 29.6.2) with `diff-` test objects; removed after. SC-002 was checked with the exact `POST /commit` query that the unit test asserts, not through the sheet
- [x] T020 Check the Changes tab (flat list, counts, row limit), the Files badges and the Apple host (no tab, Overview fallback) in the running Debug app through `scripts/gantry-ctl` and the new `debug/tab` link
- [ ] T021 Check the tree layout and the Commit sheet in the running app: `gantry-ctl` cannot switch the layout or open the sheet, and the GUI was not in scope. Unit tests cover the tree; the sheet is not checked by hand
