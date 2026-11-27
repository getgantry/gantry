<!-- STE deviation: spec-kit template headings, task format, product names, API paths and CLI flags stay verbatim. -->
# Implementation Plan: Search Images in Registries and Pull a Tag

**Branch**: `feat/image-search` | **Date**: 2026-11-21 | **Spec**: [spec.md](spec.md)

## Summary

DockerKit gets `DockerClient.searchImages(term:limit:)` (`GET /images/search`) and an
optional `platform` for `pullImage`. The Apple transport adds `--platform` to
`container image pull` when the request has one.

AppCore gets the folder `ImageSearch/`:

- `ImageSearchHTTP`: a protocol for HTTP GET, with a `URLSession` implementation. Tests use a fake.
- `DockerHubAPI`: search and tags of the Docker Hub HTTP API, and their parsers.
- `RegistryTagsAPI`: `GET /v2/<name>/tags/list` with the bearer token flow and the `Link`
  header for more pages.
- `ImageSearchError`: no results, rate limit, offline, other. It maps HTTP status, `URLError`
  and Engine errors.
- `ImageSearchModel` (`@Observable`, `@MainActor`): the query, a 300 ms debounce, the
  results, the tags and the state. The sleep is injected, so the tests do not wait.
- `HostSession.searchImages` and `HostSession.pullPlatform`.

The app gets `ImageSearchSheet` (opened from the image list toolbar and the empty state).
The pull goes through a shared `ImagePullOperation.start`, which `PullImageSheet` also uses.

## Constitution Check

- Principle I: a sheet with a segmented source picker, a search field, two lists and
  `ContentUnavailableView` for the empty and error states.
- Principle II: parsers, the token flow, the error mapping and the debounce are in AppCore
  and DockerKit with Swift Testing tests. Fixtures are copied from live responses
  (2026-11-21). Network is behind `ImageSearchHTTP`.
- Principle III: no new tool. Apple hosts use HTTP because the CLI has no search.
  `--platform` is in `container image pull` since 1.0.
- Principle IV: credentials stay in memory. They go only to the realm of the registry that
  asked for them.
- Principle V: all new strings are in the catalogs in 28 languages.

## Privacy

The query goes to Docker Hub only (through the Engine or directly). A repository name of
another registry goes only to that registry host and to the token realm that the host names.
