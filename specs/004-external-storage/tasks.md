---

description: "Task list for external drives for containers, images and volumes"
---

<!-- STE deviation: spec-kit template headings, task format, product names, CLI flags and paths stay verbatim. -->
# Tasks: External Drives for Containers, Images and Volumes

**Input**: Design documents from `/specs/004-external-storage/`

**Prerequisites**: plan.md, spec.md

**Tests**: Required. Constitution principle II asks for tests for all logic, with side effects behind protocols.

**Organization**: Tasks are grouped by user story.

**Status note**: The implementation started before this list. All tasks are open, because nobody checked the code against this list yet. Tick a task only after you check its code on branch `feat/external-storage`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: The user story of the task (US1 to US6)

## Phase 1: Setup (Research)

- [x] T001 Read the 1.7.1 source in /Volumes/SanDisk2Tb/builds/gantry-027/ac17/upstream/c171 (read only) and find how `--app-root`, `--install-root` and `--log-root` persist. Write the result in /Volumes/SanDisk2Tb/builds/gantry-027/storage/REPORT.md
- [x] T002 [P] Find the volume options (`--opt`) in the 1.7.1 source that could place a volume elsewhere, and write the result in the report
- [ ] T003 [P] Test bind mounts from `/Volumes` (virtiofs sharing, permissions, case sensitivity) in /Volumes/SanDisk2Tb/builds/gantry-027/storage/live/ with `gstore-` containers, and write the result in the report
- [x] T004 [P] Compare `ditto`, `cp -c` and `rsync --sparse` on a sparse test image in the scratch folder. Select the tool that keeps sparse files, owners and extended attributes.

---

## Phase 2: Foundational (Blocking Prerequisites)

- [x] T005 [P] Tests for disk kinds (internal, external, removable, network), file systems and space in Packages/AppCore/Tests/AppCoreTests/StorageTests.swift
- [x] T006 Implement the disk information protocol and the system implementation (`URLResourceValues`, DiskArbitration) in Packages/AppCore/Sources/AppCore/Storage/DiskInfo.swift
- [x] T007 Add file system and process protocols with fakes for tests in Packages/AppCore/Sources/AppCore/Storage/DiskInfo.swift and Packages/AppCore/Tests/AppCoreTests/StorageTests.swift

**Checkpoint**: The tests describe disks with no real disk.

---

## Phase 3: User Story 1 - Where the data is and its size (Priority: P1) (MVP)

**Goal**: A read-only Storage pane.

**Independent Test**: Compare the pane with `du` on the data root.

- [x] T008 [P] [US1] Tests for size by category and allocated size of sparse files in Packages/AppCore/Tests/AppCoreTests/StorageTests.swift
- [x] T009 [US1] Implement storage usage in Packages/AppCore/Sources/AppCore/Storage/StorageUsage.swift
- [x] T010 [US1] Create the Storage pane (root, disk, categories, volumes) in App/Views/AppleSystem/AppleStoragePane.swift
- [x] T011 [US1] Add the Storage pane to App/Views/AppleSystem/AppleSystemView.swift for hosts of the container tool

---

## Phase 4: User Story 2 - Unplugged-disk safety (Priority: P1)

**Goal**: Clear banners, disabled Start, and an eject warning.

**Independent Test**: Eject a scratch disk with a bind source.

- [x] T012 [P] [US2] Tests for mount events and for the containers that each disk affects in Packages/AppCore/Tests/AppCoreTests/StorageTests.swift
- [x] T013 [US2] Implement the mount monitor behind a protocol over `NSWorkspace` didMount, willUnmount and didUnmount in Packages/AppCore/Sources/AppCore/Storage/MountMonitor.swift
- [x] T014 [US2] Add the disk state to the host and to each container, and block Start for affected containers, in Packages/AppCore/Sources/AppCore/HostSession.swift
- [ ] T015 [P] [US2] Create the disk banner in App/Views/Shared/DiskBanner.swift
- [x] T016 [US2] Show the banner and the disabled Start in App/Views/Containers/ContainerListView.swift and App/Views/Containers/ContainerDetailView.swift
- [x] T017 [US2] Post the eject warning notification in App/Notifications/ContainerNotifier.swift

---

## Phase 5: User Story 3 - Volumes in a disk folder (Priority: P2)

**Goal**: "Folder on a disk" in New Volume.

- [x] T018 [P] [US3] Tests for the managed volume store and the Docker bind options in Packages/AppCore/Tests/AppCoreTests/StorageTests.swift
- [x] T019 [US3] Implement managed folder volumes in Packages/AppCore/Sources/AppCore/Storage/ManagedVolumes.swift
- [x] T020 [US3] Add the local driver bind options (`type=none`, `o=bind`, `device=<path>`) in Packages/DockerKit/Sources/DockerKit/Endpoints/VolumesNetworksExtended.swift
- [x] T021 [US3] Add the location choice in App/Views/Volumes/NewVolumeSheet.swift and list managed volumes in App/Views/Volumes/VolumeListView.swift
- [x] T022 [US3] Make managed volumes selectable in Packages/AppCore/Sources/AppCore/ContainerForm.swift and App/Views/Containers/CreateContainerSheet.swift

