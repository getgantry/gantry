<!-- STE deviation: spec-kit template headings, the quoted user input, Given-When-Then scenarios, product names, Apple design terms and paths stay verbatim. -->
# Feature Specification: Apple HIG and Liquid Glass Design Pass

**Feature Branch**: `feat/hig-design-pass`

**Created**: 2026-11-07

**Status**: In Progress (implementation started before spec-kit adoption on 2026-11-07)

**Input**: User description: "The UI looks empty. Make it follow Apple's Human Interface Guidelines for macOS 26 and 27 (Liquid Glass). Use the space with live charts, richer cards, rows and detail panes. Never truncate toolbar text. Add the Kubernetes section to the command palette." Source brief: `/Volumes/SanDisk2Tb/builds/gantry-027/hig.md`. Audit: `/Volumes/SanDisk2Tb/builds/gantry-027/hig/SPEC.md`.

## Context

The screenshots of every section (`/Volumes/SanDisk2Tb/builds/gantry-027/hig/01-dashboard.png` to `10-clusters.png`) show four problems. Small cards sit in big empty windows. Detail panes show plain label and value text. List rows are sparse. Toolbar buttons have cut text ("Brow…", "Write…", "Copy ku…", "Delet…"). The audit in `hig/SPEC.md` lists the HIG rules (R1 to R13) and the change for each screen.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See the state of a host at a glance (Priority: P1)

A user opens the Dashboard or the Overview of a host. The window shows live charts for CPU, memory, network and disk with a short history. It shows the containers that use the most resources, the recent operations, and quick actions. The cards fill the window width.

**Why this priority**: The Dashboard and the Overview are the first screens that a user sees. They look the most empty today.

**Independent Test**: Open the Dashboard and the Overview of a host with running containers. Make the window wide and narrow. Check that the charts update and the grid adapts.

**Acceptance Scenarios**:

1. **Given** a host with running containers, **When** the user opens Overview, **Then** four chart cards (CPU, Memory, Network, Disk I/O) show the current value, the average and the peak of the last 10 minutes.
2. **Given** the window is wide, **When** the user opens the Dashboard, **Then** the host cards fill the width in an adaptive grid.
3. **Given** a host with running containers, **When** the user opens Overview, **Then** a card lists the top containers by CPU, each with a small chart, CPU and memory.
4. **Given** operations ran in the last minutes, **When** the user opens the Dashboard, **Then** a card shows the last operations with status and time.
5. **Given** VoiceOver is on, **When** the focus is on a chart, **Then** VoiceOver reads the title, the current value and the summary.

---

### User Story 2 - Use toolbar actions with no cut text (Priority: P1)

A user opens the detail of a cluster, a machine or a Kubernetes resource. The actions are icon-only toolbar items with help text, or a primary action and a More menu. No text is cut at any normal window width.

**Why this priority**: Cut text is a visible defect and breaks constitution principle I.

**Independent Test**: Open each detail pane at the minimum window width. Check that no toolbar or header text is cut.

**Acceptance Scenarios**:

1. **Given** the cluster detail, **When** the window is at its minimum width, **Then** Browse Resources is an icon with help text, and Write Kubeconfig, Copy kubectl Context Command and Delete are in a More menu.
2. **Given** the machine detail, **When** the user looks at the toolbar, **Then** Shell, Start or Stop, and Set Default are icon items with help text.
3. **Given** a toolbar action moved, **When** the user looks for it in the context menu or the command palette, **Then** the action is still there.

---

### User Story 3 - Read richer lists and detail panes (Priority: P2)

A user looks at the Containers list. Each row shows a state symbol, the name, the image, a status line, port tags, and for running containers a CPU chart with CPU and memory values. Detail panes show grouped sections with headers, monospaced IDs and copy buttons.

**Why this priority**: Lists and details are used all the time, but they work today.

**Independent Test**: Open Containers with running and stopped containers. Open a container detail and copy an ID.

**Acceptance Scenarios**:

1. **Given** a running container with 5 published ports, **When** the user looks at its row, **Then** the row shows 3 port tags and "+2".
2. **Given** a detail pane, **When** the user selects the copy button next to an ID, **Then** the ID is on the clipboard.
3. **Given** any status badge, **When** the user looks at it, **Then** the status has a symbol and a text, not only a color.

