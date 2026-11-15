<!-- STE deviation: spec-kit headings, Apple API names, type names and paths stay verbatim. -->
# Research: Export Container Logs

## R1. Save panel and streamed write

- Decision: Use `fileExporter(isPresented:item:contentTypes:defaultFilename:onCompletion:onCancellation:)` with a `Transferable` item. The item has two `FileRepresentation`s: `UTType.log` (default) and `UTType.plainText`. Each representation calls the AppCore writer, which writes a temporary file in chunks, and returns `SentTransferredFile`.
- Rationale: The task asks for `fileExporter`. A `FileDocument` must return the whole file as one `FileWrapper` in memory, which breaks FR-004. A `FileRepresentation` gets a file URL, so the write can go in chunks.
- Alternatives considered: `NSSavePanel` plus a direct write (the pattern of the filesystem export in `ContainerListView`). It writes to the destination with no temporary copy, but it is not `fileExporter`, and the task names `fileExporter`.

## R2. Timestamps

- Decision: `HostSession.logStream` already asks Docker for `timestamps=true`, and `LogEntry.timestamp` holds the parsed date. The views keep the date in their line model. The export writes RFC 3339 UTC with milliseconds (`ISO8601DateFormatter` with `.withFractionalSeconds`). The view shows local `HH:mm:ss.SSS`.
- Apple `container`: `container logs --help` (CLI 1.7.1) has only `--boot`, `--follow` and `-n`. There is no timestamp option. The transport sends raw lines, so `timestamp` is nil. The controls are disabled when no held line has a timestamp.
- Alternatives considered: add the receive time as a timestamp on Apple hosts. Rejected: the receive time of the first 100 lines is wrong, and a wrong time is worse than no time.

## R3. Time range

- Decision: Filter the held lines on the client: All, 5 min, 15 min, 1 h, 24 h, relative to the time of the filter. A line with no timestamp passes.
- Rationale: The views hold the tail and the followed output. A new fetch with `since` would change the stream model of the views and is out of scope.

## R4. Menu target

- Decision: A `FocusedValues` entry `logExportTarget` with two closures (export, copy) and a line count. Each log view publishes it with `focusedSceneValue`. `LogCommands` reads it with `@FocusedValue` and disables the items when it is nil or the count is 0.
- Rationale: The pattern is the same as `gantrySection` in `SectionCommands.swift`.

## R5. Shortcut

- Decision: Shift-Command-E for File > Export Logs…. No shortcut for Edit > Copy Visible Log Lines.
- Rationale: Shift-Command-E is the common Export shortcut on macOS (for example in Pages and Keynote for export, and Xcode does not use it in this context). A grep of `keyboardShortcut` in `App/` shows no use of `e` with Shift-Command. A Copy variant with extra modifiers is hard to find and can clash with text editing.

## R6. Palette

- Decision: New `PaletteAction.exportLogs` ("Export Logs…", `square.and.arrow.up`) after `.logs` in `containerActions`. The runner calls `ContainerTabRequest.open(.exportLogs, …)`. The detail view opens the Logs tab for it, and `LogsView` takes the request and opens the save panel.
- The export item reads the visible lines when the user clicks Save (R1), so lines that arrive after the tab opens are in the file.
