<!-- STE deviation: spec-kit template headings, product names, Swift and Apple API names, CLI flags and paths stay verbatim. -->
# Implementation Plan: Fleet Activity Table

**Branch**: `feat/fleet-activity` | **Date**: 2026-11-14 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/006-fleet-activity/spec.md`

## Summary <!-- slop: spec-kit template heading -->

A new sidebar item "Resource Usage" shows a SwiftUI `Table` of the running containers of all connected hosts. The table reads data that is already in memory: `HostSession.visibleContainers` and `HostSession.containerLoadHistory`, which the 5-second load sampler of each host fills. No new stats streams.

The logic is in AppCore, in the new file `FleetActivity.swift`:

- `FleetActivity.snapshot(hosts:)` makes the rows and the list of unavailable hosts from plain inputs.
- `FleetActivity.Filter` applies the text and host filters.
- `FleetActivity.Comparator` is a `SortComparator` for the `Table`. Rows without a value go last in both orders. Ties sort by host name, container name and id.
- `ContainerUptime.seconds(fromStatus:)` reads Docker's "Up 3 hours" status text.

apple/container gives only "Up" as status. `AppleContainerJSON` in DockerKit now writes "Up <duration>" from the CLI's `startedDate`, in Docker's own wording (`DockerHumanDuration`). Then one parser serves both host kinds, and the Containers list of an apple host also shows the uptime.

The app adds `SidebarItem.usage`, the view `App/Views/Usage/FleetActivityView.swift`, a palette entry and the link target `usage`. The MCP server adds the read-only tool `fleet_activity`. It takes two one-shot samples one second apart for each running container and uses the same `FleetActivity` code to make and sort the rows.

## Technical Context

**Language/Version**: Swift 6, Xcode 27 SDK

**Primary Dependencies**: SwiftUI (`Table`, `TableColumn(sortUsing:)`, `contextMenu(forSelectionType:)`), AppCore, DockerKit, MCP swift-sdk (GantryMCP)

**Storage**: None. The table selection, filter and sort are view state.

**Testing**: Swift Testing in `Packages/AppCore/Tests/AppCoreTests/FleetActivityTests.swift` and `ContainerUptimeTests.swift`, `Packages/DockerKit/Tests/DockerKitTests/DockerHumanDurationTests.swift` and the existing apple JSON tests, `Packages/GantryMCP/Tests/GantryMCPTests/FleetActivityToolTests.swift`. A live check of a Debug build with `scripts/gantry-ctl`.

**Target Platform**: macOS 26 or later

**Project Type**: Desktop app (SwiftUI) with local Swift packages and an MCP server executable

**Performance Goals**: A sort or filter change with 200 rows shows in less than 0.5 s (SC-003). The table work is O(n log n) on data in memory.

**Constraints**: Builds go to `/Volumes/SanDisk2Tb/builds/gantry/fleet-activity/` with `-jobs 3`. Small SwiftUI bodies (CI type-check time).

**Scale/Scope**: One new view and one AppCore file. Small edits in ContentView, PaletteRunner, AppLink, AppleContainerJSON and GantryMCP.

## Constitution Check

- I. HIG: a native `Table` with sortable headers, a `.searchable` field and a toolbar host `Picker`, as in Activity Monitor. `ContentUnavailableView` for empty states. Pass.
- II. Logic in packages: rows, filters, sort, uptime parse and the duration text are in AppCore and DockerKit with tests. The view only shows rows and sends navigation. Pass.
- III. No required dependencies: the table works with only apple/container. The uptime change uses `startedDate`, which apple/container 0.12 and 1.x report (`runtimeState` already reads both shapes). Without the field, the status stays "Up". Pass.
- IV. Safety: the feature is read-only. No destructive action. The MCP tool reads stats only. Pass.
- V. Strings: new strings go into `App/Localizable.xcstrings` with 28 languages. `scripts/check-localization.py` must report 0 problems. Pass.
- Accessibility: each metric cell has an accessibility label. Host state has a symbol and text, not only color. Pass.

Post-design check: no change. No violations, so Complexity Tracking is empty.

## Project Structure

### Documentation (this feature)

```text
specs/006-fleet-activity/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── app-link.md
│   └── mcp-fleet-activity.md
└── tasks.md
```

### Source Code (repository root)

```text
Packages/DockerKit/Sources/DockerKit/
├── Models/DockerHumanDuration.swift            # new: Docker's "3 hours" wording
└── AppleContainer/AppleContainerJSON.swift     # Status "Up <duration>" from startedDate
Packages/AppCore/Sources/AppCore/
├── FleetActivity.swift                         # new: rows, filter, comparator, snapshot
├── ContainerUptime.swift                       # new: parse "Up 3 hours"
└── AppLink.swift                               # global target "usage"
Packages/AppCore/Tests/AppCoreTests/
├── FleetActivityTests.swift                    # new
├── ContainerUptimeTests.swift                  # new
└── AppLinkTests.swift                          # usage target
Packages/DockerKit/Tests/DockerKitTests/
├── DockerHumanDurationTests.swift              # new
└── AppleContainerJSONTests.swift, AppleContainer1_0JSONTests.swift
App/Views/Usage/FleetActivityView.swift         # new: table, filters, host lines
App/Views/ContentView.swift                     # SidebarItem.usage, sidebar row, link
App/Views/Palette/PaletteRunner.swift           # palette entry
App/Localizable.xcstrings                       # new strings, 28 languages
Packages/GantryMCP/Sources/gantry-mcp/
├── GantryTools+Activity.swift                  # new: fleet_activity
└── GantryTools.swift                           # dispatch
Packages/GantryMCP/Tests/GantryMCPTests/FleetActivityToolTests.swift
docs/automation.md                              # gantry://open/usage
```

**Structure Decision**: The existing layout of the app and the packages. The new view gets its own folder `App/Views/Usage/`, the same as `Dashboard/`.

## Complexity Tracking

None.