---

## Phase 6: User Story 4 - Bind mount picker (Priority: P2)

- [x] T023 [P] [US4] Tests for the warnings (removable disk, exFAT, FAT, NTFS) in Packages/AppCore/Tests/AppCoreTests/StorageTests.swift
- [x] T024 [US4] Add the warnings to Packages/AppCore/Sources/AppCore/ContainerForm.swift
- [x] T025 [US4] Add the folder picker with external disks and the warnings in App/Views/Containers/ContainerFormComponents.swift

---

## Phase 7: User Story 5 - Volume move, export and image save (Priority: P3)

- [x] T026 [P] [US5] Tests for the volume move plan (copy, verify, recreate only after confirmation) in Packages/AppCore/Tests/AppCoreTests/StorageTests.swift
- [x] T027 [US5] Implement the volume move with a helper container and `cp -a`, and export and import as `.tar`, in Packages/AppCore/Sources/AppCore/Storage/VolumeTransfer.swift
- [x] T028 [US5] Implement image save and load (`container image save` and `load`, `docker save` and `load`) in Packages/AppCore/Sources/AppCore/Storage/VolumeTransfer.swift and Packages/DockerKit/Sources/DockerKit/Endpoints/ImagesExtended.swift
- [x] T029 [US5] Add the actions with progress in App/Views/Volumes/VolumeListView.swift and App/Views/Images/ImageListView.swift

---

## Phase 8: User Story 6 - Move the data root (Priority: P3)

- [x] T030 [P] [US6] Tests for the move checks (file system, network disk, free space) in Packages/AppCore/Tests/AppCoreTests/StorageTests.swift
- [x] T031 [P] [US6] Tests for the move steps, Cancel before the switch, and no delete before the verification in Packages/AppCore/Tests/AppCoreTests/StorageTests.swift
- [x] T032 [US6] Implement the move plan through `OperationCenter` in Packages/AppCore/Sources/AppCore/Storage/DataRootMove.swift
- [x] T033 [US6] Store the chosen root and use it in every start in Packages/AppCore/Sources/AppCore/Storage/DataRootSettings.swift and Packages/AppCore/Sources/AppCore/AppleContainerControl.swift
- [x] T034 [US6] Use the chosen root in App/Views/MenuBar/AppleServicesMenuSection.swift, Widgets/GantryControls.swift and App/SystemIntegration/ControlRequestHandler.swift
- [x] T035 [US6] Create the move sheet with the disk list, the confirmations and the delete of the old copy through `DestructiveAction` in App/Views/AppleSystem/MoveDataRootSheet.swift
- [x] T036 [US6] Tell the user how the container tool finds the root, in App/Views/AppleSystem/AppleStoragePane.swift
- [x] T037 [US6] Test the copy and the verification on a small fake root in the scratch folder. Keep the real root and the running services as they are.

---

## Phase 9: Polish & Cross-Cutting Concerns

- [ ] T038 Write the gated live test for bind volumes and a volume move in Packages/AppCore/Tests/AppCoreTests/LiveStorageTests.swift, and remove all `gstore-` objects after it
- [x] T039 [P] Write the list of new string keys to /Volumes/SanDisk2Tb/builds/gantry-027/storage/new-strings.txt
- [x] T040 Translate the new strings into all supported UI languages and run scripts/check-localization.py
- [x] T041 Run `swift test` in AppCore and DockerKit with `--scratch-path /Volumes/SanDisk2Tb/builds/gantry-027/storage/<Package>`
- [ ] T042 Build the Debug app with `-derivedDataPath /Volumes/SanDisk2Tb/builds/gantry-027/storage/DerivedData` and check the new UI with scripts/gantry-ctl
- [x] T043 Write in /Volumes/SanDisk2Tb/builds/gantry-027/storage/REPORT.md which steps stayed untested on the real install

---

## Dependencies & Execution Order

- Phase 1 research comes first. T001 blocks T033 and T036.
- Phase 2 blocks all stories.
- US1 and US2 come before US6. US3 and US4 are independent. US5 uses the copy tool from T004.
- T040 blocks the merge (constitution principle V).

## Parallel Example: Phase 1

```bash
Task: "Find the volume options in the 1.7.1 source"
Task: "Test bind mounts from /Volumes"
Task: "Compare copy tools on a sparse image"
```

## Implementation Strategy

1. MVP: Phases 1 and 2, then User Stories 1 and 2.
2. Add User Stories 3 and 4.
3. Add User Story 5, then User Story 6 last, because it has the most risk.
4. Phase 9.
