<!-- STE deviation: spec-kit template headings, Given-When-Then scenarios, product names, Docker API keys, CLI flags and paths stay verbatim. -->
# Feature Specification: Edit the Resources of a Container

**Feature Branch**: `feat/live-limits`

**Created**: 2026-11-21

**Status**: Implemented (the UI check of the sheet is open, see tasks.md T018)

**Input**: User description: "Change the CPU, memory and restart policy of a running container. Docker: `POST /containers/{id}/update`, no restart, show the daemon errors in the sheet. Apple `container`: if the CLI cannot change a running container, offer Apply and Recreate with a confirmation. Validate the values. Refresh the detail and the stats after the change."

## Context

Today a user can change only the restart policy of a container (a submenu on Docker hosts). To change the CPU or memory limit, the user must remove the container and create it again by hand.

Docker can change these limits on a running container with `POST /containers/{id}/update`. The container does not restart.

Apple `container` 1.7.1 has no `update` command. `container --help` and the 1.7.1 sources show this. `--cpus` and `--memory` are only `create` and `run` options. The CLI has no restart policy. The sources validate the values. CPUs is an integer from 1 to the host core count. Memory is at least 200 MiB, in steps of 1 MiB. Thus on an Apple host the only path is to recreate the container.

## User Scenarios and Testing

### User Story 1 - Change the limits of a running Docker container (Priority: P1)

The user selects "Edit Resources…" in the container menu or in the More menu of the container detail. A sheet shows the CPU limit (cores), the memory limit, the memory reservation, the memory plus swap limit and the restart policy. The values come from inspect. The user changes values and clicks Apply. The container does not restart.

**Independent Test**: On a Docker host, set the memory of a running container to 256 MiB. `docker inspect` shows `Memory` 268435456, and `StartedAt` does not change.

**Acceptance Scenarios**:

1. **Given** a container with `NanoCpus` 500000000 and `Memory` 67108864, **When** the user opens the sheet, **Then** the sheet shows 0.5 cores and 64 MiB.
2. **Given** the user changes only the memory, **When** the user clicks Apply, **Then** Gantry sends only `Memory` to `/containers/{id}/update`.
3. **Given** the daemon rejects the update (for example "Minimum memoryswap limit should be larger than memory limit"), **When** the user clicks Apply, **Then** the sheet stays open and shows the daemon message.
4. **Given** the update succeeds, **When** the sheet closes, **Then** the Overview shows the new limits and the Stats tab starts a new stream, so the memory chart shows the new limit.

### User Story 2 - Change the limits of an Apple container (Priority: P1)

On an Apple `container` host the sheet shows only the CPUs and the memory. The button is "Apply and Recreate…". Gantry asks for confirmation because the container is removed and created again (it restarts, and its files outside volumes are lost). Then Gantry recreates the container with the new values.

**Independent Test**: On this Mac, recreate `lim-web` with 2 CPUs and 512 MiB. `container inspect lim-web` shows `cpus` 2 and `memoryInBytes` 536870912.

**Acceptance Scenarios**:

1. **Given** an Apple host, **When** the user opens the sheet, **Then** the sheet shows no reservation, no swap and no restart policy.
2. **Given** the user clicks "Apply and Recreate…", **When** the confirmation shows, **Then** nothing changes until the user confirms.
3. **Given** the user confirms, **When** the recreate is done, **Then** the container has the new values and keeps its image, command, environment, ports, binds and labels.

### User Story 3 - Values are checked before they are sent (Priority: P1)

**Acceptance Scenarios**:

1. **Given** the CPU field holds "0", "-1", "abc" or a value above the host CPU count, **When** the user looks at the sheet, **Then** the field shows the problem and Apply is off.
2. **Given** a memory field holds "512", "512m", "1.5g" or "2 GiB", **When** Gantry reads it, **Then** it is a valid size (a number with no unit is MiB). "12x" and "-5m" are not valid.
3. **Given** the swap field holds "-1" or "unlimited", **When** Gantry reads it, **Then** it means no swap limit.
4. **Given** a Docker container with a memory limit, **When** the user clears the field, **Then** the sheet says that Docker cannot remove the limit from an existing container.
5. **Given** an Apple host, **When** the CPU value is not a whole number or the memory is below 200 MiB, **Then** the field shows the problem.

## Requirements

- **FR-001**: The container context menu and the More menu of the container detail MUST have "Edit Resources…".
- **FR-002**: The sheet MUST show the values from inspect: CPU cores (`NanoCpus`), memory (`Memory`), memory reservation (`MemoryReservation`), memory plus swap (`MemorySwap`, -1 is unlimited) and the restart policy with its retry count.
- **FR-003**: On Docker hosts, Apply MUST send only the changed fields to `POST /containers/{id}/update`, and MUST show a daemon error in the sheet.
- **FR-004**: On Apple hosts, the sheet MUST show only CPUs and memory, and Apply MUST recreate the container through `HostSession.recreate` after a confirmation.
- **FR-005**: The recreate MUST keep the CPU and memory limits of the old container when the change does not set them. This also fixes the recreate of spec 004 (volume move) and the DNS domain change, which lost the limits before.
- **FR-006**: Gantry MUST validate the values before it sends them: positive numbers, memory units (b, k, m, g, t with an optional "i" and "b"), CPU not above the host CPU count.
- **FR-007**: After a change, Gantry MUST refresh the inspect cache, the container list, the Overview and the Stats stream.
- **FR-008**: All new strings MUST be in the String Catalogs in 28 languages.

## Success Criteria

- **SC-001**: On `nettop.local` (Docker 29.6), a memory change of a running container with the sheet logic does not change `StartedAt`.
- **SC-002**: On this Mac (apple/container 1.7.1), the recreate gives the container the new CPU and memory values.
- **SC-003**: `scripts/check-localization.py` shows 0 problems.
