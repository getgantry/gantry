<!-- STE deviation: spec-kit template headings, product names, Swift names, Docker API keys, CLI flags and paths stay verbatim. -->
# Implementation Plan: Edit the Resources of a Container

**Branch**: `feat/live-limits` | **Date**: 2026-11-21 | **Spec**: [spec.md](spec.md)

## Summary

DockerKit gets `ContainerResourceUpdate` (the body of `POST /containers/{id}/update`) and `DockerClient.updateContainer(id:update:)`. `ContainerDetails.HostConfig` decodes `MemoryReservation` and `MemorySwap` too.

AppCore gets `ContainerResources`. It has the values from inspect, the parse and format of memory sizes, the form with validation and the diff that makes the update body. `HostSession.updateResources` sends the update on Docker hosts. On Apple hosts it uses `HostSession.recreate(_:adjust:)`, a general form of the recreate of spec 004. `recreationRequest` now keeps `Memory` and `NanoCpus`. After a change, the session refreshes the inspect cache and the container list, and increments `resourceRevision`. The Overview and the Stats tab use this value in their `.task(id:)`.

The app gets `EditResourcesSheet`. It shows the fields that the host supports, the errors of the fields and the daemon error. On Apple hosts it asks for confirmation before the recreate.

## Research

- apple/container 1.7.1: `container --help` lists no `update` command. `Sources/ContainerCommands/Container/` has no update file. `ContainerConfiguration.Resources` validates `cpus` in 1...processorCount (an integer) and `memoryInBytes >= 200 MiB`. The CLI has no restart policy. The Apple transport already rejects a restart policy other than `no`.
- Docker 29.6.2 on `nettop.local`: `Memory: 0` and `NanoCpus: 0` in an update do not remove a limit (the daemon ignores zero). `MemorySwap: -1` removes the swap limit. The daemon errors are: "Minimum memoryswap limit should be larger than memory limit", "Minimum memory limit allowed is 6MB", "range of CPUs is from 0.01 to 8.00", and "Memory limit should be smaller than already set memoryswap limit". Gantry shows them as they are. When `MemorySwap` is -1, an update of `Memory` alone fails with "Memory limit should be smaller than already set memoryswap limit", and `Memory` with `MemorySwap: -1` can fail in runc. The sheet shows these errors too.

## Constitution Check

- Principle I (HIG): a sheet with a grouped form; a confirmation dialog for the recreate.
- Principle II (logic in packages): parse, validation and diff are pure functions in AppCore with Swift Testing tests. The update body encoding has a DockerKit test.
- Principle III (version-gated): Apple hosts get the recreate path on all supported CLI versions; `--cpus` and `--memory` are in `create` since 1.0.
- Principle IV (safety): the recreate removes the container, so it asks first. The recreate keeps the limits and the other settings.
- Principle V (strings): all new strings in the App and AppCore catalogs, 28 languages.

## Files

- `Packages/DockerKit/Sources/DockerKit/Models/ContainerDetails.swift`
- `Packages/DockerKit/Sources/DockerKit/Models/ContainerResourceUpdate.swift` (new)
- `Packages/DockerKit/Sources/DockerKit/Endpoints/ContainersExtended.swift`
- `Packages/DockerKit/Tests/DockerKitTests/EndpointCoverageTests.swift`
- `Packages/AppCore/Sources/AppCore/ContainerResources.swift`, `ContainerResourceForm.swift` (new)
- `Packages/AppCore/Sources/AppCore/DestructiveAction.swift`, `App/Views/Shared/DestructiveActionText.swift` (the `recreateContainer` confirmation)
- `Packages/AppCore/Sources/AppCore/HostSession+Resources.swift` (new)
- `Packages/AppCore/Sources/AppCore/ContainerRecreate.swift`
- `Packages/AppCore/Sources/AppCore/Storage/HostSession+Storage.swift`
- `Packages/AppCore/Tests/AppCoreTests/ContainerResourcesTests.swift`, `LiveResourcesTests.swift` (new)
- `App/Views/Containers/EditResourcesSheet.swift` (new)
- `App/Views/Containers/ContainerListView.swift`, `ContainerDetailView.swift`, `StatsView.swift`, `LiveTaskKey.swift`
- `App/Localizable.xcstrings`, `Packages/AppCore/Sources/AppCore/Resources/Localizable.xcstrings`
