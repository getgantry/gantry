<!-- STE deviation: spec-kit template headings, the quoted user input, Given-When-Then scenarios, product names, menu titles, keyboard shortcuts and paths stay verbatim. -->
# Feature Specification: Export Container Logs with the Current Filter

**Feature Branch**: `feat/log-export`

**Created**: 2026-11-14

**Status**: Draft

**Input**: User description: "Export the logs that the log view shows, respecting the current filter/search, time range and timestamps toggle, to a .log or .txt file via the standard save panel (fileExporter), plus Copy Visible Lines. Works for containers on Docker and Apple hosts and compose projects if the log view supports them. Large logs must stream to the file, not build one huge string in memory. Formatting/filter logic in AppCore with tests. Add the action to the palette and to the menu with a shortcut that follows HIG."

## Context

Gantry has two log views:

- The Logs tab of one container (`LogsView`). It has a level filter, a search field with "show only matching lines", Pause, Clear and Copy all.
- The stack logs sheet of a Compose project (`StackLogsView`). It merges the logs of all services. It has a level filter, a search filter and a menu that shows or hides each service.

Today the views do not have a timestamps toggle or a time range. Docker hosts send a timestamp with each line, but the views do not show it. Apple `container` hosts do not send timestamps, because `container logs` cannot add them. The views keep at most 50 000 lines.

This feature adds a timestamps toggle and a time range to both views, and adds export and copy of the visible lines.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Export the visible log lines to a file (Priority: P1)

A user debugs a container. The user sets the level filter to "Warn and up" and types "timeout" in the search field with "show only matching lines" on. The user clicks Export Logs. The standard save panel opens with the name `<container>-<date>-<time>.log`. The user saves. The file has the same lines that the view shows, in the same order, as plain text with no color codes.

**Why this priority**: This is the main value: the user can attach a log to an issue or send it to a colleague.

**Independent Test**: Start a container that writes known lines, set a filter, export, and compare the file with the visible lines.

**Acceptance Scenarios**:

1. **Given** a log view with 300 lines and the filter "Error and up" that shows 12 lines, **When** the user exports, **Then** the file has the 12 lines and nothing else.
2. **Given** a search with "show only matching lines" off, **When** the user exports, **Then** the file has all lines that pass the level filter, because the view shows all of them with highlights.
3. **Given** the save panel, **When** the user selects the type "Plain Text", **Then** the file name ends with `.txt`. The default is `.log`.
4. **Given** the save panel, **When** the user cancels, **Then** Gantry writes no file and shows no error.
5. **Given** a write error (for example, a full disk), **When** the export fails, **Then** the log view shows the error message.

---

### User Story 2 - Copy the visible lines (Priority: P1)

The user clicks Copy Visible Lines (the button that was "Copy all"), or selects Edit > Copy Visible Log Lines. The pasteboard gets the same text that an export writes.

**Why this priority**: Copy is the fastest way to paste a few lines into a chat or an issue.

**Independent Test**: Set a filter, copy, paste into a text editor, compare with the view.

**Acceptance Scenarios**:

1. **Given** a filter that shows 5 lines, **When** the user copies, **Then** the pasteboard has the 5 lines, one per line.
2. **Given** no visible lines, **When** the user opens the menu, **Then** Copy Visible Log Lines and Export Logs are disabled.

---

### User Story 3 - Timestamps and time range (Priority: P2)

On a Docker host, the user turns on Show Timestamps. Each line in the view starts with its time. An export or copy then starts each line with an RFC 3339 UTC timestamp, the same format as `docker logs --timestamps`. The user selects the time range "Last 15 minutes". The view, the export and the copy contain only the lines of the last 15 minutes.

**Why this priority**: Timestamps make an exported log useful for a timeline. The time range removes old noise. Both depend on data that only Docker hosts send.

**Independent Test**: On a Docker host, turn on timestamps and export. Make sure that each line starts with a timestamp. Select a time range and export. Make sure that each line is in the range.

**Acceptance Scenarios**:

1. **Given** timestamps off, **When** the user exports, **Then** the lines have no timestamp prefix.
2. **Given** timestamps on and a Docker host, **When** the user exports, **Then** each line starts with a time like `2026-11-14T15:30:00.123Z` and one space.
3. **Given** an Apple `container` host, **When** the user opens the display menu, **Then** Show Timestamps and the time range are disabled, and the help text tells that this host does not report log times.
4. **Given** a line without a timestamp and a time range, **When** the filter runs, **Then** the line stays visible, because Gantry cannot tell its age.

---

### User Story 4 - Export the logs of a Compose project (Priority: P2)

The user opens the stack logs of a Compose project, hides the service `db`, and exports. Each line in the file starts with the service name, as in `docker compose logs`. The file has no lines of `db`.

**Why this priority**: Compose projects are a main use case, but the single-container export comes first.

**Independent Test**: Open stack logs for a project with two services, hide one, export, check the file.

