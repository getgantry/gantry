<!-- STE deviation: spec-kit template headings, Given/When/Then scenarios, product names, API paths, CLI flags and paths stay verbatim. -->
# Feature Specification: Image Updates for Containers

**Feature Branch**: `feat/image-updates`
**Created**: 2026-11-21
**Status**: Implemented (live checks of the GUI are open, see tasks.md)

## User Scenarios and Testing

### User Story 1 - See that a newer image is available (Priority: P1)

A container runs `nginx:alpine`. The registry has a newer image for the tag `alpine`. The container list and the container detail show the mark "Update Available".

**Why this priority**: Users run old images and do not know it. This is the base of the feature.

**Independent Test**: Run a container from an old tag on a Docker host and on an Apple host. Select "Check for Image Updates". The row shows the mark.

**Acceptance Scenarios**:

1. **Given** a container whose local image digest is not the registry digest of the same tag, **When** the check is done, **Then** the row and the detail show "Update Available".
2. **Given** a container whose local digest is the registry digest, **When** the check is done, **Then** no mark shows.
3. **Given** a container from a digest-pinned reference (`nginx@sha256:…`), an image id, or a local build (Docker: no RepoDigests for the repository), **Then** Gantry does not check it and shows no mark.
4. **Given** no network, a rate limit or a registry error, **When** the check fails, **Then** no mark shows and no error alert opens.
5. **Given** the filter menu of the container list, **When** the user selects "Update Available", **Then** the list shows only the containers with the mark.

### User Story 2 - Update the container (Priority: P1)

The user selects "Update Container…" on a container with the mark. Gantry asks for a confirmation, because the container restarts. Gantry pulls the image (with progress in the activity list and the menu bar), then makes the container again with the same settings.

**Acceptance Scenarios**:

1. **Given** a standalone container with the mark, **When** the user confirms the update, **Then** Gantry pulls the reference, removes the container, and creates it again with the same name, command, environment set by the user, ports, binds, restart policy, labels and (Docker) network mode. A running container starts again. A stopped container stays stopped.
2. **Given** the pull fails or the user cancels during the pull, **Then** the old container does not change.
3. **Given** a container of a Compose project, **When** the user selects the action, **Then** Gantry tells the user to update the project and offers "Pull Images" (the existing Compose pull). Gantry does not make one service of the project again by itself.

### User Story 3 - Check rate and cache (Priority: P2)

Gantry checks each image reference at most every 6 hours. The menu command "Check for Image Updates" checks now. The results stay in a cache file, so the marks show again after a restart of the app.

**Acceptance Scenarios**:

1. **Given** a result younger than 6 hours, **When** the periodic check runs, **Then** Gantry does not send a request for that reference.
2. **Given** a failed check, **Then** Gantry tries that reference again after 1 hour, not on each refresh.
3. **Given** the user selects "Check for Image Updates", **Then** Gantry checks all references of the host now.

### User Story 4 - MCP field (Priority: P3)

The `list_containers` MCP tool gives `updateAvailable` (true, false, or absent when unknown) for each container. The MCP server reads the cache file of the app. It does not send registry requests.

## Requirements

- **FR-001**: Docker hosts MUST get the registry digest from `GET /distribution/{name}/json` of the Engine API, with the `X-Registry-Auth` that Gantry resolves from `~/.docker/config.json`.
- **FR-002**: Apple `container` 1.7.1 has no CLI command that reads a remote digest (`container image` has only local commands, `container registry` has only login commands). Apple hosts MUST use the registry HTTP API: `HEAD /v2/<repo>/manifests/<tag>` with the index and manifest media types, the bearer token flow from `WWW-Authenticate` (anonymous, or with the credentials of `~/.docker/config.json`), and the `Docker-Content-Digest` header.
- **FR-003**: Docker local digest MUST come from the RepoDigests of the image that the container runs (`ImageID`), for the same repository. Apple local digest MUST come from the descriptor digest of the container image (`ImageID` of the summary). Apple images have no RepoDigests.
- **FR-004**: Gantry MUST skip image ids, digest-pinned references and images with no RepoDigests for the repository. A reference with no tag means `latest`, as in Docker.
- **FR-005**: Results MUST be cached per canonical reference (`docker.io/library/nginx:alpine`) in `~/Library/Application Support/Gantry/image-updates.json`. A success is fresh for 6 hours, a failure for 1 hour.
- **FR-006**: A failed check MUST NOT show a mark, an alert or a banner.
- **FR-007**: "Update Container" MUST use the shared confirmation (`DestructiveAction`) and MUST pull before it removes the old container.
- **FR-008**: The recreate MUST reuse `HostSession.recreationRequest` and the recreate code of the storage feature. Environment values and the command that are the same as in the old image MUST be left out, so the new image gives its own defaults.

## Success Criteria

- **SC-001**: On a Docker host (`nettop.local`) and on Apple `container` 1.7.1, a container from an old digest of a tag shows the mark, and "Update Container" makes it again on the new digest. Then the mark goes away.
- **SC-002**: With no network, the list shows no mark and no alert.

## Assumptions

- Apple hosts read registry credentials only from `~/.docker/config.json`. The logins of `container registry login` are in the Keychain item of the CLI; Gantry does not read it for this check. A private registry with no Docker credentials gives "unknown" (no mark).
- Apple has no record of a local build. A local build with the same name as a registry image can show a mark.
- The recreate keeps the settings that `recreationRequest` keeps. Extra networks (more than the network mode), entrypoint changes and the files in the container layer are lost, as with the volume switch of spec 004.