---

### User Story 4 - Start from a useful empty state (Priority: P2)

A user opens an empty section. The section shows a short explanation and the actions to start, for example Quick Run, New Container and Pull Image in Containers.

**Why this priority**: New users see empty sections first.

**Independent Test**: Open each section on a host with no objects.

**Acceptance Scenarios**:

1. **Given** a host with no containers, **When** the user opens Containers, **Then** the empty state offers Quick Run, New Container and Pull Image.

---

### User Story 5 - Open Kubernetes from the command palette (Priority: P3)

A user presses Command-K and types "Kubernetes". The palette shows the Kubernetes section and one item for each Kubernetes context.

**Why this priority**: It is a small bug fix.

**Independent Test**: Open the palette, type "kube", and run each item.

**Acceptance Scenarios**:

1. **Given** the palette is open, **When** the user types "Kubernetes", **Then** the Kubernetes section is in the results.
2. **Given** two contexts exist, **When** the user selects one context item, **Then** Gantry opens Kubernetes with that context.

---

### Edge Cases

- One host only: the Dashboard grid has one full-width column.
- A container restarts and its counters go back to zero.
- A container is removed while its history is in the chart.
- Increase Contrast is on: cards get a visible border.
- Reduce Transparency is on, light mode, dark mode.
- No operations ran yet: the activity card shows a short text.
- A host type has no paused state.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Gantry MUST keep a bounded history of CPU, memory, network and disk values for each host and each running container.
- **FR-002**: Gantry MUST calculate rates from counter differences and handle a counter reset with no negative values.
- **FR-003**: Each chart MUST show a title, the current value, and the average and peak. Each chart MUST have an accessible label and value.
- **FR-004**: CPU and memory charts MUST use a fixed 0 to 100 % range. Network and disk charts MUST use a dynamic range from 0.
- **FR-005**: The Dashboard and Overview MUST use an adaptive grid that fills the window width.
- **FR-006**: Text in a toolbar or a button MUST never be cut. Detail actions MUST be icon-only items with help text, or a primary action and a More menu.
- **FR-007**: Every action moved to the toolbar MUST stay in its context menu and in the command palette.
- **FR-008**: List rows MUST show a state symbol, the name, a secondary line and a status badge. Rows for running containers MUST show a CPU chart, CPU and memory.
- **FR-009**: Detail panes MUST use grouped sections with headers. IDs, versions, hashes and paths MUST be monospaced with a copy button.
- **FR-010**: Each empty section MUST show a short explanation and at least one useful action.
- **FR-011**: The command palette MUST have a Kubernetes section item and one item for each Kubernetes context.
- **FR-012**: Liquid Glass MUST be used only for floating controls, not for content.
- **FR-013**: The UI MUST look right in light and dark mode, with Reduce Transparency and with Increase Contrast.
- **FR-014**: Status MUST never be shown by color only. Every icon-only control MUST have a label.
- **FR-015**: The behaviour of every action MUST stay the same.
- **FR-016**: APIs from macOS 27 MUST be behind availability checks with a working fallback on macOS 26.
- **FR-017**: All new user-facing text MUST be localizable. Counts MUST use plural variations.

### Key Entities

- **Load sample**: one point in time with CPU, memory, network rate and disk rate for a host.
- **Container load history**: a bounded series of points for one container.
- **Metric summary**: the latest value, the average and the peak of a series.
- **Palette item**: a command palette entry for a section or a Kubernetes context.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: At a window width of 1100 points, the Dashboard and the Overview leave no empty area larger than one card.
- **SC-002**: At the minimum window width, 0 toolbar or header labels are cut in any section.
- **SC-003**: A user finds the most CPU-intensive container of a host in less than 5 seconds from the Overview.
- **SC-004**: Every section has before and after screenshots in light and dark mode.
- **SC-005**: All existing tests pass and no action changes its behaviour.

## Assumptions

- The minimum stays macOS 26. The audit found no macOS 27 API that is needed.
- The views of the Kubernetes browser and the System properties logic are also changed by other branches (`feat/kubernetes-native`, `feat/apple-container-1-7-1`). This branch changes only their presentation.
- The Kubernetes context items in the palette use the contexts that the Kubernetes browser knows.
- Translations into the other UI languages are done by the maintainer after the English text is final.
