<!-- STE deviation: spec-kit template headings, the quoted user input, Given-When-Then scenarios, product names, file system names and paths stay verbatim. -->
# Feature Specification: External Drives for Containers, Images and Volumes

**Feature Branch**: `feat/external-storage`

**Created**: 2026-11-07

**Status**: In Progress (implementation started before spec-kit adoption on 2026-11-07)

**Input**: User description: "Make external drives easy. Keep volumes, containers and images on an external disk, move them there and back, and stay safe when a disk is unplugged. Apple container hosts first, then Docker hosts where it makes sense." Source brief: `/Volumes/SanDisk2Tb/builds/gantry-027/storage.md`.

## Context

Apple's container tool keeps all its data in one data root, by default `~/Library/Application Support/com.apple.container`. The root holds containers, image content, snapshots, volumes, kernels and networks. Named volumes are sparse disk images inside the root. The internal disk of many Macs is small. Users want to keep this data on an external disk.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See where the data is and how much space it uses (Priority: P1)

A user opens System and selects Storage. Gantry shows the data root and the disk that holds it. For the disk, Gantry shows the name, the file system, the free and total space, and if it is internal or external. Gantry also shows the size of each category (images, containers, snapshots, volumes, kernels) and the real size on disk of each volume.

**Why this priority**: The user must know where the data is and how big it is before a move. The pane changes nothing, so it is safe to ship first.

**Independent Test**: Open Storage on a host of the container tool. Compare the sizes with `du` on the data root.

**Acceptance Scenarios**:

1. **Given** a host of the container tool, **When** the user opens Storage, **Then** Gantry shows the data root path and the name, file system, free space, total space and kind of its disk.
2. **Given** a sparse volume of 10 GB with 1 GB of data, **When** the user looks at the volume list, **Then** the size on disk is about 1 GB, not 10 GB.
3. **Given** the root is on an external disk, **When** the user opens Storage, **Then** the disk is marked as external.

---

### User Story 2 - Stay safe when a disk is unplugged (Priority: P1)

A user unplugs the external disk that holds the data root or the source folder of a bind mount. Gantry says which disk is not connected. Gantry disables Start for the containers that need the disk. Before an eject, Gantry tells the user to stop the containers that run from the disk.

**Why this priority**: Data loss and a host that looks broken are the largest risks of external disks.

**Independent Test**: Use a scratch folder on an external disk as a bind source. Eject the disk. Check the banners and the Start button. Mount the disk again.

**Acceptance Scenarios**:

1. **Given** the disk of the data root is disconnected, **When** the user opens the host, **Then** a banner says "The disk X is not connected". The host shows this reason next to its state.
2. **Given** a container with a bind mount on a disconnected disk, **When** the user looks at the container, **Then** the container shows the same message and Start is disabled.
3. **Given** containers run from a disk, **When** the user starts to eject that disk, **Then** Gantry posts a notification that tells the user to stop them first.
4. **Given** the disk is connected again, **When** macOS mounts it, **Then** the banners go away and Start is enabled.

---

### User Story 3 - Create a volume on an external disk (Priority: P2)

A user creates a new volume and selects "Folder on a disk" as the location. Gantry creates a folder on the selected disk and records it as a volume that Gantry manages. The user can select this volume in the New Container form like a named volume. On Docker hosts, Gantry creates a local volume with a bind to the folder.

**Why this priority**: Most users want only their large data on the external disk, not the whole root.

**Independent Test**: Create a volume in a scratch folder on the external disk. Run a container that writes a file into it. Find the file in the folder.

**Acceptance Scenarios**:

1. **Given** a host of the container tool, **When** the user creates a volume in a folder on a disk, **Then** Gantry creates the folder and lists the volume as managed by Gantry.
2. **Given** a managed folder volume, **When** the user creates a container, **Then** the volume is in the volume list of the form.
3. **Given** a Docker host, **When** the user creates a volume in a folder, **Then** Gantry creates a local volume with a bind to that folder.

---

### User Story 4 - Pick a bind mount folder with warnings (Priority: P2)

A user adds a bind mount in the New Container form. A folder picker shows external disks. Gantry warns when the disk is removable or when its file system has no permissions.

**Why this priority**: It prevents containers that fail later because of a removable disk or a file system with no permissions.

**Independent Test**: Pick a folder on an APFS disk and a folder on an exFAT disk. Check the warnings.

**Acceptance Scenarios**:

1. **Given** the user picks a folder on a removable disk, **When** the form shows the mount, **Then** Gantry warns that the container cannot start without the disk.
2. **Given** the user picks a folder on exFAT, **When** the form shows the mount, **Then** Gantry warns that the file system has no permissions.

---

### User Story 5 - Move a volume, export it, and save images (Priority: P3)

A user moves a named volume to a folder on a disk and back. The user exports a volume to a `.tar` file and imports it again. The user saves an image to a `.tar` file on a disk and loads it again. Gantry shows the progress.

**Why this priority**: It is useful, but the user can do it by hand today.

**Independent Test**: Move a test volume with data to a scratch folder. Check the data. Export it and import it into a new volume.

**Acceptance Scenarios**:

1. **Given** a named volume with data, **When** the user moves it to a disk folder, **Then** Gantry copies the data and verifies the copy.
2. **Given** containers use the volume, **When** the move is ready to switch, **Then** Gantry asks before it recreates those containers.
3. **Given** a volume, **When** the user exports it, **Then** Gantry writes a `.tar` file and shows the progress.
4. **Given** an image, **When** the user saves it to a disk, **Then** Gantry writes a `.tar` file that loads again.

