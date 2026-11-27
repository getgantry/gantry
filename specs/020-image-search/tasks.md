<!-- STE deviation: spec-kit template headings, task format, product names, API paths and CLI flags stay verbatim. -->
# Tasks: Search Images in Registries and Pull a Tag

**Input**: `/specs/020-image-search/`

## DockerKit

- [x] T001 [US1] `DockerClient.searchImages(term:limit:)` and `ImageSearchResult` in `Packages/DockerKit/Sources/DockerKit/Endpoints/ImageSearch.swift`, with a test from a live nettop response
- [x] T002 [US3] Optional `platform` for `DockerClient.pullImage`, and `--platform` in the Apple transport `pullStream`, with tests

## AppCore

- [x] T003 [US1] `ImageSearchHTTP` protocol and the `URLSession` implementation (ephemeral, no cookies, no cache)
- [x] T004 [US1] `DockerHubAPI` search and tags parsers with live fixtures
- [x] T005 [US2] `RegistryTagsAPI` with the bearer token flow, credentials and `Link` pages (1000 tags for each page, 10 pages at most; signature tags are hidden)
- [x] T006 [US4] `ImageSearchError` mapping: 429, `toomanyrequests`, `URLError`, Engine DNS errors, 404
- [x] T007 [US1] `ImageSearchModel` with the 300 ms debounce and cancel of old searches
- [x] T008 [US3] `HostSession.searchImages`, `HostSession.pullPlatform` and the `platform` parameter of `HostSession.pullImage`
- [x] T009 Unit tests for T003–T008 in `Packages/AppCore/Tests/AppCoreTests/ImageSearchTests.swift` and `HostSessionStreamingTests.swift`

## App

- [x] T010 [US1] `ImageSearchSheet`, the "Search Images…" toolbar button and the empty-state action in `App/Views/Images/`
- [x] T011 [US3] `ImagePullOperation.start`, used by `PullImageSheet`, `ImageSearchSheet` and the `debug/pull` link
- [x] T012 [US4] Strings in the catalogs in 28 languages; `scripts/check-localization.py` shows 0 problems
- [x] T013 Debug link `debug/imagesearch` (PNG of the sheet) in `AppLink` and `docs/automation.md`

## Checks

- [x] T014 `swift test` for DockerKit (366 tests) and AppCore (949 tests)
- [x] T015 Debug build of the app with `xcodebuild`
- [x] T016 Live: Docker Hub search and tags, ghcr.io tags with an anonymous token, Docker Hub registry tags (`LiveImageSearchTests`, `GANTRY_SRCH_LIVE=1`)
- [ ] T017 Live: Engine search and pull with `platform` on nettop (`GANTRY_SRCH_LIVE_DOCKER_SOCKET`). Open: nettop has no default route on 2026-11-21. The Engine reply in the fixture is from nettop earlier that day; the DNS error from nettop maps to "Registry Not Reachable" in a unit test.
- [x] T018 Live: `container image pull --platform linux/arm64` stores one variant, with no flag all variants (SC-002); the pull from the shared operation on Apple stores one variant and shows in `debug/activity`
- [x] T019 Live UI check through `scripts/gantry-ctl`: Docker Hub results and tags, other registry tags, no results, access denied, dark mode (Apple host only)
