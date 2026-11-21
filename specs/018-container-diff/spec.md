<!-- STE deviation: spec-kit template headings, Given-When-Then scenarios, product names, API paths and CLI names stay verbatim. -->
# Feature Specification: Container Changes and Commit Options

**Feature Branch**: `feat/container-diff`

**Created**: 2026-11-21

**Status**: Implemented

**Input**: User description: "Show the file changes of a container, and commit it as an image. A Changes view in the container detail lists the files that the container added, changed and deleted compared to its image (Docker `GET /containers/{id}/changes`), as a tree or a flat list, with a filter by kind, a search field and the count of each kind. The action Commit as Image… opens a sheet with repository, tag, optional message and author, and Pause during commit (default on), with Docker `POST /commit`, and refreshes the image list. Apple `container`: hide the controls that have no equivalent. A large diff must not freeze the UI. Optional: show the diff in the file browser."

## Context

Gantry already has "Commit to Image…" with repository, tag and comment. It has no author, no pause option, and it shows the comment field on Apple hosts, where the CLI ignores it. Gantry has no view of the file changes of a container.

Apple `container` 1.7.1 has `container commit <id> <reference>` and no other options. It has no command for the file changes of a container (`container --help`, and the 1.7.1 sources: `Sources/ContainerCommands/Container/ContainerCommit.swift` exports the root file system and loads it as an image; no diff exists).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See the file changes of a container (Priority: P1)

A user opens a container on a Docker host and selects the "Changes" tab. A list shows each path that the container added, changed or deleted, compared to its image. The header shows the count of each kind. The user filters by kind, searches by path and switches between a flat list and a tree.

**Independent Test**: Run `alpine` on a Docker host, add `/tmp/a`, change `/etc/profile` and delete `/etc/motd`. The Changes tab shows the same paths as `docker diff`.

**Acceptance Scenarios**:

1. **Given** a Docker host, **When** the user opens the Changes tab, **Then** Gantry loads `GET /containers/{id}/changes` and shows each path with its kind (Added, Changed, Deleted) as an icon and a text.
2. **Given** the list, **When** the user turns off one kind, **Then** the rows of that kind go away and the counts stay.
3. **Given** the search text "etc", **When** the user types it, **Then** only paths that contain "etc" (any letter case) stay.
4. **Given** the tree mode, **When** the user expands a directory, **Then** its changed children show.
5. **Given** a container with no changes, **When** the tab opens, **Then** an empty state says that the file system is the same as the image.
6. **Given** an Apple host, **When** the user opens a container, **Then** the Changes tab is not there.

### User Story 2 - A large diff does not freeze the UI (Priority: P1)

**Acceptance Scenarios**:

1. **Given** a diff with 50,000 entries, **When** the tab opens or the filter changes, **Then** the decode, filter and tree build run off the main actor, and the list draws at most 2,000 rows (per directory in the tree). A line tells how many rows are not shown and asks the user to refine the search.

### User Story 3 - Commit a container as an image with options (Priority: P2)

The user selects "Commit to Image…". The sheet has repository, tag, message (optional), author (optional) and "Pause during commit" (on by default). After the commit, the image list refreshes.

**Acceptance Scenarios**:

1. **Given** a Docker host, **When** the user commits with a message, an author and the pause on, **Then** Gantry sends `POST /commit?container=&repo=&tag=&comment=&author=&pause=true`.
2. **Given** the pause off, **When** the user commits, **Then** Gantry sends `pause=false`.
3. **Given** an Apple host, **When** the sheet opens, **Then** it shows repository and tag only, because `container commit` has no message, author or pause.
4. **Given** a successful commit, **When** the sheet closes, **Then** the image list shows the new image.

### User Story 4 - Changed files in the file browser (Priority: P3)

**Acceptance Scenarios**:

1. **Given** a Docker host and the Files tab, **When** a listed item is added or changed in the container, **Then** its row has a small "Added" or "Changed" badge with a text label for accessibility.

## Requirements

- **FR-001**: DockerKit MUST decode `GET /containers/{id}/changes` (`Kind` 0 = changed, 1 = added, 2 = deleted; a `null` body is an empty list).
- **FR-002**: AppCore MUST count, filter (kinds and search) and build a tree of the changes in pure functions with tests. The work MUST run off the main actor.
- **FR-003**: The view MUST draw at most `ContainerChanges.rowLimit` rows at one time and tell the number of hidden rows.
- **FR-004**: `HostSession.commit` MUST send `author` and `pause`. The DockerKit default of `pause` MUST be `true`, the same as Docker.
- **FR-005**: `HostCapabilities` MUST gate the Changes tab (`containerChanges`) and the commit options (`commitOptions`). Both are off for Apple hosts. The Apple transport MUST answer `/containers/{id}/changes` with a clear 501.
- **FR-006**: Every new string MUST be in the catalogs with all 28 languages. Counts use plural variations.

## Success Criteria

- **SC-001**: On a Docker host (nettop), the Changes tab of a test container shows the added, changed and deleted paths that `docker diff` shows.
- **SC-002**: A commit with a message and an author makes an image whose `Comment` and `Author` are those values.
- **SC-003**: Filtering 50,000 entries takes less than 200 ms off the main actor in the unit test (measured: 136 ms for the flat list and a tree, Debug build).
