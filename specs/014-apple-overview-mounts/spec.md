<!-- STE deviation: spec-kit template headings, the quoted user input, Given-When-Then scenarios, product names, file system names and paths stay verbatim. -->
# Feature Specification: Apple Container Mounts in Overview

**Feature Branch**: `fix/apple-overview-mounts`

**Created**: 2026-11-14

**Status**: Implemented; the GUI live check (T008) is open

**Input**: User description: "Fix: on Apple container hosts the DockerKit translation of `container inspect`/`list` mounts ignores options [\"ro\"] so read-only binds show rw; maps type {\"virtiofs\":{}} to \"virtiofs\" not \"bind\"; never sets Name for named volumes so Overview shows the volume.img path. Fix the translation so Mounts gets Docker-shaped Type, Name, RW, Source, Destination; Overview shows the volume name for volumes. Consumers keep working. Fixture tests from real container 1.7.1 inspect output."

## Context

We found this defect during PR #68 (compose export). Gantry translates the JSON of
`container inspect` and `container list` into Docker-shaped JSON. The translation of
`configuration.mounts` has three errors:

- It reads `readOnly`, but apple/container 1.7.1 writes `"options": ["ro"]`. A read-only
  bind shows as `rw`.
- It copies the type key as it is: `virtiofs`, `volume`, `tmpfs`. Docker uses `bind` for a
  host folder.
- It does not read the volume name from `type.volume.name`. The source of a named volume is
  the path of its `volume.img` file, so the Overview tab shows that path.

The Docker-shaped mounts also go to copy-as-run (recipes), Explain, the "in use by" counts
of the volume delete confirmations, volume transfer and the disk presence check.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The Overview tab shows mounts as they are (Priority: P1)

A user opens a container on an Apple `container` host. The Mounts section of the Overview tab
shows each read-only bind as `ro`, and shows each named volume by its name.

**Why this priority**: The Overview tab shows wrong data today. A user can think that a
container can write to a folder when it cannot.

**Independent Test**: Translate the real inspect output of a container with a read-only bind,
a read-write bind, a named volume and a tmpfs. Check the type, name, source, target and mode
of each mount.

**Acceptance Scenarios**:

1. **Given** a container started with `-v /host/dir:/ro:ro`, **When** the user opens Overview, **Then** the mount row shows `/host/dir → /ro` and `ro`.
2. **Given** a container started with `-v data:/data`, **When** the user opens Overview, **Then** the mount row shows `data → /data` and `rw`, not the path of `volume.img`.
3. **Given** a container on a Docker host with a named volume, **When** the user opens Overview, **Then** the mount row shows the volume name.

---

### User Story 2 - Other features read the correct mounts (Priority: P2)

Copy-as-run, Explain and the volume delete confirmation use the same mounts. They must get the
read-only flag and the volume name.

**Why this priority**: These features give wrong results today on Apple hosts (copy-as-run
writes the `volume.img` path as the volume source and drops `:ro`; the delete confirmation does
not count the containers that use a volume).

**Independent Test**: Build a recipe and an Explain mounts text from the translated fixture.
Count the users of a volume in a container list from the fixture.

**Acceptance Scenarios**:

1. **Given** the fixture container, **When** Gantry makes a recipe, **Then** the volumes are `/host/dir:/ro:ro`, `/host/rw:/rw` and `data:/data`, and the tmpfs is not a volume.
2. **Given** the fixture container in a list, **When** the user deletes the volume `data`, **Then** the confirmation counts one container that uses it.

### Edge Cases

- A mount without `options` is read-write.
- An older CLI that writes `readOnly` (bool) still works.
- A `type` that is a plain string still works.
- A volume without a name in `type.volume` (for example an anonymous volume) falls back to the
  `name` key or to the source.
- A tmpfs mount keeps type `tmpfs`; copy-as-run skips it as before.
- An unknown type key (for example `block`) passes through unchanged.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The translation MUST set the mount type to `bind` for `virtiofs` and `bind`, `volume` for `volume`, `tmpfs` for `tmpfs`, and keep other types unchanged.
- **FR-002**: The translation MUST set the volume name from `type.volume.name`, or from a `name` key.
- **FR-003**: The translation MUST set the read-only flag from `options` that contain `ro`, or from a `readOnly` or `readonly` bool. A mount without these MUST be read-write.
- **FR-004**: The translation MUST keep the source (host path, or the `volume.img` path for a volume) and the target.
- **FR-005**: The Overview tab MUST show the name of a named volume instead of its source, on Apple and Docker hosts.
- **FR-006**: Container lists and inspect bodies MUST use the same mount translation.

### Key Entities

- **Mount**: type, name (volumes only), source, target, read-only flag.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For the real 1.7.1 fixture, 4 of 4 mounts have the correct type, name, source, target and mode.
- **SC-002**: Copy-as-run for the fixture gives the same volumes that the user typed to create the container.
- **SC-003**: All tests in DockerKit and AppCore that cover mounts pass.

## Assumptions

- apple/container 1.7.1 is the reference. The fixture comes from a live `container inspect`.
- The source of a named volume stays the `volume.img` path. Disk presence checks use host
  paths, and that path is on the disk of the data root.
- The tmpfs source stays `tmpfs` as the CLI writes it.
- No new user-facing strings: `ro` and `rw` already show as they are.