---

### User Story 6 - Move the whole data root to another disk (Priority: P3)

A user moves the data root to an external disk. Gantry lists suitable disks and checks the free space. After confirmation, Gantry stops the services, copies the data and keeps sparse files, owners and extended attributes. Gantry verifies the copy, switches the root, starts the services, and checks that containers, images and volumes are listed. Then Gantry offers to delete the old copy with a second confirmation. Every later start uses the new root.

**Why this priority**: It has the largest effect, but also the most risk. It needs Stories 1 and 2 first.

**Independent Test**: Move a small fake root to a scratch folder. Check the copy and the verification. The switch of the user's real root is not part of the test.

**Acceptance Scenarios**:

1. **Given** the target disk is exFAT, FAT or NTFS, **When** the user selects it, **Then** Gantry refuses it and tells why.
2. **Given** the target disk is a network disk, **When** the user selects it, **Then** Gantry warns the user.
3. **Given** the target disk has less free space than the allocated size, **When** the user selects it, **Then** Gantry refuses to start.
4. **Given** the copy runs, **When** the user selects Cancel before the switch, **Then** the old root stays as it was.
5. **Given** the copy is complete, **When** Gantry verifies it, **Then** sparse images stay sparse and the sizes and files match.
6. **Given** the root moved, **When** Gantry, the menu bar or a Control Center control starts the services, **Then** they use the new root.
7. **Given** the move worked, **When** the user deletes the old copy, **Then** Gantry asks again with Touch ID if the user turned it on.

---

### Edge Cases

- The disk name has spaces or the same name as another disk.
- The disk is ejected during a copy or a move.
- The data root is a symbolic link.
- Two disks have the same volume name.
- The case-sensitive and case-insensitive file systems differ between source and target.
- A bind mount source is on a disk that macOS has not mounted yet at app start.
- The services were started outside Gantry with a different root.
- A volume export is larger than the free space of the target.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Gantry MUST show the data root, its disk (name, file system, free and total space, internal, external or removable), the size of each category and the size on disk of each volume.
- **FR-002**: Gantry MUST measure the allocated size of sparse files, not the apparent size.
- **FR-003**: Gantry MUST watch disk mounts and unmounts. Gantry MUST show a clear message on the host and on each affected container when a needed disk is not connected.
- **FR-004**: Gantry MUST disable Start for a container that needs a disk that is not connected.
- **FR-005**: Gantry MUST notify the user before an eject when containers run from that disk.
- **FR-006**: Gantry MUST let the user create a volume in a folder on a disk. On hosts of the container tool, Gantry MUST record it as a managed bind volume. On Docker hosts, Gantry MUST use a local volume with a bind.
- **FR-007**: Managed folder volumes MUST be selectable in the New Container form.
- **FR-008**: The bind mount picker MUST show external disks and warn about removable disks and file systems with no permissions.
- **FR-009**: Gantry MUST move a named volume to a disk folder and back. Gantry MUST verify the copy and ask before it recreates containers.
- **FR-010**: Gantry MUST export and import a volume as a `.tar` file, and save and load an image as a `.tar` file, with progress.
- **FR-011**: Gantry MUST accept only APFS and HFS+ disks for the data root, warn on network disks, and check the free space against the allocated size.
- **FR-012**: Gantry MUST stop the services only after the user confirms.
- **FR-013**: Gantry MUST copy the root with sparse files, owners and extended attributes, and verify the copy before the switch.
- **FR-014**: Gantry MUST NOT delete the source before the new root is verified. The delete MUST use the shared destructive confirmation.
- **FR-015**: A Cancel before the switch MUST leave the old root as it was.
- **FR-016**: After the switch, every start from Gantry, the menu bar and the Control Center controls MUST use the chosen root. Gantry MUST tell the user how the container tool finds the root.
- **FR-017**: Long operations MUST run in the operations list with progress and Cancel.
- **FR-018**: Docker-only options MUST stay hidden on hosts of the container tool.
- **FR-019**: All new user-facing text MUST be localizable.

### Key Entities

- **Disk**: name, mount point, file system, free and total space, internal, external, removable or network, connected or not.
- **Data root**: path, disk, size by category, and the root that later starts must use.
- **Managed folder volume**: name, folder path, disk, host.
- **Move plan**: source, target, allocated size, steps (stop, copy, verify, switch, start, check) and state.
- **Mount event**: mount, will-unmount or unmount of a disk.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user sees where the data is and how big it is in less than 10 seconds.
- **SC-002**: In 100 % of the tests, Gantry keeps the source data until the copy is verified.
- **SC-003**: After an unplug, the host and each affected container show the reason in less than 5 seconds.
- **SC-004**: A sparse test image keeps an allocated size within 5 % of the source after a copy.
- **SC-005**: A user creates a volume on an external disk in less than 1 minute.

## Assumptions

- How the container tool keeps the chosen root for later starts is not known yet. The research reads the 1.7.1 source. [NEEDS CLARIFICATION: flag only, environment variable, config.toml property or launchd plist]
- The live tests use only `/Volumes/SanDisk2Tb/builds/gantry-027/storage/live/` and objects with the `gstore-` prefix. The tests remove them afterwards.
- The real data root of the user is not moved and the services are not stopped during development. The root switch can stay untested on the real install. The report must say so.
- The volume move uses a short-lived helper container (for example alpine) to copy the data.
- Docker support covers folder volumes, export, import, and image save and load. The data root move is for hosts of the container tool only.
- Translations into the other UI languages are done by the maintainer after the English text is final.
