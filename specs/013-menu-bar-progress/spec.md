<!-- STE deviation: spec-kit template headings, the quoted user input, Given-When-Then scenarios, product names, file system names and paths stay verbatim. -->
# Feature Specification: Progress of Pull, Build and Compose in the Menu Bar

**Feature Branch**: `feat/menu-bar-progress`

**Created**: 2026-11-14

**Status**: Implemented. The live check without GUI control is done; the GUI check is open.

**Input**: User description: "Show running long operations (image pull, build, compose up/down/pull) in the MenuBarExtra with progress (bytes/layers or steps), elapsed time, Cancel, and a notification on finish or failure using the existing notification actions. The menu bar icon shows activity while something runs. Reuse the existing OperationCenter/LongOperation activity model. Logic in AppCore with tests. Live Activities out of scope: ActivityKit in the macOS 27.2 SDK is @available(macOS, unavailable)."

## Context

Gantry has an Activity list in the main window toolbar. It shows long operations: pulls,
builds, Compose up, bulk actions, installs. The menu bar panel does not show them. A user
who closes the main window, or who uses Gantry as a menu bar app only, cannot see that a
pull still runs, how far it is, or stop it.

Today an operation has only a text line and an optional fraction. The pull sheet knows the
layers and the bytes, but the Activity list gets only the last status line. A build and
Compose up have no fraction.

In the container list, a user can only stop or restart all containers of a Compose group.
Compose down exists only as a Shortcuts action (`ComposeDownIntent`), without progress.
Compose pull does not exist. This feature adds the two actions on the Compose group header,
because the menu bar must show them as operations.

Live Activities: in the macOS 27.2 SDK, every ActivityKit API is marked
`@available(macOS, unavailable)`. This feature does not use them.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See running operations in the menu bar (Priority: P1)

The user starts an image pull and closes the main window. The user opens the Gantry menu
bar panel. The panel shows an Activity section with the pull: its title, its host, a
progress bar, the layers done of all layers, the bytes done of all bytes, and the elapsed
time. A build shows its steps ("Step 3 of 7"). Compose up, Compose down and Compose pull show
their services or items done of all.

**Why this priority**: This is the core of the feature. Without it, the other stories have
no place to show.

**Independent Test**: Start a pull of a large image on a host. Open the menu bar panel.
The Activity section shows the pull with layers, bytes and a time that goes up.

**Acceptance Scenarios**:

1. **Given** a pull runs, **When** the user opens the menu bar panel, **Then** the panel shows the pull with a progress bar, "Layers: N of M", "X of Y" bytes and the elapsed time.
2. **Given** a build runs, **When** the build output reports steps, **Then** the panel shows "Step N of M" and a progress bar with that fraction.
3. **Given** no operation runs and none finished recently, **When** the user opens the panel, **Then** the panel shows no Activity section.
4. **Given** two operations run on two hosts, **When** the user opens the panel, **Then** the panel shows both, the newest first, each with its host name.

---

### User Story 2 - Cancel an operation from the menu bar (Priority: P1)

The user sees a pull that takes too long and clicks Cancel in the menu bar panel. The pull
stops. The row shows "Stopping…" and then "Cancelled". An operation that asks before it
stops (Compose up) asks in the panel, not in an alert, because an alert closes the panel.

**Why this priority**: The brief asks for Cancel. A progress row without Cancel forces the
user to open the main window.

**Independent Test**: Start a pull, click Cancel in the panel, and read the state of the
operation with `gantry-ctl` or in the Activity list.

**Acceptance Scenarios**:

1. **Given** a pull runs, **When** the user clicks Cancel in the panel, **Then** the pull stops and the row shows that it was cancelled.
2. **Given** Compose up runs, **When** the user clicks Cancel, **Then** the row asks "Stop" or "Keep Running" in place, and only "Stop" cancels.
3. **Given** an operation cannot be cancelled, **When** the user looks at its row, **Then** the row has no Cancel button.

---

### User Story 3 - The menu bar icon shows activity (Priority: P2)

While an operation runs, the menu bar item shows the number of running operations next to
the Gantry icon. When all operations end, the number goes away.

**Why this priority**: The user sees that work runs without opening the panel.

**Independent Test**: Start a pull. The menu bar item shows "1". Cancel it. The number goes
away.

**Acceptance Scenarios**:

1. **Given** no operation runs, **When** the user looks at the menu bar, **Then** the item shows only the Gantry icon.
2. **Given** two operations run, **When** the user looks at the menu bar, **Then** the item shows the icon and "2".
3. **Given** VoiceOver is on, **When** VoiceOver reads the menu bar item, **Then** it reads "Gantry" and the number of running operations.

---

### User Story 4 - A notification when an operation ends (Priority: P2)

When a pull, build or Compose operation ends while Gantry is not the front app, Gantry posts
a notification: "Done: …" or "Failed: …". The notification has the existing Show action. A
click or Show opens the Activity list. A cancel by the user posts nothing.

**Why this priority**: The user does not have to watch the panel. Gantry has this today for
operations in the main window; it must also be true for Compose down and Compose pull.

