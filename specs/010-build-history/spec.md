<!-- STE deviation: spec-kit template headings, the quoted user input, Given-When-Then scenarios, product names, CLI commands, file system names and paths stay verbatim. -->
# Feature Specification: Build History

**Feature Branch**: `feat/build-history`

**Created**: 2026-11-14

**Status**: Implemented and checked live

**Input**: User description: "A Builds view: past image builds with status, start, duration, steps, cached vs run steps, and the log of each. Docker hosts: `docker buildx history ls/inspect` (check availability and version; gate when missing). Apple hosts: research what `container build` and the builder expose; if there is no history, record builds started from Gantry itself. Parsing logic in AppCore/DockerKit with fixture tests."

## Context

Research on 2026-11-14:

- apple/container 1.7.1 has no build history. `container builder` has only `start`, `status`, `stop` and `delete`. `container build` prints BuildKit plain progress (`#N name`, `#N DONE 0.1s`, `#N CACHED`, `#N ERROR: …`) and keeps no record. Thus, on Apple hosts, Gantry records the builds that Gantry starts.
- Gantry builds on Docker hosts with the classic `/build` endpoint. The daemon streams `Step i/n : …` and ` ---> Using cache`. These builds do not show in `docker buildx history`. Thus, Gantry also records its own builds on Docker hosts.
- `docker buildx history ls --format json` (buildx 0.29.1, Docker 28.5.2) gives one JSON object per line with `ref`, `name`, `status`, `created_at`, `completed_at`, `total_steps`, `completed_steps` and `cached_steps`. `inspect --format json` gives `Error.Message`, `Context` and `Dockerfile`. `logs REF` gives BuildKit plain progress. These records come from BuildKit builds that the user starts with the `docker` CLI.
- Gantry does not need the `docker` CLI for any other feature. Buildx history is optional (constitution principle III).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See the builds that Gantry started (Priority: P1)

A user builds an image in the Build Image sheet, then opens the Builds section of the host. The list shows the build with its tag, status, start time, duration and the number of cached and run steps. The user selects the build and reads its steps and its full log. This works on Apple `container` hosts and on Docker hosts.

**Why this priority**: Apple hosts have no other source of build history. A failed build log is lost today when the sheet closes.

**Independent Test**: On an Apple host, build a small Dockerfile two times, and build a Dockerfile with a failing `RUN`. The Builds section shows three records: succeeded, succeeded with all steps cached, and failed with the failing step marked.

**Acceptance Scenarios**:

1. **Given** a connected Apple host, **When** the user builds an image in the Build Image sheet, **Then** a record with status "Succeeded", the start time and the duration shows in the Builds section.
2. **Given** a build where all Dockerfile steps came from cache, **When** the user selects it, **Then** each step shows "Cached" and the summary shows the number of cached steps.
3. **Given** a build failed at a `RUN` step, **When** the user selects it, **Then** the status is "Failed", the failed step is marked, and the error message and the full log show.
4. **Given** a build is in progress, **When** the user opens the Builds section, **Then** the record shows "Running".
5. **Given** the user cancels a build, **Then** its record shows "Cancelled".
6. **Given** Gantry quits and starts again, **When** the user opens the Builds section, **Then** the earlier records are still there.

---

### User Story 2 - See BuildKit builds on a Docker host (Priority: P2)

A user builds images on a Docker host with `docker build` in Terminal. In Gantry, the Builds section of that host also shows these builds from `docker buildx history`, with their status, steps, cached steps and log. Each record shows its source.

**Why this priority**: Most Docker builds start outside Gantry. Buildx keeps their history, so Gantry can show it without extra work for the user.

**Independent Test**: With fixtures copied from buildx 0.29.1, the parsers give the same counts as `docker buildx history ls`. On a host without the `docker` CLI or with an old buildx, the section shows an explanation and the Gantry records only.

**Acceptance Scenarios**:

1. **Given** a local Docker host and a `docker` CLI with buildx 0.23.0 or later, **When** the user opens Builds, **Then** buildx records show with the source "BuildKit" next to the Gantry records, newest first.
2. **Given** an SSH Docker host with `docker` and buildx on the remote machine, **When** the user opens Builds, **Then** Gantry reads the remote buildx history over SSH.
3. **Given** no `docker` CLI, no buildx, or buildx older than 0.23.0, **When** the user opens Builds, **Then** a short note tells why BuildKit records do not show and what to install. The host is not shown as broken.
4. **Given** a buildx record, **When** the user selects it, **Then** Gantry loads its log and its error message on demand.

---

### User Story 3 - Manage the recorded history (Priority: P3)

A user removes old records of one host with Clear History. Gantry asks for confirmation first. Gantry keeps a limited number of records per host, so the history does not grow without limit.

**Why this priority**: Logs can hold private build output. The user must be able to remove them.

