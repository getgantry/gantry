<!-- STE deviation: spec-kit template headings, product names, Swift type names, CLI flags and paths stay verbatim. -->
# Implementation Plan: Image Scan and SBOM

**Branch**: `feat/image-scan` | **Date**: 2026-11-14 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/011-image-scan/spec.md`

## Summary

Gantry finds Trivy or Grype on the Mac and runs it on one image. The logic is in a new AppCore folder `ImageScan/`:

1. `ImageScanner.swift`: the two scanners, their minimum versions, install help, the search for the binary (overrides, `PATH`, Homebrew folders) and the version parse.
2. `ImageScanPlan.swift`: how one image goes to the scanner on one host kind (OCI layout, Docker archive or registry reference) and the platform.
3. `ScanCommand.swift`: the command arguments for each scanner, source and output format. See [contracts/scanner-commands.md](./contracts/scanner-commands.md).
4. `ScanReport.swift`: one finding model, the severity groups, and the parsers `TrivyReportParser` and `GrypeReportParser`.
5. `ImageScanModel.swift`: an `@Observable` model for the sheet. It detects scanners, runs export, unpack and scan, exports SBOMs, cancels and removes the temporary folder. Side effects are behind `ScanProcessRunning`, `ScanFileSystem` and an export closure, so tests do not touch the system.
6. `HostSession+ImageScan.swift`: makes the plan for an image of the session and the export closure (`container image save --platform` for Apple hosts, `saveImages` for the local Docker host).

The app gets `App/Views/Images/ImageScanSheet.swift` and `ImageScanFindingsView.swift` (small helper views) and the action "Scan for Vulnerabilities…" in the image context menu and the image detail toolbar.

## Technical Context

**Language/Version**: Swift 6, Xcode 27 SDK

**Primary Dependencies**: SwiftUI, AppKit (`NSSavePanel`, `NSWorkspace`), AppCore, DockerKit (`ChildProcess`)

**Storage**: Temporary folder per sheet under the macOS user temporary folder. Nothing is stored after the sheet closes.

**Testing**: Swift Testing in `Packages/AppCore/Tests/AppCoreTests/ImageScanTests.swift`. Fixtures are cut from real Trivy 0.76.2 and Grype 0.121.3 JSON reports of `postgres:16-alpine` and `alpine:latest` on apple/container 1.7.1. Live check of a Debug build with `scripts/gantry-ctl`.

**Target Platform**: macOS 26 or later

**Project Type**: Desktop app (SwiftUI) with local Swift packages

**Performance Goals**: The report parse of a 500 KB Trivy report takes less than 1 s. The sheet stays responsive while the child process runs.

**Constraints**: No scanner is installed or bundled. Builds go to `/Volumes/SanDisk2Tb/builds/gantry/image-scan/`. Scanner processes are cancellable (SIGTERM through `ChildProcess`).

**Scale/Scope**: One image per scan. Reports with some hundreds of findings.

## Constitution Check

- I. HIG: a sheet with a native `List` in sections, `ContentUnavailableView` for empty and missing-tool states, toolbar-style buttons with full text, SF Symbols. Severity shows as text with a symbol, not by color only. Pass.
- II. Logic in packages: detection, plan, commands, parse and the scan state machine are in AppCore with tests. The views only show the model state. Process and file effects are behind protocols. Pass.
- III. No required dependencies, version-gated: Trivy and Grype are optional. A missing tool shows install help; the host stays healthy. Each scanner has a minimum version. `container image save --platform` is in every supported `container` version (it is older than 0.12.0, minimum supported is 1.0.0), and the export was verified on 1.7.1. Pass.
- IV. Safety: the feature deletes only its own temporary folder. Gantry passes no registry passwords to the scanners. The SBOM file is written to a temporary path and moved to the user's path only after the scanner succeeds. Pass.
- V. Strings: all new strings go into the AppCore and App catalogs with 28 languages. Counts use plural variations. Pass.

Post-design check: no change. No violation needs a justification.

## Project Structure

### Documentation (this feature)

```text
specs/011-image-scan/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/scanner-commands.md
├── checklists/requirements.md
└── tasks.md
```

### Source Code (repository root)

```text
Packages/AppCore/Sources/AppCore/ImageScan/
├── ImageScanner.swift
├── ImageScanPlan.swift
├── ScanCommand.swift
├── ScanReport.swift
├── ImageScanModel.swift
└── HostSession+ImageScan.swift
Packages/AppCore/Tests/AppCoreTests/
├── ImageScanTests.swift
└── ImageScanFixtures.swift
App/Views/Images/
├── ImageScanSheet.swift
├── ImageScanFindingsView.swift
└── ImageListView.swift        (menu and toolbar entries)
```

**Structure Decision**: The existing app and package layout. A new folder in AppCore keeps the feature together.

## Complexity Tracking

No violations.
