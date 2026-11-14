<!-- STE deviation: spec-kit template headings, the quoted user input, Given-When-Then scenarios, product names, Compose keys, file system names and paths stay verbatim. -->
# Feature Specification: Export a Running Container as a Compose File

**Feature Branch**: `feat/compose-export`

**Created**: 2026-11-14

**Status**: Draft

**Input**: User description: "From a container (and from a set of selected containers) generate a docker-compose.yml from inspect data: image, command, entrypoint, env (mask values that look like secrets and let the user choose to include them), ports, volumes and binds, networks, restart policy, labels, healthcheck, resources. Show a preview sheet with the YAML, warnings for fields that compose cannot express, then Save or Copy. For Apple container hosts, map what is possible and warn about the rest. Generation logic in AppCore with fixture tests (round-trip sanity: generated YAML parses). Optional: a short comment header via Foundation Models only if already used in the app and gated on availability; not required."

## Context

Gantry can copy a container as a `docker run` or a `container run` command. Many users keep their services in Compose files. When a user made a container by hand, the user must write the Compose file by hand to keep that setup. This feature makes the Compose file from the inspect data of the container that runs now.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Export one container as Compose (Priority: P1)

A user right-clicks a container on a Docker host and selects "Export as Compose…". A sheet opens. The sheet shows the Compose YAML of the container: image, command, entrypoint, environment, ports, volumes and binds, networks, restart policy, labels, healthcheck and resource limits. The user clicks Copy, or clicks Save and selects a file.

**Why this priority**: This is the main value of the feature. One container is the most frequent case.

**Independent Test**: Run a container with ports, a named volume, a bind, a network, labels, a restart policy, a healthcheck and limits. Export it. The YAML has each of these settings, and `docker compose config` (or the Gantry Compose parser) reads the file without errors.

**Acceptance Scenarios**:

1. **Given** a running container with port 8080 published to 80, **When** the user exports it, **Then** the YAML has `ports: ["8080:80"]` under the service.
2. **Given** a container with a named volume and a bind, **When** the user exports it, **Then** the service lists both mounts, and the named volume is declared at the top level as `external: true`.
3. **Given** a container on a user network, **When** the user exports it, **Then** the service lists the network and the network is declared at the top level as `external: true`.
4. **Given** the preview sheet, **When** the user clicks Copy, **Then** the YAML goes to the pasteboard. **When** the user clicks Save, **Then** a save panel opens with the name `docker-compose.yml`, and Gantry writes the YAML to the selected file.
5. **Given** a container whose settings are equal to the image defaults (command, entrypoint, environment, working directory, user, labels), **When** the user exports it, **Then** the YAML does not repeat the image defaults.

---

### User Story 2 - Secret values stay out of the file unless the user includes them (Priority: P1)

A container has the environment variable `DB_PASSWORD`. In the preview, its value is not shown. The YAML has `DB_PASSWORD: ${DB_PASSWORD}`, so that Compose reads the value from the shell or from a `.env` file. The sheet lists the masked variables. The user can turn on each variable to put its real value in the file.

**Why this priority**: Constitution principle IV: Gantry keeps secrets out of plain-text files. A Compose file is often committed to git.

**Independent Test**: Export a container with `DB_PASSWORD=hunter2` and `APP_MODE=prod`. The YAML has `APP_MODE: prod` and `DB_PASSWORD: ${DB_PASSWORD}`. The text `hunter2` is not in the YAML. Turn on `DB_PASSWORD`. The YAML has the value.

**Acceptance Scenarios**:

1. **Given** a variable with a secret name (for example `PASSWORD`, `TOKEN`, `SECRET`, `API_KEY`), **When** the user exports, **Then** the value is masked by default.
2. **Given** a variable with a value that looks like a random token (16 or more letters and digits), **When** the user exports, **Then** the value is masked by default.
3. **Given** masked variables, **When** the user turns one on, **Then** the preview shows that value, and the other masked values stay masked.
4. **Given** the file includes a secret value, **When** Gantry saves it, **Then** only the user can read the file (permissions `0600`).

---

### User Story 3 - Export several selected containers as one file (Priority: P2)

A user selects three containers in the list and selects "Export as Compose…" in the context menu. The sheet shows one Compose file with one service for each container, and one shared set of top-level networks and volumes.

**Why this priority**: A small stack made by hand (an app, a database, a cache) is a frequent case. It builds on User Story 1.

**Independent Test**: Select two containers that share a network and a volume. Export them. The YAML has two services, the network and the volume are declared one time, and the file parses.

**Acceptance Scenarios**:

1. **Given** two containers with the same name after the service name rules, **When** the user exports them, **Then** the service names are different (`web`, `web-2`).
2. **Given** containers made by Compose (they have `com.docker.compose.*` labels), **When** the user exports them, **Then** the service names come from the Compose labels, the Compose labels are not copied, and the project name is the top-level `name` when all containers have the same project.
3. **Given** a container that uses the network of another selected container, **When** the user exports both, **Then** the YAML has `network_mode: "service:<name>"`.

---

### User Story 4 - Warnings for settings that Compose cannot express (Priority: P2)

The sheet shows a list of warnings under the YAML. Each warning names the service and the setting, and tells what the user must do. Examples: "Remove after stop" (`--rm`) has no Compose equivalent; an anonymous volume gives a new empty volume; the image is known only by its digest.

**Why this priority**: The user must know where the file is not equal to the running container.

**Independent Test**: Export a container that was started with `--rm` and an anonymous volume. The warning list has two items.

**Acceptance Scenarios**:

1. **Given** a container with no warnings, **When** the sheet opens, **Then** the sheet tells "No warnings" and shows no empty list.
2. **Given** warnings, **When** VoiceOver reads the list, **Then** each warning is one element with the service name and the text. The warning state is not shown by color only.

