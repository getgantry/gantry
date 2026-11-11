<!-- STE deviation: spec-kit template headings, the quoted user input, Given-When-Then scenarios, product names, file system names and paths stay verbatim. -->
# Feature Specification: Polish Fixes for 0.27.1

**Feature Branch**: `fix/polish-0-27-1`

**Created**: 2026-11-09

**Status**: Draft

**Input**: User description: "Fix four defects found while making the 0.27.0 marketing screenshots: the Explain button has no accessibility label, the time labels of the memory chart overlap, a gantry:// link leaves the command palette open, and gantry-ctl can find its own shell instead of the app. Target release 0.27.1."

## Context

We found these defects on 2026-11-08, when we made the screenshots for the 0.27.0 site with `scripts/gantry-ctl` on a live Debug build. Each defect is small and independent. Each user story below is one defect.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - VoiceOver reads the Explain button (Priority: P1)

A VoiceOver user selects a failed container. The container header has the Explain button. VoiceOver reads "Explain, button" and the help text. Today VoiceOver reads only "button".

**Why this priority**: Constitution principle "Accessibility" says that every icon-only control has a label. This defect breaks a rule of the project.

**Independent Test**: Read the accessibility tree of the container header for a failed container. The Explain button has the name "Explain" in each UI language.

**Acceptance Scenarios**:

1. **Given** a failed container and Explain Failures on, **When** VoiceOver moves to the Explain button, **Then** VoiceOver reads "Explain" and the hint "Explain this failure with Apple Intelligence".
2. **Given** the app language is Russian, **When** VoiceOver moves to the button, **Then** VoiceOver reads the Russian name.
3. **Given** a failed build in Activity, **When** VoiceOver moves to its Explain button, **Then** VoiceOver reads "Explain" too.

---

### User Story 2 - The time labels of the stats charts are clear (Priority: P2)

A user opens the Stats tab of a running container. Under each chart, the time labels have space between them. Today the labels of the memory chart touch: "13:38:0413:38:09".

**Why this priority**: The defect shows on the site screenshots and in each Stats tab. It does not block work.

**Independent Test**: Open Stats for one minute at the minimum window width and at a wide width. Take a snapshot. No two labels touch.

**Acceptance Scenarios**:

1. **Given** the Stats tab at the minimum window width, **When** the charts have one minute of samples, **Then** each time label has space on each side.
2. **Given** the Stats tab with 10 seconds of samples, **When** the user looks at the axis, **Then** the labels do not repeat the same time.

---

### User Story 3 - A link closes the command palette (Priority: P2)

The command palette (⌘K) is open. A `gantry://open/...` link arrives from a script, from Shortcuts or from the automation socket. Gantry closes the palette and shows the place that the link names. Today the palette stays open over that place.

**Why this priority**: Scripts and screenshots that use links get a dimmed window. The user must close the palette by hand.

**Independent Test**: Open the palette with `gantry-ctl palette`, send `gantry-ctl open/containers`, then `gantry-ctl state`. The state shows no palette and the Containers section.

**Acceptance Scenarios**:

1. **Given** the palette is open, **When** the link `gantry://open/containers` arrives, **Then** the palette closes and Containers shows.
2. **Given** the palette is open, **When** the link `gantry://settings` arrives, **Then** the palette closes and Settings opens.
3. **Given** the palette is open, **When** the link `gantry://palette` arrives, **Then** the palette stays open.
4. **Given** the palette is open, **When** a debug link (`snapshot`, `state`, `appearance`) arrives, **Then** the palette stays open, so a script can take a snapshot of it.

---

### User Story 4 - gantry-ctl finds the app every time (Priority: P3)

A developer runs `scripts/gantry-ctl` from a shell, an agent or a script. The tool finds the running Debug build of Gantry. Today `pgrep -n -f` can match another process whose command line contains the pattern, for example the shell of a parallel agent command or a `tail` of the app log. On macOS, `pgrep` already skips itself and its ancestors, but it does not skip these other processes. When such a process is newer than the app, the tool selects it and says that no socket exists.

**Why this priority**: Only developers and agents use the tool. Constitution engineering rules say that UI checks use it, so a defect slows each UI check.

**Independent Test**: While a Debug build runs, start `sh -c 'sleep 20; : Debug/Gantry.app/Contents/MacOS/Gantry' &`, then run `zsh -c 'scripts/gantry-ctl state <path>; : Debug/Gantry.app/Contents/MacOS/Gantry'`. The command writes the state file.

**Acceptance Scenarios**:

1. **Given** a Debug build runs, **When** the calling command line or another newer process contains the app path, **Then** gantry-ctl sends to the pid of the app.
2. **Given** two Debug builds run and `GANTRY_APP` names one, **When** the developer runs gantry-ctl, **Then** the tool sends to that build.
3. **Given** a running process has the pattern in its command line but no automation socket, **When** the developer runs gantry-ctl, **Then** the tool skips that process.

---

### Edge Cases

- Explain Failures is off: the Explain button is hidden, so it needs no label.
- A container stops while the Stats tab is open: the chart keeps the old samples and the labels stay clear.
- A link arrives while a sheet or a confirmation shows over the palette: Gantry closes the palette only. A destructive confirmation stays.
- No Debug build runs: gantry-ctl prints the same error as today and exits with a status that is not zero.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Each Explain button (container header, Activity) MUST have the accessibility name "Explain" from the String Catalog and the hint of its help text.
- **FR-002**: The time axis of each chart in the Stats tab MUST show labels that do not touch, at each window width that the app allows.
- **FR-003**: A `gantry://open/...` or `gantry://settings` link MUST close an open command palette before Gantry shows the place.
- **FR-004**: A `gantry://palette` link and the debug links MUST keep the palette in its current state.
- **FR-005**: `scripts/gantry-ctl` MUST select only a process whose automation socket exists, and MUST ignore its own shell and its parents.
- **FR-006**: The fix of FR-003 MUST come with a Swift Testing test of the rule "which link closes the palette".
- **FR-007**: All new user-facing strings MUST have translations for all supported UI languages.
- **FR-008**: The debug link `state` MUST answer after each navigation. The main window reader of ContentView MUST keep its window when SwiftUI makes the split view again (Dashboard and Containers use different columns).

### Key Entities

- **App link**: a `gantry://` URL. It names a place (`open`, `settings`), the palette, or a debug command.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The accessibility tree shows 0 Explain buttons without a name, in English and in Russian.
- **SC-002**: On snapshots of the Stats tab at 3 window widths, 0 time labels touch.
- **SC-003**: In 10 runs of "open palette, send link, read state", the state shows the palette closed 10 times.
- **SC-004**: In 20 runs of gantry-ctl from a shell whose command line contains the pattern, while another newer process with the pattern runs, the tool reaches the app 20 times.

## Assumptions

- Release 0.27.1 is a patch release. The fixes add no new features.
- The localization check (`scripts/check-localization.py`) runs on the pull request.
- VoiceOver checks use the accessibility tree through `orca computer`. A check by ear with the user is optional.
- Out of scope: the open tasks of earlier specs (001 T035, 003 T013 and T030, 004 T042) and the Paste Command screenshot of the site.
