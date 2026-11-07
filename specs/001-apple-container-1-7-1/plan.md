<!-- STE deviation: spec-kit template headings, product names and paths stay verbatim. -->
# Implementation Plan: Full Support for Apple container 1.7.1

**Branch**: `feat/apple-container-1-7-1` | **Date**: 2026-11-07 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-apple-container-1-7-1/spec.md`

**Note**: The implementation started before this plan. The plan describes the approach that the branch follows. The branch report is `/Volumes/SanDisk2Tb/builds/gantry-027/ac171/REPORT.md`.

## Summary <!-- slop: spec-kit template heading -->

Add the user-visible changes of Apple's container tool 1.7.1 that main does not have yet. A new diagnosis in AppCore turns the cluster service connection error into a clear message with a fix. The config file editor in AppCore can read and write lists of strings. The System properties pane gets a list editor for the `[container.dns]` defaults. The stats decoder in DockerKit uses the new `cpuUtilization` value with the old calculation as a fallback. A check makes sure that the kernel install follows the tool. The review of all other changes adds a builder image check. Every new feature is gated on the tool version.

## Technical Context

**Language/Version**: Swift 6 (Swift tools 6.1 in the packages), Xcode 27 SDK

**Primary Dependencies**: SwiftUI, AppCore, DockerKit (`AppleContainerTransport` emulates the Docker API over the `container` CLI), GantryMCP, Yams

**Storage**: The user's config file `~/.config/container/config.toml` (TOML, edited in place)

**Testing**: Swift Testing in `Packages/AppCore/Tests/AppCoreTests`, `Packages/DockerKit/Tests/DockerKitTests` and `Packages/GantryMCP/Tests`. Fixtures come from a live 1.7.1 run (`/Volumes/SanDisk2Tb/builds/gantry-027/ac171/live-1.7.1`) and from the 1.7.1 source.

**Target Platform**: macOS 26 or later (Apple silicon)

**Project Type**: Desktop app (SwiftUI) with local Swift packages

**Performance Goals**: The diagnosis adds at most one file system check per failed cluster command. No extra process runs per stats sample.

**Constraints**: CLI 1.6.1 must keep working. Live checks are read-only. Builds go to `/Volumes/SanDisk2Tb/builds/gantry-027/ac171/`.

**Scale/Scope**: About 8 AppCore and DockerKit source files, 5 view files, 1 MCP file, about 23 new strings.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Check | Result |
|---|---|---|
| I. Native Mac App, HIG First | The notice uses the standard empty state and a banner above the list. The list editor is a standard sheet. No new macOS 27 API. | Pass |
| II. Logic in Packages, Thin Views, Tests | Diagnosis, list validation, TOML edits, stats decoding and builder image comparison are in AppCore and DockerKit with Swift Testing tests. File system checks go through an injectable layout probe. Fixtures come from a live 1.7.1 run. | Pass |
| III. No Required Dependencies, Version-Gated | The DNS keys are gated on 1.7.0 (`Features.containerDNSDefaults`). The stats value is used only when present. The diagnosis runs only after a failure. 1.6.1 behaviour is unchanged. Support is verified against live 1.7.1 output. | Pass |
| IV. Safety of User Data and Secrets | The TOML write re-parses the result and compares every other value before it saves. It refuses unsafe edits. Recreate Builder and Restart Services use the shared confirmation. | Pass |
| V. Every String in Every Language | New strings go to `App/Localizable.xcstrings` and the AppCore catalog in English. The list is in `ac171/new-strings.txt`. The merge needs the translations for all 28 languages and a green `scripts/check-localization.py`. | Pass with a condition: translations are still to do |

Post-design re-check: no change. No violation needs a justification.

## Project Structure

### Documentation (this feature)

```text
specs/001-apple-container-1-7-1/
├── spec.md
├── plan.md
└── tasks.md
```

The research for this feature is in `/Volumes/SanDisk2Tb/builds/gantry-027/ac17/REPORT.md` and `/Volumes/SanDisk2Tb/builds/gantry-027/ac171/REPORT.md`. No separate research.md, data-model.md or contracts were written.

### Source Code (repository root)

```text
Packages/AppCore/Sources/AppCore/
├── ClusterServiceDiagnosis.swift      # new: error recognition and install layout check
├── AppleContainerProperties.swift     # list value kinds, DNS keys, validation
├── ConfigTOML.swift                   # read and write string arrays in place
├── ContainerTooling.swift             # Features.containerDNSDefaults (1.7.0)
├── HostSession.swift                  # clusterServiceProblem state
├── AppleContainerBuilder.swift        # builder image comparison
├── AppleContainerKernel.swift         # recommended kernel through the CLI
└── Resources/Localizable.xcstrings
Packages/AppCore/Tests/AppCoreTests/
└── AppleContainer171Tests.swift       # new
Packages/DockerKit/Sources/DockerKit/AppleContainer/
└── AppleContainerJSON.swift           # cpuUtilization in the stats body
Packages/DockerKit/Tests/DockerKitTests/
└── AppleContainerJSONTests.swift
Packages/GantryMCP/Sources/gantry-mcp/
└── GantryTools+AppleSystem.swift      # list values for apple_set_property
App/Views/
├── Clusters/ClusterServiceProblemView.swift     # new
├── Clusters/ClusterListView.swift
├── Clusters/CreateClusterSheet.swift
├── AppleSystem/AppleSystemListEditor.swift      # new
├── AppleSystem/AppleSystemPropertiesPane.swift
├── AppleSystem/AppleBuilderPane.swift
└── Kubernetes/KubernetesBrowserView.swift       # cluster service notice
App/Localizable.xcstrings
```

**Structure Decision**: The existing layout of the app and its packages. Logic goes into AppCore and DockerKit. Views only show the state.

## Complexity Tracking

No violations.