---

### User Story 5 - Export from an Apple container host (Priority: P2)

A user exports a container on the local Apple `container` host. Gantry maps the image, the process, the environment, the published ports, the volumes, binds and tmpfs mounts, the networks, the labels, the capabilities, CPU and memory. Gantry warns about settings that Compose cannot express: custom kernel, kernel arguments, Rosetta, virtualization, SSH agent forwarding, published sockets, DNS domain. Gantry also tells that `container` sets CPU and memory for each container, so the limits in the file can be the defaults.

**Why this priority**: Constitution principle III: Gantry works with only Apple `container`. The feature must not be Docker-only.

**Independent Test**: Run an Apple container with a port, a named volume, a read-only bind, a tmpfs mount, a network, labels, `--cpus 2 -m 512M` and `--cap-add CAP_NET_ADMIN`. Export it. The YAML has each of these settings, the bind is `:ro`, and the warnings list the Apple-only settings.

**Acceptance Scenarios**:

1. **Given** an Apple container whose process is the image entrypoint and command, **When** the user exports it, **Then** the YAML has no `entrypoint` and no `command`.
2. **Given** an Apple container started with `--entrypoint /bin/sh` and arguments, **When** the user exports it, **Then** the YAML has `entrypoint` and `command` that start the same process.
3. **Given** an Apple named volume, **When** the user exports it, **Then** the YAML uses the volume name, not the path of the disk image of the volume.

### Edge Cases

- An environment value or a command argument contains `$`: the YAML escapes it as `$$`, so that Compose does not read it as a variable.
- A string that YAML reads as a number, a boolean or null (`80:80`, `yes`, `on`, `null`, `0755`): the YAML quotes it.
- A bind source contains `:`: the YAML uses the long volume syntax.
- The container is removed while the sheet loads: the sheet shows an error and no YAML.
- The image cannot be inspected: Gantry keeps all settings, because it cannot remove the image defaults. A warning tells this.
- The healthcheck of the container is equal to the image healthcheck: the YAML does not repeat it. `NONE` gives `disable: true`.
- A Kubernetes cluster node container on an Apple host: export works like for other containers.
- A remote Docker host over SSH: bind sources are paths on the remote host. A warning tells this.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The context menu of one container, the More menu of the container detail view, and the context menu of several selected containers MUST have the item "Export as Compose…".
- **FR-002**: Gantry MUST make one Compose file with one service for each selected container, from the inspect data of the container and of its image.
- **FR-003**: Each service MUST have the image, and, when they differ from the image defaults, the entrypoint, command, environment, working directory, user and labels.
- **FR-004**: Each service MUST have the published ports, named volumes, binds, tmpfs mounts, networks with aliases and static IPv4 addresses, the network mode, the restart policy, the healthcheck, CPU and memory limits, and the other host settings that Compose can express (capabilities, privileged, read-only root, devices, DNS, extra hosts, init, shared memory size, sysctls, ulimits, security options, logging, stop signal and timeout, hostname, domain name, TTY and stdin).
- **FR-005**: Named volumes and networks MUST be declared at the top level as `external: true`, one time each.
- **FR-006**: Environment values with a secret name, or that look like random tokens, MUST be masked as `${NAME}` by default. The user MUST be able to include each masked value separately.
- **FR-007**: A file that includes a secret value MUST be saved with permissions `0600`.
- **FR-008**: Gantry MUST escape `$` in all values as `$$`, except in the `${NAME}` references that it makes itself. Gantry MUST quote each string that YAML can read as another type.
- **FR-009**: Gantry MUST show a warning for each setting that Compose cannot express or that Gantry cannot copy exactly. Each warning names the service.
- **FR-010**: On an Apple `container` host, Gantry MUST read the original data of `container inspect`, and MUST warn about the Apple-only settings listed in User Story 5.
- **FR-011**: The preview sheet MUST show the YAML in a monospaced, selectable, scrollable view, the list of masked variables, the list of warnings, and the buttons Copy, Save… and Done.
- **FR-012**: The generated YAML MUST parse with the Gantry Compose parser, and the parsed services MUST have the exported image, ports, mounts and environment.
- **FR-013**: The generation logic MUST be in AppCore, with Swift Testing tests on fixtures (one Docker inspect, one Apple `container` 1.7.1 inspect from a live run).
- **FR-014**: All new user-facing strings MUST have translations for all 28 supported UI languages.

### Key Entities

- **Export source**: one container: its inspect data, the inspect data of its image (when available), and the host kind (Docker or Apple `container`).
- **Export options**: the set of masked variables that the user includes.
- **Export result**: the YAML text, the warnings, and the masked variables with their service names.
- **Warning**: the service name and a localized text.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user exports one container and has the Compose file on the pasteboard in 3 clicks or fewer (menu item, Copy, Done).
- **SC-002**: For the test fixtures, 100% of the generated files parse with the Compose parser, and the parsed image, ports, mounts and environment are equal to the source.
- **SC-003**: With the default options, no masked secret value is in the YAML text (checked by the tests).
- **SC-004**: All new strings have translations in 28 languages; `scripts/check-localization.py` reports 0 problems.

## Assumptions

- The Compose file is for Docker Compose v2 and the Compose Specification. The file has no `version` key.
- Named volumes and networks exist on the host, so they are `external: true`. Gantry does not copy volume data.
- `container_name` is set for containers that Compose did not make, so that the new container has the same name.
- The optional Foundation Models comment header is out of scope. The feature works without Apple Intelligence.
- Gantry does not save the export to the MCP server or to a recipe in this feature.
