<!-- STE deviation: spec-kit template headings, the quoted user input, Given-When-Then scenarios, product names and paths stay verbatim. -->
# Feature Specification: Full Support for Apple container 1.7.1

**Feature Branch**: `feat/apple-container-1-7-1`

**Created**: 2026-11-07

**Status**: In Progress (implementation started before spec-kit adoption on 2026-11-07)

**Input**: User description: "Full support for apple/container 1.7.1. Main already supports the 1.7 cluster changes (PR #50). Add: a clear message when the cluster services are not installed or not running, an editor for the DNS defaults in config.toml, the new CPU utilization value in stats, a check that the kernel recommendation follows the CLI, and a review of every other 1.6.1 to 1.7.1 change." Source brief: `/Volumes/SanDisk2Tb/builds/gantry-027/ac171.md`. Context: `ac17.md` and `ac17/REPORT.md` in the same folder.

## Context

Main already has the cluster changes of 1.7 (PR #50, branch `feat/apple-container-1-7`). These are the per-cluster list, worker nodes with their CPUs and memory, the shared local image store, and the lock on lifecycle actions for cluster node containers. This feature keeps them as they are. It adds the remaining user-visible changes of release 1.7.1.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Understand why clusters do not work (Priority: P1)

A user opens the Clusters section. The cluster services of the container tool are absent or stopped. Thus every cluster command fails with a low-level connection error. Gantry tells the user what is wrong and what to do. If the user has a Homebrew build that does not include the cluster services, Gantry says so and links to the signed installer. In all other cases Gantry offers to restart the services.

**Why this priority**: Today the user sees a raw error and thinks that Gantry is broken. A Homebrew build of 1.7.1 without the cluster services is a known, common setup.

**Independent Test**: Give the diagnosis a failed cluster command and a fake tool layout (Homebrew without the plugin, package without the plugin, complete install). Check the message and the action for each layout. In the app, open Clusters on a host where the cluster services fail.

**Acceptance Scenarios**:

1. **Given** a Homebrew install of version 1.7.1 that has no cluster service plugin, **When** a cluster command fails with "cluster service unavailable", **Then** the Clusters section shows "This Homebrew build of container 1.7.1 lacks the cluster services. Install the signed package from github.com/apple/container/releases." and a button that opens the releases page.
2. **Given** a complete install, **When** a cluster command fails with the same error, **Then** the Clusters section says that the cluster services are not running and offers the existing Restart Services action with its confirmation.
3. **Given** the notice is visible, **When** a later cluster list works, **Then** the notice goes away.
4. **Given** the cluster services are unavailable, **When** the user opens Create Cluster, **Then** the sheet shows the same notice.
5. **Given** the cluster services are unavailable, **When** the user opens a Kubernetes flow for a cluster of the container tool, **Then** Gantry shows the same notice.

---

### User Story 2 - Edit the DNS defaults for new containers (Priority: P2)

A user wants every new container to use specific name servers, search domains or resolver options. Version 1.7.0 and later read these defaults from the `[container.dns]` table of the user's config file. The user opens the System properties pane, sees the current lists, and adds or removes rows. Gantry writes the change. All other content of the file stays the same.

**Why this priority**: It is a new user-visible setting of 1.7. Without it the user must edit the file by hand.

**Independent Test**: Load a config file with comments, unknown keys and DNS lists. Change one list. Check that only that list changed. In the app, open System, Properties on a 1.7.1 host and edit a list.

**Acceptance Scenarios**:

1. **Given** a host with version 1.7.0 or later, **When** the user opens System properties, **Then** the pane shows the name servers, search domains and options of `[container.dns]`.
2. **Given** a host with version 1.6.1, **When** the user opens System properties, **Then** the pane does not show these keys, unless the file already holds them.
3. **Given** the list editor is open, **When** the user adds a row with a space, a comma or a duplicate value, **Then** Gantry marks the row as not valid and does not save.
4. **Given** the user removes all rows of a list, **When** the user saves, **Then** Gantry removes the key from the file.
5. **Given** the file has comments and keys that Gantry does not know, **When** Gantry saves a list, **Then** the comments and the other keys stay the same.

---

### User Story 3 - See the CPU use that the container tool reports (Priority: P2)

A user looks at the CPU percentage of a running container. Version 1.7 reports its own CPU utilization value. Gantry shows that value when it is present. With older versions, Gantry calculates the value as before.

**Why this priority**: The value from the tool is more accurate, and the first sample is no longer empty.

**Independent Test**: Decode stats output from a live 1.7.1 run and from 1.6.1. Check the CPU percentage for each.

**Acceptance Scenarios**:

1. **Given** stats output with a CPU utilization of 0.5, **When** Gantry shows the container, **Then** the CPU value is 50 % (1.0 is one full core).
2. **Given** stats output without the value, **When** Gantry shows the container, **Then** Gantry calculates the value from the CPU counters as before.
3. **Given** the value is negative, not a number, or not numeric, **When** Gantry reads it, **Then** Gantry ignores it and uses the calculation.

---

### User Story 4 - Install the kernel that the tool recommends (Priority: P3)

A user installs the recommended kernel from the Kernel pane. The recommended kernel in 1.7.1 changed. Gantry must install the kernel that the installed tool recommends, not a fixed old version.

**Why this priority**: A fixed version would install an old kernel. The check is small.

**Independent Test**: Read the kernel properties of a live 1.7.1 run. Check that the install action asks the tool for its recommended kernel and has no version of its own.

**Acceptance Scenarios**:

1. **Given** version 1.7.1, **When** the user selects Install Recommended Kernel, **Then** the tool installs the kernel from its own kernel properties.

---

### User Story 5 - Know when the builder image is old (Priority: P3)

A user has a builder that was made with an older builder image. Version 1.7.1 ships a newer image. Gantry tells the user that the builder image is old and offers to recreate the builder.

**Why this priority**: It came out of the review of all 1.7.1 changes. It prevents builds with an old builder.

**Independent Test**: Compare a configured image and a running image with the same rule that the tool uses. Check the card in the Builder pane.

**Acceptance Scenarios**:

1. **Given** the builder runs image 0.13.2 and the tool expects 0.13.3, **When** the user opens the Builder pane, **Then** the pane shows "Builder image is outdated" and a Recreate Builder button with a confirmation.

---

### Edge Cases

- The command path is a symbolic link. Gantry must resolve it before it examines the install layout.
- The Homebrew version has a bottle revision, for example `1.7.1_1`. The message shows `1.7.1`.
- The error is the bare XPC text "Connection invalid", not "cluster service unavailable".
- A package install has a plugin folder, but one cluster plugin is absent.
- A DNS list is written over several lines, has a comment after the closing bracket, or has a comment inside the brackets.
- A DNS key holds a value that is not a list of strings.
- Removing the last list key leaves an empty `[container.dns]` table header.
- Stats rows for cluster node containers appear in the output, but these containers are not in the container list.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Gantry MUST recognize the "cluster service unavailable" error and the bare "Connection invalid" error from cluster commands.
- **FR-002**: Gantry MUST find the install layout of the command (Homebrew or package) after it resolves symbolic links.
- **FR-003**: When a Homebrew install has no `container-core-clusters` plugin (or no `cluster-hoststore` plugin), Gantry MUST show the Homebrew message with the version and a button that opens the releases page.
- **FR-004**: When a package install has no cluster plugin, Gantry MUST show the same advice without a version.
- **FR-005**: In all other cases Gantry MUST offer the existing Restart Services action with its confirmation.
- **FR-006**: Gantry MUST show the notice in the Clusters section, in Create Cluster and in the Kubernetes flows for clusters of the container tool. Gantry MUST remove the notice after a cluster list works.
- **FR-007**: Gantry MUST show and edit the `[container.dns]` keys `nameservers`, `searchDomains` and `options` as lists of strings, only when the tool version is 1.7.0 or later, or when the file or the services already hold them.
- **FR-008**: Gantry MUST check each list row: trim it, refuse spaces and commas, refuse duplicates, and require an IP address for name servers.
- **FR-009**: Gantry MUST keep comments, unknown keys and all other values of the config file when it writes a list. Gantry MUST refuse to write when it cannot do so safely, and it MUST tell the user why.
- **FR-010**: Gantry MUST remove a list key when the user saves an empty list.
- **FR-011**: Gantry MUST use the CPU utilization value from the stats output when it is present and valid. Gantry MUST keep the old calculation as a fallback.
- **FR-012**: Gantry MUST install the recommended kernel through the tool and MUST NOT hold a kernel version of its own.
- **FR-013**: Gantry MUST tell the user when the running builder image differs from the image that the tool expects, and offer to recreate the builder with a confirmation.
- **FR-014**: The automation tool for agents MUST accept list values for the DNS keys.
- **FR-015**: All new features MUST be gated on the tool version, so that 1.6.1 keeps working as before.
- **FR-016**: Every other change from 1.6.1 to 1.7.1 MUST be reviewed for user-visible effect, and the result MUST be written down.
- **FR-017**: All new user-facing text MUST be localizable.

### Key Entities

- **Cluster service problem**: the kind of failure (Homebrew build without plugins, package without plugins, services not running), the version, and the action to offer.
- **DNS defaults**: three lists of strings (name servers, search domains, options) in the user's config file.
- **Container load sample**: the CPU percentage of one container, from the tool value or from the counters.
- **Builder image state**: the configured image and the image that the tool expects.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On a Homebrew 1.7.1 install without the cluster services, the user sees the cause and the fix in the Clusters section in less than 5 seconds, with no raw error text.
- **SC-002**: A user can add a name server to the DNS defaults in less than 30 seconds without opening a text editor.
- **SC-003**: In 100 % of the round-trip tests, a write to the config file changes only the edited key.
- **SC-004**: The CPU value of a running container is shown from the first sample on 1.7.1.
- **SC-005**: All existing behaviour on 1.6.1 stays the same. All existing tests pass.

## Assumptions

- The installed tool for live checks is 1.7.1. Live checks are read-only. No services are stopped and no containers or clusters are created or deleted.
- The cluster changes of PR #50 are on main and stay out of scope.
- The tag 1.7.1 source in `/Volumes/SanDisk2Tb/builds/gantry-027/ac17/upstream/c171` is the reference for key names and output shapes.
- Translations into the other UI languages are done by the maintainer after the English text is final.
- The other open upstream items (label filter, network MTU, `cluster create --retain`) are not merged upstream and stay out of scope.