**Acceptance Scenarios**:

1. **Given** two services `web` and `db` and `db` hidden, **When** the user exports, **Then** each line starts with `web | ` and no line is from `db`.
2. **Given** timestamps on, **When** the user exports, **Then** each line is `<timestamp> <service> | <text>`.

---

### User Story 5 - Menu, shortcut and command palette (Priority: P3)

The user presses Shift-Command-E (File > Export Logs…) while a log view is in front. The save panel opens. In the command palette, a container result has the action "Export Logs…". It opens the Logs tab of the container and the save panel.

**Why this priority**: Keyboard and palette access follow the app's patterns. Buttons in the view already give the feature.

**Independent Test**: Open a Logs tab, press Shift-Command-E, check the save panel. In the palette, find a container, select Export Logs…, check the Logs tab and the save panel.

**Acceptance Scenarios**:

1. **Given** no log view in front, **When** the user opens the File menu, **Then** Export Logs… is disabled.
2. **Given** a container in the palette, **When** the user selects Export Logs…, **Then** the Logs tab of that container opens and the save panel opens.

### Edge Cases

- The view has 50 000 lines: the export writes the file in chunks. It does not join all lines into one string first.
- Lines arrive while the save panel is open: the export contains the lines that are visible when the user clicks Save. A paused view exports the lines that it shows, not the held lines.
- The container name has characters that are not safe in a file name (`/`, `:`): the default name replaces them with `-`.
- The search is an invalid regular expression. The filter uses the rule of the view: no line matches. Thus the export is empty, as the view is.
- Lines with ANSI color codes: the file has the plain text only.
- A line with no level: the level filter hides it when a minimum level is set, the same as the view does today.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The Logs tab and the stack logs sheet MUST have an Export Logs button that opens the standard save panel.
- **FR-002**: The export MUST contain exactly the lines that the view shows, in the same order. It uses the same level filter, search, matches-only rule, hidden services and time range.
- **FR-003**: The save panel MUST offer the types Log File (`.log`, default) and Plain Text (`.txt`). The default file name MUST be `<name>-<yyyy-MM-dd-HHmm>` with unsafe characters replaced.
- **FR-004**: The export MUST write the file in chunks of bounded size. It MUST NOT build one string of the whole file.
- **FR-005**: The Copy all button MUST become Copy Visible Lines and MUST copy the same text that an export writes.
- **FR-006**: Both views MUST have a display menu with Show Timestamps and a time range. The time ranges are All, Last 5 minutes, Last 15 minutes, Last hour and Last day. These titles are the titles of the Apple system logs pane.
- **FR-007**: If the lines have no timestamps (Apple `container` hosts), the view MUST disable Show Timestamps and the time range. A help text MUST tell why.
- **FR-008**: A line without a timestamp MUST pass the time range filter.
- **FR-009**: With timestamps on, each exported line MUST start with an RFC 3339 UTC time with milliseconds and one space. In the view, the time MUST show in the local time zone.
- **FR-010**: Stack logs exports MUST start each line with the service name and ` | `.
- **FR-011**: The exported text MUST have no ANSI escape codes and MUST end each line with a line feed.
- **FR-012**: File > Export Logs… (Shift-Command-E) and Edit > Copy Visible Log Lines MUST act on the log view in front. If no log view is in front, or the view shows 0 lines, the app MUST disable the two items.
- **FR-013**: The command palette MUST offer Export Logs… on container results where Show Logs is offered. It MUST open the Logs tab and the save panel.
- **FR-014**: A failed export MUST show its error in the view. A cancelled export MUST show nothing.
- **FR-015**: Every new user-facing string MUST be in the String Catalogs with all 28 languages.

### Key Entities

- **Log line for export**: plain text, optional timestamp, optional level, optional source (service name).
- **Line filter**: minimum level, search query, regex flag, matches-only flag, hidden sources, time range.
- **Export format**: timestamps on or off, source prefix on or off.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For each filter, the exported file and the copied text contain the same lines as the view, in the same order. Tests and a live check show this.
- **SC-002**: An export of 50 000 lines finishes in less than 2 seconds on the development Mac. During the write, the export uses at most one chunk of memory more than the lines that the view holds.
- **SC-003**: The user can export the visible logs in 3 actions or fewer: shortcut or button, file name, Save.
- **SC-004**: `scripts/check-localization.py` reports 0 problems.

## Assumptions

- "Time range" filters the lines that the view holds (the last 100 lines at open plus the followed lines, at most 50 000). It does not fetch older logs from the host.
- The export is a snapshot of the visible lines when the user clicks Save. It does not follow new output.
- The Kubernetes pod logs view and the Apple system logs pane are not in scope.
- Shift-Command-E is free in Gantry and is the common Export shortcut in Mac apps. Copy Visible Log Lines has no shortcut. Thus it cannot clash with the text Copy (Command-C).
- The setting of Show Timestamps and the time range are not saved between launches.
