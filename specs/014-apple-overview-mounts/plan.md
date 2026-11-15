<!-- STE deviation: spec-kit template headings, product names, JSON keys, CLI flags and paths stay verbatim. -->
# Implementation Plan: Apple Container Mounts in Overview

**Branch**: `fix/apple-overview-mounts` | **Date**: 2026-11-14 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/014-apple-overview-mounts/spec.md`

## Summary

One fix in the DockerKit translation and one small change in the Overview row.

1. `Packages/DockerKit/Sources/DockerKit/AppleContainer/AppleContainerJSON.swift`,
   `mountJSON(fromAppleMount:)`. Read the type key and its body (`{"volume": {"name": …}}`),
   map `virtiofs` to `bind`, set `Name` for volumes, and set `RW` from `options` (`ro`) or the
   old `readOnly`/`readonly` bool. `RW` is always set (Docker always writes it). The list body
   and the inspect body already use this one function (FR-006).
2. `Packages/DockerKit/Sources/DockerKit/Models/Container.swift`: add
   `MountPoint.displaySource` (volume name for a named volume, else the source, else the name).
   `App/Views/Containers/ContainerDetailView.swift`, `mountsSection`, shows it. This also fixes
   Docker hosts, where Overview showed `/var/lib/docker/volumes/<name>/_data`.
3. Fixture tests from a live `container inspect` on 1.7.1 (read-only bind, read-write bind,
   named volume, tmpfs) in DockerKit, and consumer tests in AppCore (recipe volumes, Explain
   mounts text, volume users count).

The parsing knowledge comes from PR #68 (`setAppleMounts` and `appleMountKind` in
`ComposeExport+Apple.swift` on `origin/feat/compose-export`). This fix does not import that
code; it is not merged.

## Technical Context

**Language/Version**: Swift 6, Xcode 27 SDK

**Primary Dependencies**: DockerKit, AppCore, SwiftUI

**Storage**: N/A

**Testing**: Swift Testing in `Packages/DockerKit/Tests/DockerKitTests` and
`Packages/AppCore/Tests/AppCoreTests`. Docker inspect of a named volume on the test host
`nettop.local` (Docker 29.6.2) for the Docker side of `displaySource`.

**Target Platform**: macOS 26 or later

**Project Type**: Desktop app (SwiftUI) with local Swift packages

**Constraints**: Builds go to `/Volumes/SanDisk2Tb/builds/gantry/apple-overview-mounts/`,
`-jobs 3`. No GUI control (shared screen).

**Scale/Scope**: about 40 lines of logic, one view line.

## Constitution Check

- I. HIG: the Overview row keeps its layout. Pass.
- II. Logic in packages with tests: the translation and `displaySource` are in DockerKit,
  with fixtures from the real CLI. The view only calls `displaySource`. Pass.
- III. Version-gated CLI use: the parser accepts the 1.7.1 shape and the older
  `readOnly` bool and string type. No new CLI call. Pass.
- IV. Safety: the volume delete confirmation now counts the Apple containers that use the
  volume (before: 0). Pass, an improvement.
- V. Strings: no new strings. Pass.

Post-design check: no change. Pass.

## Project Structure

### Documentation (this feature)

```text
specs/014-apple-overview-mounts/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── checklists/requirements.md
└── tasks.md
```

No `contracts/`: the change has no external interface. The Docker-shaped JSON is internal.

### Source Code (repository root)

```text
Packages/DockerKit/Sources/DockerKit/AppleContainer/AppleContainerJSON.swift
Packages/DockerKit/Sources/DockerKit/Models/Container.swift
Packages/DockerKit/Tests/DockerKitTests/AppleContainerMountsTests.swift
Packages/AppCore/Tests/AppCoreTests/AppleMountsConsumerTests.swift
App/Views/Containers/ContainerDetailView.swift
```

## Complexity Tracking

None.
