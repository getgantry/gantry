<!-- STE deviation: spec-kit template headings, task format, product names, Swift names and paths stay verbatim. -->
# Tasks: Image Updates for Containers

**Input**: `/specs/017-image-updates/`

## Phase 1: Foundational (DockerKit)

- [x] T001 [P] Add `ImageReference` (parse, canonical, repository, registry host) in Packages/DockerKit/Sources/DockerKit/Models/ImageReference.swift with tests in Packages/DockerKit/Tests/DockerKitTests/ImageReferenceTests.swift
- [x] T002 [P] Add `DockerClient.distributionDigest(reference:auth:)` (`GET /distribution/{name}/json`, `X-Registry-Auth`) in Packages/DockerKit/Sources/DockerKit/Endpoints/Distribution.swift with a mock-transport test
- [x] T003 Add `RegistryManifestClient` (HEAD manifest, bearer challenge parser, anonymous and basic token, 429 as rate limit) in Packages/DockerKit/Sources/DockerKit/Registry/RegistryManifestClient.swift with tests on a fake `RegistryHTTP`

## Phase 2: User Story 1 and 3 - Check and mark (P1, P2)

- [x] T004 Add `ImageUpdatePlan.target(for:images:isApple:)`, `status(...)` in Packages/AppCore/Sources/AppCore/ImageUpdates/ImageUpdatePlan.swift
- [x] T005 Add `ImageUpdateCache` (6 h success, 1 h failure, file load and save) in Packages/AppCore/Sources/AppCore/ImageUpdates/ImageUpdateCache.swift
- [x] T006 Add `ImageUpdateMonitor` and `HostSession.checkImageUpdates(force:)`, `imageUpdateStatus(for:)` and the periodic loop in Packages/AppCore/Sources/AppCore/ImageUpdates/
- [x] T007 AppCore tests for the plan, the cache and the monitor (fresh entries send no request, failures give no mark) in Packages/AppCore/Tests/AppCoreTests/ImageUpdateTests.swift
- [x] T008 Badge in the container row and the detail, filter "Update Available", "Check for Image Updates" in the More menu in App/Views/Containers/

## Phase 3: User Story 2 - Update the container (P1)

- [x] T009 Add `HostSession.recreate(_:request:)` as the shared step; use it in the volume switch in Packages/AppCore/Sources/AppCore/Storage/HostSession+Storage.swift
- [x] T010 Add `HostSession.updateContainer(_:)` (pull with progress as a long operation, then recreate with user env and command, network mode) and `ImageUpdatePlan.userEnvironment` and `userCommand` with tests
- [x] T011 Add `DestructiveAction.Kind.updateContainer` and its texts; add the context menu item, the item in the More menu of the detail, the confirmation and the Compose alert in the app

## Phase 4: User Story 4 - MCP (P3)

- [x] T012 Add `updateAvailable` to `ContainerDTO` from the cache file in Packages/GantryMCP/Sources/gantry-mcp/ with a test

## Phase 5: Polish

- [x] T013 Add all new strings with 28 languages and run `python3 scripts/check-localization.py` (0 problems)
- [x] T014 Run the DockerKit, AppCore and GantryMCP tests and build the app with `xcodebuild -jobs 3`
- [x] T015 Live check on Apple `container` 1.7.1 with `LiveImageUpdateTests` (`GANTRY_UPD_LIVE_APPLE=1`): mark, pull, recreate, mark gone; `upd-web` and `alpine:3.21` removed
- [ ] T015b Live check on Docker (`nettop.local`, `GANTRY_UPD_LIVE_DOCKER_SOCKET`). Open: the host had no default route and no DNS during the work. Only the `/distribution` answer shape was checked live, before the outage
- [x] T016 Live check of the GUI with `scripts/gantry-ctl` snapshots in light and dark: icon in the list row, badge in the detail (Debug build with `GANTRY_HOSTS_PATH` and `GANTRY_IMAGE_UPDATES_PATH` in the build folder)
- [ ] T016b The filter "Update Available", the confirmation and the Compose alert in the GUI. Open: no link reaches them, and clicks were not permitted
- [x] T017 Open the pull request "feat: show when a newer image is available" (#84)
