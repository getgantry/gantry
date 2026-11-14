<!-- STE deviation: product names such as apple/container, Swift API names and paths stay verbatim. -->
# Research: Fleet Activity Table

## R1. Source of the live values

- Decision: read `HostSession.containerLoadHistory.latest(id)` and `HostSession.visibleContainers`.
- Rationale: each connected host samples all its running containers every 5 s (`startLoadSampling`, `recordLoadSample`) for the dashboard and the Overview. The samples have CPU, memory and network and disk rates. The table adds no load on the hosts. This is important over SSH, where the transport is serial.
- Alternatives: one stats stream for each container (as the Stats tab). Rejected: N streams for each host, and a repeat of the existing sampler.

## R2. Network and disk I/O: rates or totals

- Decision: rates in bytes per second (received and sent; read and written). The sort key is the sum.
- Rationale: the dashboard and the Overview show rates. A rate answers "what is busy now". Totals since start mostly sort by uptime.
- Alternatives: the cumulative totals of `docker stats`. Rejected for the reason above.

## R3. Uptime for both host kinds

- Decision: parse the Docker status text "Up <duration>" in AppCore (`ContainerUptime`). For apple/container, `AppleContainerJSON` writes the same text from `status.startedDate` (1.x) or `startedDate` (0.12), with the wording of Docker's `units.HumanDuration`.
- Rationale: `GET /containers/json` has no start time. An inspect for each container at each refresh is too expensive. Docker's text is the only data in the list. With the same text for apple hosts, one parser serves both kinds, and the apple Containers list shows uptime as Docker does.
- Live check (apple/container 1.7.1, 2026-11-14): `container ls --format json` gives `"status": {"state": "running", "startedDate": "2026-11-14T15:03:55Z"}`.
- Alternatives: a new `startedAt` field on `ContainerSummary`. Rejected: Docker cannot fill it from the list call.
- Precision: Docker rounds ("About an hour", "3 days"). The parsed value is the lower bound of the unit. It is good for sort and display.

## R4. Sort with SwiftUI Table

- Decision: `FleetActivity.Comparator: SortComparator` in AppCore, one for each column, used with `TableColumn(_:sortUsing:)`. The view keeps `[FleetActivity.Comparator]` as `sortOrder` and sorts with `rows.sorted(using:)`.
- Rationale: the comparator is pure and has tests. It keeps rows without a value last in both orders (FR-005), which `KeyPathComparator` on optionals cannot do.

## R5. Navigation from a row

- Decision: `contextMenu(forSelectionType:menu:primaryAction:)` on the `Table`. The primary action (double-click, Return) calls the existing `navigate(hostID, .containers, .container(id))`. "Show Stats" uses the same route and sets the pending detail tab. A row id is `"<hostID>/<containerID>"`.
- Rationale: the dashboard and the palette use this route already.

## R6. MCP tool

- Decision: `fleet_activity` in `GantryTools+Activity.swift`. For each target host: list the running containers, take one-shot stats twice with one second between them, and use `LoadMath.point` and `FleetActivity` to make, sort and cut the rows. A host that fails gives one error entry.
- Rationale: the MCP server is a separate process and has no sampler history. Two one-shot samples give CPU and rates the same way as the app sampler. The cost is about 1 s for each call, and the hosts run in parallel.
