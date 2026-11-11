<!-- STE deviation: spec-kit template headings, product names, Apple API names, CLI flags and paths stay verbatim. -->
# Implementation Plan: Polish Fixes for 0.27.1

**Branch**: `fix/polish-0-27-1` | **Date**: 2026-11-09 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/005-polish-0-27-1/spec.md`

## Summary <!-- slop: spec-kit template heading -->

Four small fixes and one fix found during the live checks, one commit each, in one pull request.

1. Explain button: `App/Views/Explain/ExplainEntryPoints.swift`. Add `.accessibilityLabel` and `.accessibilityHint` to `ExplainFailureButton` and `ExplainOperationButton`. The strings "Explain" and the help text are in the catalog already.
2. Time axis: the step rule goes to AppCore as `StatsTimeAxis` (`Packages/AppCore/Sources/AppCore/StatsTimeAxis.swift`, tests in `StatsTimeAxisTests.swift`). It takes the sample span and gives the smallest clock step (5 s, 10 s, 15 s, 30 s, 1 min, 2 min, 5 min ... 1 h) with at most 3 intervals, so at most 4 labels. `TimeAxis` in `App/Views/Containers/StatsView.swift` uses `AxisMarks(values: .stride(...))` with that step, and the format `hour().minute()` when the step is 1 minute or more (spans over 90 s; the window holds 180 samples). Snapshot the Stats tab at 3 widths.
3. Palette and links: `App/Views/ContentView.swift`, `apply(_:)`. Add `AppLink.closesPalette` in AppCore (true for `.open` and `.settings`), test it in `AppLinkTests`, and set `showingPalette = false` in `apply(_:)` when it is true.
4. gantry-ctl: `scripts/gantry-ctl`. Take all pids from `pgrep -f`, remove `$$` and its parents, and keep the newest pid that has a socket. Note: macOS `pgrep` already skips its own ancestors (`-a` adds them), so the real defect is another process with the pattern (a parallel shell, a `tail`) that is newer than the app. The socket check fixes that case.
5. Window reader (found in the live check of fix 3): `App/AppLinks/AppLinkHandler.swift`, `WindowReader`. `splitView` in ContentView is an `if`/`else` of two `NavigationSplitView`s, so a link from Dashboard to Containers makes the `.background(WindowReader)` again. The old reader reported `view.window` from `makeNSView` while it was still nil, so `hostWindow` became nil and `gantry-ctl state` did not answer after the first navigation. The new reader reports from `viewDidMoveToWindow` and never reports nil.

## Technical Context

**Language/Version**: Swift 6, Xcode 27 SDK; bash for `gantry-ctl`

**Primary Dependencies**: SwiftUI, Swift Charts, AppCore

**Testing**: Swift Testing in `Packages/AppCore/Tests/AppCoreTests/AppLinkTests.swift` and `StatsTimeAxisTests.swift`. Live checks of a Debug build with `scripts/gantry-ctl` and the accessibility tree.

**Target Platform**: macOS 26 or later

**Project Type**: Desktop app (SwiftUI) with local Swift packages

**Constraints**: Builds go to `/Volumes/SanDisk2Tb/builds/gantry/polish-0-27-1/`.

## Constitution Check

- I. HIG: the axis fix keeps the system chart style. Pass.
- II. Logic in packages: the palette rule and the axis step rule go to AppCore with tests. Pass.
- III. No required dependencies: no change. Pass.
- IV. Safety: a link closes the palette only, and keeps a destructive confirmation. Pass.
- V. Strings: the fixes use strings that exist. New strings get all translations. Pass.
- Accessibility rule: fix 1 makes the project follow it. Pass.

## Project Structure

```text
App/Views/Explain/ExplainEntryPoints.swift
App/Views/Containers/StatsView.swift
App/Views/ContentView.swift
App/AppLinks/AppLinkHandler.swift
Packages/AppCore/Sources/AppCore/AppLink.swift
Packages/AppCore/Sources/AppCore/StatsTimeAxis.swift
Packages/AppCore/Tests/AppCoreTests/AppLinkTests.swift
Packages/AppCore/Tests/AppCoreTests/StatsTimeAxisTests.swift
scripts/gantry-ctl
```
