<!-- STE deviation: spec-kit template headings, product names, Apple API names and paths stay verbatim. -->
# Implementation Plan: Apple HIG and Liquid Glass Design Pass

**Branch**: `feat/hig-design-pass` | **Date**: 2026-11-07 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/003-hig-design-pass/spec.md`

**Note**: The implementation started before this plan. The audit and the change list per screen are in `/Volumes/SanDisk2Tb/builds/gantry-027/hig/SPEC.md`. That file is the research for this plan.

## Summary <!-- slop: spec-kit template heading -->

First, add shared design components. These are spacing constants, a card container, a metric chart card with Swift Charts, a sparkline, a status badge and a copyable value. Add a load history in AppCore with tests. Then change each area in small commits: Dashboard, Overview, lists, detail panes, Clusters, Kubernetes and System.

Detail actions move to icon-only toolbar items and a More menu. The command palette gets the Kubernetes items. Liquid Glass stays on the toolbar and system controls. The behaviour of all actions stays the same.

## Technical Context

**Language/Version**: Swift 6, Xcode 27 SDK

**Primary Dependencies**: SwiftUI, Swift Charts, AppCore

**Storage**: None. The history is in memory only.

**Testing**: Swift Testing in `Packages/AppCore/Tests/AppCoreTests` for the history math and the palette catalog. UI checks with `scripts/gantry-ctl` snapshots of the running Debug build.

**Target Platform**: macOS 26 or later. macOS 27 APIs only behind `#available(macOS 27, *)`.

**Project Type**: Desktop app (SwiftUI) with local Swift packages

**Performance Goals**: Charts update with each load sample and keep the UI smooth. History is bounded (10 minutes per series).

**Constraints**: Small SwiftUI `body` expressions, because the CI type check times out. No `glassEffect` on content. Builds go to `/Volumes/SanDisk2Tb/builds/gantry-027/hig/`.

**Scale/Scope**: All 10 sections. About 2 new shared view files, 1 new AppCore file and changes to about 15 view files.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Check | Result |
|---|---|---|
| I. Native Mac App, HIG First | This feature applies the principle. Glass only for floating controls. No cut toolbar text. Light, dark, Reduce Transparency and Increase Contrast are checked. | Pass |
| II. Logic in Packages, Thin Views, Tests | History buffers, rate math, summaries and palette items are in AppCore with tests. Views get split into subviews to keep `body` small. | Pass |
| III. No Required Dependencies | No new dependency. Docker-only cards stay hidden on hosts of the container tool through the host capabilities. | Pass |
| IV. Safety of User Data and Secrets | Actions keep `DestructiveAction`. No behaviour change. | Pass |
| V. Every String in Every Language | New strings in English in the catalogs, list in `hig/new-strings.txt`. Counts use plural variations. The merge needs translations for all 28 languages and a green `scripts/check-localization.py`. | Pass with a condition: translations are still to do |
| Engineering constraint: UI checks with `scripts/gantry-ctl`, not clicks | The brief tells the agent to navigate with System Events for screenshots. The constitution and `COMMON.md` say to use `scripts/gantry-ctl`. This plan uses `scripts/gantry-ctl`. | Pass after the change of method |

Post-design re-check: no change.

## Project Structure

### Documentation (this feature)

```text
specs/003-hig-design-pass/
├── spec.md
├── plan.md
└── tasks.md
```

Research: `/Volumes/SanDisk2Tb/builds/gantry-027/hig/SPEC.md`. Screenshots: `/Volumes/SanDisk2Tb/builds/gantry-027/hig/*.png` (before) and `hig/after/` (after).

### Source Code (repository root)

```text
Packages/AppCore/Sources/AppCore/
├── LoadHistory.swift                 # new: counters, rates, per-container history, summary
├── HostSession.swift                 # record per-container points and host rates in LoadSample
└── Palette/PaletteCatalog.swift      # Kubernetes section and context items
Packages/AppCore/Tests/AppCoreTests/
├── LoadHistoryTests.swift            # new
└── CommandPaletteTests.swift
App/Views/Shared/
├── DesignSystem.swift                # new: Spacing, DashboardCard, StatusBadge, CopyableValue
├── MetricChart.swift                 # new: MetricChartCard, Sparkline
├── DetailComponents.swift            # FactGrid with monospaced and copyable values
└── ListEmptyState.swift              # secondary actions
App/Views/Dashboard/FleetDashboardView.swift
App/Views/HostOverviewView.swift
App/Views/Containers/ContainerListView.swift
App/Views/Images/ImageListView.swift
App/Views/Volumes/VolumeListView.swift
App/Views/Networks/NetworkListView.swift
App/Views/Machines/MachineListView.swift
App/Views/AppleSystem/AppleSystemOverviewPane.swift
App/Views/Kubernetes/KubeResourceDetailView.swift
App/Views/Clusters/ClusterListView.swift
App/Views/Palette/CommandPaletteView.swift
App/Localizable.xcstrings
```

**Structure Decision**: Shared components go into `App/Views/Shared`. Logic goes into AppCore. Each area changes in its own commit.

## Complexity Tracking

No violations.
