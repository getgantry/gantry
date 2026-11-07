<!-- STE deviation: spec-kit template headings, product names, Apple API names, CLI flags and paths stay verbatim. -->
# Implementation Plan: External Drives for Containers, Images and Volumes

**Branch**: `feat/external-storage` | **Date**: 2026-11-07 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/004-external-storage/spec.md`

**Note**: The implementation started before this plan. The plan describes the approach of the brief. The research results go to `/Volumes/SanDisk2Tb/builds/gantry-027/storage/REPORT.md`.

## Summary <!-- slop: spec-kit template heading -->

Research first. Read the 1.7.1 source to learn how `--app-root` persists, which volume options exist, and what bind mounts on `/Volumes` need. Find a copy tool that keeps sparse files, owners and extended attributes.

Then build in AppCore, behind protocols for disks, files, processes and mount events. The parts are disk information, storage usage, a mount monitor, managed folder volumes, a data root move plan and volume transfers. The views are a new Storage pane in System, a location choice in New Volume, a bind mount picker, banners, and a move sheet. Long work runs through `OperationCenter`.

## Technical Context

**Language/Version**: Swift 6, Xcode 27 SDK

**Primary Dependencies**: SwiftUI, AppCore, DockerKit, Foundation `URLResourceValues`, DiskArbitration, `NSWorkspace` mount notifications

**Storage**: The data root of the container tool. Gantry's own store for managed folder volumes and the chosen root. User folders on external disks.

**Testing**: Swift Testing in `Packages/AppCore/Tests/AppCoreTests` with fake disks, files and processes. Live tests only in `/Volumes/SanDisk2Tb/builds/gantry-027/storage/live/` with `gstore-` objects.

**Target Platform**: macOS 26 or later

**Project Type**: Desktop app (SwiftUI) with local Swift packages

**Performance Goals**: The Storage pane shows in less than 10 s for a root of about 6 GB. Mount events show in less than 5 s.

**Constraints**: Do not move the user's real root. Do not stop the services. The cluster `gtest` and the work of other agents depend on them. Builds go to `/Volumes/SanDisk2Tb/builds/gantry-027/storage/`. New UI goes into new files where possible.

**Scale/Scope**: About 7 new AppCore files, 3 new view files, and changes to about 8 existing files.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Check | Result |
|---|---|---|
| I. Native Mac App, HIG First | The Storage pane uses grouped forms and the shared components. Banners use the existing error banner. The move sheet is a standard sheet. | Pass |
| II. Logic in Packages, Thin Views, Tests | Disk info parsing, usage, move plans, checks and mount state are in AppCore with tests. Disks, files, processes and mount events are behind protocols, so tests do not touch real disks. | Pass |
| III. No Required Dependencies, Version-Gated | Works with the container tool only. Docker options appear only on Docker hosts through the host capabilities. A `--app-root` feature that needs a newer CLI is gated on the version. | Pass |
| IV. Safety of User Data and Secrets | The source is deleted only after a verified copy, with `DestructiveAction` and Touch ID. Gantry asks before it stops the services or recreates containers. Cancel before the switch keeps the old root. | Pass. This is the main risk of the feature. |
| V. Every String in Every Language | New strings in English in the catalogs, list in `storage/new-strings.txt`. The merge needs translations for all 28 languages and a green `scripts/check-localization.py`. | Pass with a condition: translations are still to do |

Post-design re-check: open until the research finds how the root persists.

## Project Structure

### Documentation (this feature)

```text
specs/004-external-storage/
├── spec.md
├── plan.md
└── tasks.md
```

### Source Code (repository root)

```text
Packages/AppCore/Sources/AppCore/Storage/                # new folder
├── DiskInfo.swift            # disk name, file system, space, kind (protocol + system implementation)
├── StorageUsage.swift        # size by category, allocated size of sparse files
├── MountMonitor.swift        # mount, will-unmount and unmount events, affected containers
├── ManagedVolumes.swift      # managed folder volumes in Gantry's store
├── DataRootMove.swift        # move plan, checks, copy, verify, switch, start, check
├── DataRootSettings.swift    # the chosen root for every later start
└── VolumeTransfer.swift      # volume move with a helper container, export, import, image save and load
Packages/AppCore/Sources/AppCore/
├── AppleContainerControl.swift   # startServices and restartServices with the chosen root
├── ContainerTooling.swift        # version gate for root options if needed
├── ContainerForm.swift           # managed volumes and bind mount warnings
├── HostSession.swift             # disk state on the host and on containers
└── OperationCenter.swift         # progress and Cancel for long work
Packages/AppCore/Tests/AppCoreTests/
├── StorageTests.swift            # new
└── LiveStorageTests.swift        # new, gated, scratch folder only
Packages/DockerKit/Sources/DockerKit/Endpoints/
├── VolumesNetworksExtended.swift # local driver bind options
└── ImagesExtended.swift          # image save and load streams
App/Views/AppleSystem/
├── AppleStoragePane.swift        # new
├── MoveDataRootSheet.swift       # new
└── AppleSystemView.swift         # add the Storage pane
App/Views/Volumes/NewVolumeSheet.swift, App/Views/Volumes/VolumeListView.swift
App/Views/Containers/CreateContainerSheet.swift, App/Views/Containers/ContainerFormComponents.swift
App/Views/Containers/ContainerDetailView.swift, App/Views/Containers/ContainerListView.swift
App/Views/Images/ImageListView.swift
App/Views/Shared/DiskBanner.swift # new
App/Views/MenuBar/AppleServicesMenuSection.swift, Widgets/GantryControls.swift, App/SystemIntegration/ControlRequestHandler.swift
App/Notifications/ContainerNotifier.swift
App/Localizable.xcstrings
```

**Structure Decision**: The new logic goes into a new `Storage` folder in AppCore. New UI goes into new files, because other branches restyle the existing views.

## Complexity Tracking

No violations.
