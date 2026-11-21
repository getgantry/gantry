<!-- STE deviation: spec-kit template headings, task format, product names, API paths and CLI flags stay verbatim. -->
# Feature Specification: Search Images in Registries and Pull a Tag

**Feature Branch**: `feat/image-search`
**Created**: 2026-11-21
**Status**: Implemented

## User Scenarios and Testing

### User Story 1 - Search Docker Hub (Priority: P1)

A user opens "Search Images…" in the image list and types "nginx". Gantry shows the
repositories that match. Each row shows the name, the description, the stars and an
"Official" mark for official images.

**Why this priority**: Users must know the exact name of an image before they can pull it.
Today they find it in a web browser.

**Independent Test**: Type "nginx" on a Docker host and on an Apple host. The list shows
`nginx` with the "Official" mark first.

**Acceptance Scenarios**:

1. **Given** a Docker host, **When** the user types a query, **Then** Gantry sends
   `GET /images/search?term=…` to the Docker Engine.
2. **Given** an Apple `container` host, **When** the user types a query, **Then** Gantry
   sends `GET https://hub.docker.com/v2/search/repositories/?query=…`. The `container` CLI
   has no search command (checked on 1.7.1).
3. **Given** the user types fast, **When** the user stops for 300 ms, **Then** Gantry sends
   one search for the last text only.

### User Story 2 - See the tags of a result (Priority: P1)

The user selects a result. Gantry shows its tags. For Docker Hub, each tag shows the date of
the last push and the size for the host platform. For another registry, each tag shows its name.

**Independent Test**: Select `nginx`. The tags show a date and a size. Enter
`ghcr.io/home-assistant/home-assistant`. The tags show.

**Acceptance Scenarios**:

1. **Given** a Docker Hub repository, **When** the user selects it, **Then** Gantry sends
   `GET https://hub.docker.com/v2/repositories/<namespace>/<name>/tags/`.
2. **Given** another registry, **When** the user enters `<registry>/<name>`, **Then** Gantry
   sends `GET https://<registry>/v2/<name>/tags/list`. On `401` it gets a bearer token from
   the realm in `WWW-Authenticate`. It sends the credentials that Gantry resolves from
   `~/.docker/config.json`, when there are some.
3. **Given** a Docker Hub tag that has no image for the host platform, **When** the tag
   shows, **Then** Gantry tells the user, and the Pull button is not available.

### User Story 3 - Pull a tag (Priority: P1)

The user selects a tag and chooses Pull. Gantry starts the existing pull. The progress shows
in Activity and in the menu bar.

**Acceptance Scenarios**:

1. **Given** a Docker host, **When** the user pulls a tag, **Then** `POST /images/create`
   has `platform=<os>/<arch>` of the host.
2. **Given** an Apple host, **When** the user pulls a tag, **Then** Gantry runs
   `container image pull --platform linux/<arch> <reference>`.

### User Story 4 - Clear errors (Priority: P2)

**Acceptance Scenarios**:

1. **Given** no results, **Then** Gantry shows "No Results" with the query.
2. **Given** HTTP 429 or a `toomanyrequests` error, **Then** Gantry shows that the registry
   limits the requests, and the time to try again when the registry gives it.
3. **Given** no network, **Then** Gantry shows that the registry is not reachable.

### Edge Cases

- An empty query clears the results and sends no request.
- A new query cancels the search that is in progress.
- A repository that does not exist shows "No Tags" (HTTP 404).

## Requirements

- **FR-001**: Gantry MUST search Docker Hub through the Engine API on Docker hosts and through
  the Docker Hub HTTP API on Apple hosts.
- **FR-002**: Gantry MUST show name, description, stars and the official mark for each result.
- **FR-003**: Gantry MUST list the tags: Docker Hub API for Docker Hub, the registry API v2
  with token authentication for other registries.
- **FR-004**: Gantry MUST reuse `RegistryCredentialStore` for the credentials of a registry.
- **FR-005**: The pull MUST use `HostSession.pullImage` with the host platform, and an
  operation in the `OperationCenter`.
- **FR-006**: Gantry MUST wait 300 ms after the last change of the query before it searches.
- **FR-007**: Gantry MUST show different messages for no results, rate limits and no network.
- **FR-008**: Gantry MUST send the query and the repository name only to the registry that
  the user selected (Docker Hub, or the registry host in the repository name). It MUST NOT
  send them to other services.

## Success Criteria

- **SC-001**: On nettop (Docker 1.55) and on this Mac (Apple `container` 1.7.1), a search for
  "nginx" shows `nginx` with the official mark.
- **SC-002**: A pull of a tag from the search on an Apple host pulls one platform only.