**Independent Test**: Clear History on a host with records asks for confirmation (with Touch ID when on), then the Gantry records of that host are gone and the records of other hosts stay.

**Acceptance Scenarios**:

1. **Given** Gantry records on a host, **When** the user chooses Clear History and confirms, **Then** Gantry removes the Gantry records of that host only.
2. **Given** 100 records on a host, **When** a new build finishes, **Then** Gantry removes the oldest record.
3. **Given** buildx records, **When** the user chooses Clear History, **Then** buildx records stay (Gantry does not change the buildx store).

### Edge Cases

- A build log is very large: Gantry keeps the end of the log up to a fixed size and marks that it cut the start.
- A build used build arguments: Gantry records only the argument names, never the values.
- The host disconnects during a build: the record ends as "Failed" with the connection error.
- Gantry quits during a build: on the next start, a record that still says "Running" changes to "Interrupted".
- The buildx output has an unknown status or extra fields: Gantry shows the status text as is and ignores the unknown fields.
- `docker buildx history ls` fails (no builder, daemon down): Gantry shows the error as a note and keeps the Gantry records.
- A Compose project builds services: each service build is one record.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Each host MUST have a Builds section in the sidebar, after Images.
- **FR-002**: Gantry MUST record each image build that it starts (Build Image sheet and Compose) on every host kind, with: tag, Dockerfile, context path, target, no-cache flag, build argument names, start time, end time, status, image ID, log, and error message.
- **FR-003**: Gantry MUST compute the steps of a recorded build from its log: the BuildKit plain progress of `container build` and buildx, and the classic daemon stream of Docker. Each step has a name, a state (run, cached, failed, unknown) and a duration when the log gives one.
- **FR-004**: The list MUST show, for each record: status (icon and text, not color only), tag or name, source, start time, duration, and cached and total steps.
- **FR-005**: The detail MUST show the summary, the step list, the error message, and the full log with text selection.
- **FR-006**: On Docker hosts, Gantry MUST read `docker buildx history ls --format json` when a `docker` CLI with buildx 0.23.0 or later is available: the local CLI for local hosts, and the remote CLI over the SSH connection for SSH hosts. Gantry MUST load `inspect` and `logs` only for the selected record.
- **FR-007**: When buildx history is not available, Gantry MUST show the reason (no CLI, no buildx, old buildx, command error) and MUST still show the Gantry records.
- **FR-008**: Gantry MUST store its records on the Mac, per host, at most 100 records per host and at most 512 KB of log per record, in a file that only the user can read.
- **FR-009**: Gantry MUST NOT store build argument values.
- **FR-010**: Clear History MUST use the shared destructive confirmation and MUST remove only the Gantry records of the host.
- **FR-011**: When Gantry starts, a stored record with the status "Running" MUST change to "Interrupted".
- **FR-012**: When a host is removed, Gantry MUST remove its records.
- **FR-013**: All new user-facing strings MUST be in the String Catalogs with all 28 languages.

### Key Entities

- **Build record**: one build. Attributes: ID, host ID, source (Gantry or BuildKit), name or tag, status, start, end, duration, steps, total, cached and completed step counts, error message, log, build options (without argument values).
- **Build step**: one step of a build. Attributes: number, name, state, duration.
- **Buildx availability**: the result of the check: available with version, or unavailable with a reason.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After a build in the Build Image sheet, the record shows in the Builds section in 1 second or less after the build ends.
- **SC-002**: For the fixtures from buildx 0.29.1, the step count and the cached step count that Gantry computes from the log are equal to the counts that `docker buildx history ls` gives.
- **SC-003**: For the fixtures from `container build` 1.7.1 and the Docker 28.5.2 classic stream, Gantry finds each Dockerfile step and its cached state with no error.
- **SC-004**: On a host without the `docker` CLI, the Builds section shows the Gantry records and one explanation, with no error state.
- **SC-005**: No stored file contains a build argument value (verified by a test).
- **SC-006**: `scripts/check-localization.py` reports 0 problems.

## Assumptions

- The minimum buildx version is 0.23.0. The JSON format of `history inspect` came in 0.21, and the records and flags are stable in later versions. The fixtures come from 0.29.1. The parser accepts both the JSON lines form and a JSON array, and both key styles (`created_at` and `CreatedAt`).
- Gantry looks for the local `docker` CLI in `/usr/local/bin`, `/opt/homebrew/bin`, `~/.docker/bin` and `/Applications/Docker.app/Contents/Resources/bin`. `GANTRY_DOCKER` overrides the path.
- For a local Docker host, Gantry sets `DOCKER_HOST` to the socket of the host, so buildx uses the default builder of that daemon.
- Gantry does not change, remove or export buildx records. Docker Desktop actions (`open`, `export`) are out of scope.
- Build logs can contain private output of the user's build. They stay on the Mac with owner-only file permissions, as other Gantry data does.
- Kubernetes clusters are out of scope.