**Independent Test**: Start Compose pull, switch to another app, wait for the end. A
notification comes with the Show action.

**Acceptance Scenarios**:

1. **Given** Gantry is in the background, **When** a build fails, **Then** a notification "Failed: Build …" comes with the Show action.
2. **Given** the user cancelled the operation, **When** it ends, **Then** no notification comes.

---

### User Story 5 - Compose down and Compose pull on a Compose group (Priority: P3)

In the container list, the header of a Compose group has two more actions: Pull Images and
Compose Down. Pull Images pulls the image of each service again. Compose Down asks first with
the shared confirmation, then removes the containers of the project and the networks that
the project made. Both run as operations with per-item progress.

**Why this priority**: The brief lists Compose down and pull. They are new actions, so they
come after the menu bar parts.

**Independent Test**: Run Compose up for a two-service project, then Pull Images, then
Compose Down. Each shows in the Activity list and in the panel with "N of M". After Down, the
project has no containers and no project networks.

**Acceptance Scenarios**:

1. **Given** a Compose group with two services, **When** the user clicks Pull Images, **Then** an operation "Compose pull <project>" runs with "N of 2" progress.
2. **Given** a Compose group, **When** the user clicks Compose Down, **Then** the shared confirmation lists the project and the running containers that stop.
3. **Given** the user confirms Compose Down, **When** it ends, **Then** the containers of the project and its networks are removed, and named volumes stay.
4. **Given** an apple/container host, **When** the user runs Compose Down, **Then** it works the same; networks that the host does not support are skipped.

### Edge Cases

- A pull reports no byte counts (apple/container, or a cached layer): the row shows the layer count and an indefinite bar.
- A build output has no step lines: the row shows the last output line and an indefinite bar.
- Many operations run: the panel shows at most five running rows and a "Show All" link to the Activity list.
- An operation finishes while the panel is open: the row changes to Done, Failed or Cancelled and stays until the user dismisses it or for up to 10 minutes.
- The user cancels twice: the second click does nothing.
- A host disconnects during an operation: the operation fails with the error, the row shows Failed.
- The image of a Compose service has no tag (it was built locally): Pull Images skips it and the summary counts it as skipped.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The menu bar panel MUST show an Activity section when at least one operation runs or finished in the last 10 minutes.
- **FR-002**: Each running row MUST show the title, the host, a progress bar (determinate when the fraction is known), a detail line, the elapsed time, and Cancel when the operation can be cancelled.
- **FR-003**: An operation MUST be able to report structured progress: items done of a total with a unit (layers, steps, services, items) and bytes done of a total.
- **FR-004**: An image pull MUST report layers done of all layers and the sum of bytes of the layers that report sizes.
- **FR-005**: A build MUST report "step N of M" when the output has BuildKit (`#N [x/y]`) or classic (`Step x/y :`) step lines.
- **FR-006**: Compose up MUST report services started of all services.
- **FR-007**: Cancel in the panel MUST use the same cancel path as the Activity list. An operation with a cancel confirmation MUST ask in the row.
- **FR-008**: The menu bar item MUST show the count of running operations next to the icon while one runs, and its accessibility label MUST name the count.
- **FR-009**: The end of an operation MUST post the existing operation notification with the Show action, for all operation kinds of this feature, and MUST NOT post for a cancel.
- **FR-010**: The Compose group header MUST offer Pull Images and Compose Down. Compose Down MUST use the shared destructive confirmation.
- **FR-011**: Compose Down MUST stop each container of the project gracefully, then remove it, then remove the networks with the project label. It MUST NOT remove volumes or images.
- **FR-012**: All new user-facing strings MUST be in the String Catalogs with all 28 languages.
- **FR-013**: The Activity section MUST work the same for Docker hosts and apple/container hosts.

### Key Entities

- **Long operation**: one unit of long work (existing). It gets structured progress: item progress (done, total, unit) and byte progress (done, total).
- **Menu bar activity summary**: what the menu bar shows: the visible running rows, the recent finished rows, the hidden count, and the running count for the icon.
- **Pull progress tracker**: folds the per-layer lines of a pull into layers done, layers total, bytes done and bytes total.
- **Build step parser**: reads build output lines and finds the current step and the step total.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user can see the progress and the elapsed time of a running pull in two clicks or fewer, with the main window closed.
- **SC-002**: A user can cancel a running pull from the menu bar in two clicks or fewer.
- **SC-003**: The menu bar item shows a running operation within one second after it starts.
- **SC-004**: All new logic has automatic tests; the localization check reports 0 problems.

## Assumptions

- "Recent" finished operations are the ones that finished in the last 10 minutes; at most three show.
- The notification rule stays as it is today: Gantry posts only when it is not the front app, so the user does not get a banner for work that the user watches.
- The menu bar item shows a number, not an animation, because a menu bar label shows only an image and text, and status must not be shown by color only.
- Compose down does not remove images or volumes (the default of `docker compose down`).
- Compose pull pulls the image tag that each container of the project uses; it does not read the Compose file again.
- Live Activities are out of scope: the macOS 27.2 SDK marks ActivityKit unavailable on macOS.
