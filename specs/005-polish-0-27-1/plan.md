<!-- STE deviation: spec-kit template headings, product names, Apple API names, CLI flags and paths stay verbatim. -->
# Implementation Plan: Polish Fixes for 0.27.1

**Branch**: `fix/polish-0-27-1` | **Date**: 2026-11-09 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/005-polish-0-27-1/spec.md`

## Summary <!-- slop: spec-kit template heading -->

Four small fixes, one commit each, in one pull request.

1. Explain button: `App/Views/Explain/ExplainEntryPoints.swift`. Add `.accessibilityLabel` and `.accessibilityHint` to `ExplainFailureButton` and `ExplainOperationButton`. The strings "Explain" and the help text are in the catalog already.
2. Time axis: `App/Views/Containers/StatsView.swift`, `TimeAxis`. Use fewer marks (`desiredCount: 3`), a stride that follows the sample span, and a shorter format (`hour().minute()` when the span is more than 2 minutes). Snapshot the Stats tab at 3 widths.
3. Palette and links: `App/Views/ContentView.swift`, `apply(_:)`. Add `AppLink.closesPalette` in AppCore (true for `.open` and `.settings`), test it in `AppLinkTests`, and set `showingPalette = false` in `apply(_:)` when it is true.
4. gantry-ctl: `scripts/gantry-ctl`. Take all pids from `pgrep -f`, remove `$$` and its parents, and keep the newest pid that has a socket.

## Technical Context

**Language/Version**: Swift 6, Xcode 27 SDK; bash for `gantry-ctl`

**Primary Dependencies**: SwiftUI, Swift Charts, AppCore

**Testing**: Swift Testing in `Packages/AppCore/Tests/AppCoreTests/AppLinkTests.swift`. Live checks of a Debug build with `scripts/gantry-ctl` and the accessibility tree.

**Target Platform**: macOS 26 or later

**Project Type**: Desktop app (SwiftUI) with local Swift packages

**Constraints**: Builds go to `/Volumes/SanDisk2Tb/builds/gantry/`.

## Constitution Check

- I. HIG: the axis fix keeps the system chart style. Pass.
- II. Logic in packages: the palette rule goes to AppCore with a test. Pass.
- III. No required dependencies: no change. Pass.
- IV. Safety: a link closes the palette only, and keeps a destructive confirmation. Pass.
- V. Strings: the fixes use strings that exist. New strings get all translations. Pass.
- Accessibility rule: fix 1 makes the project follow it. Pass.

## Project Structure

```text
App/Views/Explain/ExplainEntryPoints.swift
App/Views/Containers/StatsView.swift
App/Views/ContentView.swift
Packages/AppCore/Sources/AppCore/AppLink.swift
Packages/AppCore/Tests/AppCoreTests/AppLinkTests.swift
scripts/gantry-ctl
```
