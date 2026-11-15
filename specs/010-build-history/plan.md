<!-- STE deviation: spec-kit template headings, product names, type names, CLI flags and paths stay verbatim. -->
# Implementation Plan: Build History

**Branch**: `feat/build-history` | **Date**: 2026-11-14 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/010-build-history/spec.md`

## Summary <!-- slop: spec-kit template heading -->

Add a Builds section to each host. It shows two kinds of records:

1. Gantry records. `HostSession` records each build that Gantry starts. The hooks are in `buildImageStream` and `buildImage`, so they cover the Build Image sheet and Compose. `BuildHistoryStore` in AppCore keeps the records in `~/Library/Application Support/Gantry/build-history.json` (mode 0600), at most 100 per host, at most 512 KB of log per record (the end of the log). The steps come from the log with the parsers in DockerKit.
2. BuildKit records (Docker hosts only). `BuildxHistory` in AppCore runs `docker buildx version`, `docker buildx history ls --format json --no-trunc`, and, for the selected record, `history inspect --format json REF` and `history logs REF`. A local host uses the local `docker` CLI with `DOCKER_HOST=unix://<socket>`. An SSH host runs the commands on the remote machine over a new SSH exec channel (`SSHClient.executeCommand`). The gate is buildx 0.23.0 or later.

The parsers are in DockerKit (`BuildProgressParser`, `BuildxHistoryParser`), with fixtures from container 1.7.1, Docker 28.5.2 and buildx 0.29.1.

## Technical Context

**Language/Version**: Swift 6, Xcode 27 SDK

**Primary Dependencies**: SwiftUI, AppCore, DockerKit, SSHKit (Citadel exec channel)

**Storage**: one JSON file in Application Support, owner-only permissions

**Testing**: Swift Testing. DockerKit: parser tests with fixtures in `Packages/DockerKit/Tests/DockerKitTests/BuildHistoryFixtures.swift`. AppCore: store, recorder and buildx service tests with an in-memory store and a fake command runner. Live check of a Debug build on the Apple host with `scripts/gantry-ctl`.

**Target Platform**: macOS 26 or later

**Project Type**: Desktop app (SwiftUI) with local Swift packages

**Constraints**: No required `docker` CLI. Builds go to `/Volumes/SanDisk2Tb/builds/gantry/build-history/`. SwiftUI bodies stay small for the CI type checker.

**Scale/Scope**: about 10 new source files, one new sidebar section, about 40 new strings.

## Constitution Check

- I. HIG: the section uses a list and a detail pane in a split view, and SF Symbols. The empty state is a `ContentUnavailableView`. Status has an icon and text. Pass.
- II. Logic in packages: parsers in DockerKit, store and buildx service in AppCore, with tests. Side effects (files, processes, SSH) are behind `BuildHistoryPersistence` and `BuildxCommandRunner`. The views only show state. Pass.
- III. No required dependencies, version gate: the `docker` CLI and buildx are optional. The gate is the buildx version. A missing tool gives a note, not an error state. Apple hosts do not need anything new. Pass.
- IV. Data and secrets: build argument values are not stored (a test checks the file). Logs stay on the Mac with mode 0600. Clear History uses `DestructiveAction` (Touch ID when on). Gantry does not change buildx records. Pass.
- V. Strings: all new strings go to the catalogs with 28 languages. Counts use plural variations. Pass.
- Accessibility: status icons have text. Icon-only buttons have labels. Pass.

Post-design check: no change. Pass.

## Project Structure

### Documentation (this feature)

```text
specs/010-build-history/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/buildx-cli.md
└── tasks.md
```

### Source Code (repository root)

```text
Packages/DockerKit/Sources/DockerKit/Models/
├── BuildProgress.swift          # BuildStep, BuildStepState, BuildProgressParser (BuildKit plain + classic)
└── BuildxHistory.swift          # BuildxRecord, BuildxInspect, BuildxHistoryParser, buildx version
Packages/DockerKit/Tests/DockerKitTests/
├── BuildProgressTests.swift
├── BuildxHistoryTests.swift
└── BuildHistoryFixtures.swift   # real output as strings
Packages/AppCore/Sources/AppCore/Builds/
├── BuildRecord.swift            # BuildRecord, BuildStatus, BuildSource, log cap
├── BuildHistoryStore.swift      # @Observable store + persistence protocol
├── BuildxHistory.swift          # availability, list, detail; command runners
└── HostSession+Builds.swift     # recording hooks, runner per host kind
Packages/AppCore/Tests/AppCoreTests/
├── BuildHistoryStoreTests.swift
└── BuildxHistoryServiceTests.swift
App/Views/Builds/
├── BuildHistoryView.swift       # split view, toolbar, loading
├── BuildRowView.swift
└── BuildDetailView.swift        # summary, steps, log
```

Changes in existing files: `AppleContainerTransport` (a relative Dockerfile path becomes absolute against the context; see research R2), `HostSection` (new `.builds`), `AppLink` section names, `AppModel` (store, host removal), `HostSession.buildImage`/`buildImageStream` (recording), `DestructiveAction` (`.clearBuildHistory`) and `DestructiveActionText`, the String Catalogs.

**Structure Decision**: The Builds section is full width, with its own `HSplitView` (list and detail). This keeps the change out of the shared detail selection of `ContentView`.

## Complexity Tracking

No violations.
