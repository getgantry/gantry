<!-- STE deviation: menu titles, shortcuts and SF Symbol names stay verbatim. -->
# UI Contract: Export Container Logs

## Log view toolbar (LogsView and StackLogsView)

| Control | Symbol | Label and help | State |
|---|---|---|---|
| Display menu | `clock` / `clock.fill` when a range or timestamps is on | "Timestamps and Time Range" | items disabled with help "This host does not report log times" when no line has a timestamp |
| Copy Visible Lines | `doc.on.doc` | "Copy Visible Lines" | disabled with 0 visible lines |
| Export Logs | `square.and.arrow.up` | "Export Logs…" | disabled with 0 visible lines |

Display menu items: Toggle "Show Timestamps", Picker "Time Range" with All, Last 5 minutes, Last 15 minutes, Last hour, Last day.

## Menus

| Menu | Item | Shortcut | Enabled when |
|---|---|---|---|
| File | Export Logs… | Shift-Command-E | a log view is in front and shows 1 or more lines |
| Edit | Copy Visible Log Lines | none | same |

## Command palette

Container results with Show Logs also have "Export Logs…" (`square.and.arrow.up`) after Show Logs.

## Save panel

Default name `<container or project>-yyyy-MM-dd-HHmm.log`. Types: Log File (`.log`), Plain Text (`.txt`).

## File format

One line for each visible line, a line feed after each line, UTF-8, no ANSI codes:

```text
[<RFC 3339 UTC timestamp> ][<service> | ]<text>
```
