<!-- STE deviation: spec-kit template headings, product names, Swift names and paths stay verbatim. -->
# Implementation Plan: Container Changes and Commit Options

**Branch**: `feat/container-diff` | **Date**: 2026-11-21 | **Spec**: [spec.md](spec.md)

## Summary

DockerKit gets `ContainerChange` and `DockerClient.containerChanges(id:)`, and `commitContainer` gets `author` and `pause`. AppCore gets `ContainerChanges` (counts, filter, tree, row limit; pure and `Sendable`) and `HostSession.containerChanges(containerID:)`. `HostCapabilities` gets `containerChanges` and `commitOptions`. The app gets a "Changes" tab, more fields in `CommitImageSheet`, and a badge in `FilesView`.

## Research

- Docker API: `GET /containers/{id}/changes` returns `[{"Path": "/etc", "Kind": 0}]`. `Kind`: 0 modified, 1 added, 2 deleted. Docker returns `null` when nothing changed. `POST /commit` takes `author`, `comment`, `pause` (default `true`).
- Apple `container` 1.7.1: `container commit <id> <reference>`, no options. No diff command. The transport already ignores `comment`. So Gantry hides the message, author and pause fields and the Changes tab on Apple hosts.

## Performance

- The diff is decoded in DockerKit (off the main actor; `DockerClient` is an actor).
- `ContainerChanges.filtered` and `ContainerChanges.tree` are `nonisolated` pure functions. The view calls them in `Task.detached` and keeps only the result.
- The flat list draws at most `rowLimit` (2,000) rows. In the tree, each directory shows at most `rowLimit` children. A row tells how many rows are hidden.

## Constitution Check

- I (HIG): a segmented tab, a toolbar-style filter bar, SF Symbols plus a text for each kind (status is not color only).
- II (logic in packages): counts, filter, tree and the limit are in AppCore with Swift Testing tests. DockerKit tests decode a fixture from a real Docker 28 run on nettop.
- III (no required tools, gated support): Apple hosts hide the tab and the commit options through `HostCapabilities`.
- IV (data safety): commit makes a new image; it removes nothing.
- V (strings): new strings in `App/Localizable.xcstrings` with 28 languages, plural variations for counts.

## Files

- `Packages/DockerKit/Sources/DockerKit/Models/ContainerChange.swift`
- `Packages/DockerKit/Sources/DockerKit/Endpoints/ContainersExtended.swift`
- `Packages/DockerKit/Sources/DockerKit/AppleContainer/AppleContainerTransport.swift`
- `Packages/DockerKit/Tests/DockerKitTests/EndpointCoverageTests.swift` and `AppleContainerTransportTests.swift`
- `Packages/AppCore/Sources/AppCore/ContainerChanges.swift`
- `Packages/AppCore/Sources/AppCore/DockerHost.swift`
- `Packages/AppCore/Sources/AppCore/HostSession.swift`
- `Packages/AppCore/Tests/AppCoreTests/ContainerChangesTests.swift`
- `App/Views/Containers/ContainerChangesView.swift`
- `App/Views/Containers/ContainerDetailView.swift`
- `App/Views/Containers/CommitImageSheet.swift`
- `App/Views/Containers/FilesView.swift`
- `App/Localizable.xcstrings`
- `Packages/AppCore/Sources/AppCore/AppLink.swift`, `App/AppLinks/AppLinkHandler.swift`, `docs/automation.md`: Debug link `debug/tab?name=` for the live check
