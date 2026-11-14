<!-- STE deviation: spec-kit template headings, the quoted user input, Given-When-Then scenarios (long, condition in the middle), product names such as apple/container, file system names and paths stay verbatim. -->
# Feature Specification: Fleet Activity Table

**Feature Branch**: `feat/fleet-activity`

**Created**: 2026-11-14

**Status**: Draft

**Input**: User description: "Fleet activity table: one sortable table of all running containers across all connected hosts (Docker and Apple container): host, name, image, CPU %, memory, network IO, block IO, uptime. Sort by any column, filter by host and text, live refresh with the existing stats sampling, open a row to the container. Reachable from the sidebar and the ⌘K palette. Handle unreachable hosts in the existing error model. Data aggregation and sorting logic in AppCore with tests. An MCP tool for the same snapshot if it is small."

## Context

Today a user sees the load of containers for only one host at a time. The host Overview shows the top containers. The Stats tab shows one container. A user with several hosts cannot find the container that uses the most CPU or memory in the whole fleet. Each connected host already samples the load of its running containers every 5 seconds for the dashboard. This feature shows those samples for all hosts in one table. Activity Monitor shows processes on a Mac in the same way.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See the load of all running containers in one table (Priority: P1)

A user has a local apple/container host and one or more Docker hosts. The user selects "Resource Usage" in the sidebar. One table shows each running container of each connected host. The columns are host, name, image, CPU, memory, network I/O, disk I/O and uptime. The values update while the table is open, without a manual refresh.

**Why this priority**: This is the feature. Without it, sort, filter and navigation have no data.

**Independent Test**: Connect an apple/container host with two running containers and a Docker host with one running container. Open Resource Usage. The table has three rows. After 10 seconds, the CPU and memory values of a busy container change.

**Acceptance Scenarios**:

1. **Given** two connected hosts with running containers, **When** the user opens Resource Usage, **Then** the table has one row for each running container of each host, and each row names its host.
2. **Given** the table is open, **When** a host takes a new load sample, **Then** the values of that host's rows change in the same table, and the selection and the sort order stay.
3. **Given** a container that started less than 5 seconds ago, **When** it shows in the table, **Then** its metric cells show a dash until the first sample arrives.
4. **Given** a stopped container, **When** the user opens the table, **Then** the container is not in the table.
5. **Given** the apple BuildKit builder or a Gantry debug sidecar runs, **When** the user opens the table, **Then** these containers are not in the table, the same as in the Containers list.

---

### User Story 2 - Sort and filter the table (Priority: P1)

The user clicks a column header to sort by that column. A second click reverses the order. A search field filters the rows by name, image or host. A host menu limits the rows to one host.

**Why this priority**: "Which container uses the most CPU in the fleet?" is the main question. Sort answers it.

**Independent Test**: With rows from two hosts, sort by CPU descending: the busiest container is the first row. Type part of an image name: only matching rows stay. Pick one host in the host menu: only that host's rows stay.

**Acceptance Scenarios**:

1. **Given** the table, **When** the user clicks the CPU header, **Then** the rows sort by CPU, and the next click reverses the order.
2. **Given** rows without a sample yet, **When** the user sorts by any metric column, in either order, **Then** these rows are at the end.
3. **Given** two rows with the same value in the sort column, **When** the values update, **Then** the two rows keep their order (the tie order is by host name, then container name).
4. **Given** the search text "redis", **When** the user types it, **Then** only rows whose name, image or host contains "redis" (any letter case) stay.
5. **Given** the host menu set to one host, **When** the user types a search text too, **Then** both filters apply.
6. **Given** filters that match no row, **When** the table is empty, **Then** an empty state says that no container matches and offers to clear the filters.

---

### User Story 3 - Open a container from the table (Priority: P2)

The user double-clicks a row, or selects it and presses Return. Gantry opens the Containers section of that host with the container selected. A context menu on a row has "Show in Containers", "Show Stats" and "Copy Name".

**Why this priority**: The table finds the container; the user then wants to act on it with the tools that already exist.

**Independent Test**: Double-click a row of the apple/container host. The sidebar selects that host's Containers section, and the detail column shows that container.

**Acceptance Scenarios**:

1. **Given** a row of host A, **When** the user double-clicks it, **Then** the Containers section of host A opens with that container selected.
2. **Given** a selected row, **When** the user presses Return, **Then** the same happens.
3. **Given** a row, **When** the user chooses "Show Stats" in its context menu, **Then** the container opens on its Stats tab.

---

### User Story 4 - Hosts that are not connected (Priority: P2)

Some hosts are down, connecting or disconnected. The table shows the rows of the connected hosts. Above the table, one line for each host that is not connected tells its state and has a Retry button for a failed or disconnected host. The table never shows a modal error alert.

**Why this priority**: Constitution principle III and the 0.26 error model: a missing or failed host explains itself and does not break the rest of the screen.

**Independent Test**: Add an SSH host that cannot connect. Open the table. The rows of the other hosts show, and one line says that the SSH host failed, with the reason and a Retry button.

**Acceptance Scenarios**:

1. **Given** a failed host, **When** the user opens the table, **Then** a line shows the host name, "Connection failed", the reason and a Retry button, and the other hosts' rows show.
2. **Given** a host that is connecting, **When** the user opens the table, **Then** a line shows "Connecting…" for that host, with no Retry button.
3. **Given** no host is connected, **When** the user opens the table, **Then** an empty state says that no host is connected, and the host lines show.
4. **Given** connected hosts without running containers, **When** the user opens the table, **Then** an empty state says that no container runs.

---

### User Story 5 - Open the table from the command palette and a link (Priority: P3)

The user presses ⌘K and types "usage" or "activity". The palette shows "Resource Usage". Return opens it. A script opens it with `gantry://open/usage`.

**Why this priority**: The palette is the fast way to every place in the app.

**Independent Test**: `scripts/gantry-ctl open/usage`, then `scripts/gantry-ctl state`: the selection is the Resource Usage item.

**Acceptance Scenarios**:

1. **Given** the palette, **When** the user types "activity", **Then** "Resource Usage" is in the results.
2. **Given** the link `gantry://open/usage`, **When** it arrives, **Then** the main window shows the table and the palette closes.

---

### User Story 6 - The same snapshot for an AI agent (Priority: P3)

An agent that uses the Gantry MCP server calls the tool `fleet_activity`. It gets one JSON list of the running containers of all hosts (or one host), with the same columns, sorted by the column that it asks for, and one error entry for each host that it cannot reach.

**Why this priority**: Agents already have `container_stats` for one container; this tool answers the fleet question in one call. It is useful but not necessary for the app.

**Independent Test**: Call `fleet_activity` with `sort: "memory"` against a test host with two running containers. The result has two rows, the larger memory first.

**Acceptance Scenarios**:

1. **Given** two hosts, one down, **When** the agent calls `fleet_activity`, **Then** the result has the rows of the up host and an error entry for the down host.
2. **Given** `limit: 5`, **When** more than 5 containers run, **Then** the result has 5 rows.

---

### Edge Cases

- A container stops between two samples: its row goes away at the next container list refresh.
- A container restarts: its counters go down; the network and disk rates show 0 for that sample, not a negative value.
- Two hosts have containers with the same name: the rows are different, because each row is identified by host and container id.
- A host is removed while the table is open: its rows and its host line go away. When the host menu was set to that host, the filter goes back to all hosts.
- Docker reports uptime as text ("Up 3 hours", "Up About a minute"); the uptime is approximate to the unit that Docker gives. apple/container gives the start date; Gantry shows the uptime from it.
- A very long container or image name: the cell truncates in the middle and the full text shows in the help tag.
- Many containers (more than 200): the table stays responsive, because it shows only data that is already in memory.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The app MUST show a "Resource Usage" item in the sidebar, under Dashboard, that opens the fleet activity table.
- **FR-002**: The table MUST have one row for each user-visible running container of each connected host, from Docker hosts and apple/container hosts.
- **FR-003**: Each row MUST show host, container name, image, CPU (100 % = one core), memory used, network I/O (received and sent per second), disk I/O (read and written per second) and uptime.
- **FR-004**: The values MUST come from the load samples that each host already takes (one sample every 5 seconds). The table MUST NOT open extra stats streams.
- **FR-005**: A row without a sample MUST show a dash in its metric cells, and MUST sort after all rows with a value, in both sort orders.
- **FR-006**: The user MUST be able to sort by each column, in both orders. The default sort is CPU, highest first. Ties MUST sort by host name, then by container name, then by container id.
- **FR-007**: The user MUST be able to filter by text (name, image, host; any letter case) and by host (all hosts or one host). The filters MUST combine.
- **FR-008**: Double-click or Return on a row MUST open the Containers section of the row's host with the container selected. The row context menu MUST have Show in Containers, Show Stats and Copy Name.
- **FR-009**: For each host that is not connected, the screen MUST show its name and state (Connecting…, Connection failed with the reason, or Disconnected). Failed and disconnected hosts MUST have a Retry button. The screen MUST NOT show a modal alert.
- **FR-010**: The command palette MUST list "Resource Usage" (search terms include "activity", "top", "stats", "cpu", "memory"). The link `gantry://open/usage` MUST open it.
- **FR-011**: apple/container hosts MUST report the uptime of a running container. Gantry MUST get it from the start date that the `container` CLI reports.
- **FR-012**: The MCP server MUST have a read-only tool `fleet_activity` with the optional arguments `host_id`, `sort` (a column name), `ascending` and `limit`. It returns rows with the same fields and one error entry for each host that it cannot reach.
- **FR-013**: Every new user-facing string MUST be in the String Catalogs with translations for all 28 UI languages.
- **FR-014**: Each metric cell MUST have an accessibility value that says the metric and its value. Status MUST NOT be shown by color only.

### Key Entities

- **Activity row**: one running container on one host: host id and name, host kind, container id, name, image, the latest load point (CPU, memory, network in and out rates, disk read and write rates) or none, and the uptime in seconds or none.
- **Unavailable host**: a host that is not connected: host id, name, and its state (connecting, failed with a reason, disconnected).
- **Activity snapshot**: the rows and the unavailable hosts at one instant.
- **Sort**: a column and an order.
- **Filter**: a text and an optional host id.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user with three hosts finds the container with the highest CPU in the fleet in at most two actions (open the table, and if necessary click the CPU header).
- **SC-002**: The values in the table are never more than 10 seconds older than the last load sample of their host.
- **SC-003**: With 200 running containers, a sort or a filter change shows its result in less than 0.5 seconds.
- **SC-004**: A failed host never hides the rows of the other hosts, and never opens an alert.
- **SC-005**: The localization check reports 0 problems for the new strings in all 28 languages.

## Assumptions

- The name "Resource Usage" is used for the sidebar item and the window title, because "Activity" already names the operations list in the toolbar.
- Network and disk I/O show rates (bytes per second), the same as the dashboard and the Overview cards, and not cumulative totals.
- Kubernetes pods are out of scope: the Kubernetes section has its own browser and no load samples.
- Paused containers are not in the table: they use no CPU, and the Containers list already shows them.
- The table refreshes on the host's existing 5-second sample. The sample interval does not change.
- The MCP tool takes its own two samples one second apart, because the MCP server is a separate process without the app's history.
