<!-- STE deviation: Swift type and field names stay verbatim. -->
# Data Model: Fleet Activity Table

All types are in `Packages/AppCore/Sources/AppCore/FleetActivity.swift` unless the text says a different file.

## FleetActivity.HostInput

The data of one host that the snapshot needs.

| Field | Type | Note |
|-------|------|------|
| id | UUID | host id |
| name | String | host name |
| isAppleContainer | Bool | host kind |
| state | `HostState` | `.connected`, `.connecting`, `.disconnected`, `.failed(String)` |
| containers | [ContainerSummary] | only user-visible containers are used |
| load | [String: ContainerLoadPoint] | latest point by container id |

## FleetActivity.Row

| Field | Type | Note |
|-------|------|------|
| id | String | `"<hostID>/<containerID>"`, unique in the fleet |
| hostID, hostName, isAppleContainer | | from the host |
| containerID, name, image | String | from `ContainerSummary` |
| load | ContainerLoadPoint? | nil until the first sample |
| uptime | TimeInterval? | from `ContainerUptime.seconds(fromStatus:)` |

Derived values: `cpuPercent`, `memoryBytes`, `networkRate`, `diskRate` (optional, from `load`).

Rules: a row exists only for a running, user-visible container of a connected host.

## FleetActivity.UnavailableHost

`id`, `name`, `state` (`.connecting`, `.disconnected` or `.failed(reason)`). One for each host that is not connected, in sidebar order.

## FleetActivity.Snapshot

`rows: [Row]`, `unavailableHosts: [UnavailableHost]`, `connectedHostCount: Int`.

## FleetActivity.Column

`host`, `name`, `image`, `cpu`, `memory`, `network`, `disk`, `uptime`. Raw values are the MCP `sort` argument values.

## FleetActivity.Comparator

`column: Column`, `order: SortOrder`. Conforms to `SortComparator` (Compared = Row).

1. Text columns compare with `localizedStandardCompare`.
2. Metric columns: a nil value is after each non-nil value, in both orders.
3. Ties: host name, then container name, then id (always ascending).

## FleetActivity.Filter

`text: String`, `hostID: UUID?`. Text matches name, image or host name (any letter case, diacritics ignored). An empty text matches all. `hostID == nil` matches all hosts. A `hostID` that is not in the host list is reset to nil by the view.

## ContainerUptime (`ContainerUptime.swift`)

`seconds(fromStatus:) -> TimeInterval?`. Input: "Up 3 hours", "Up 3 hours (healthy)", "Up About a minute", "Up Less than a second", "Up 2 weeks (Paused)". Output nil for "Up", "Exited (0) 2 hours ago" and "".

## DockerHumanDuration (DockerKit)

`string(_ seconds: TimeInterval) -> String`. Docker's `units.HumanDuration`:

| Input | Output |
|-------|--------|
| < 1 s | Less than a second |
| 1 s | 1 second |
| < 60 s | N seconds |
| 1 min | About a minute |
| < 60 min | N minutes |
| hours rounded = 1 | About an hour |
| < 48 h | N hours |
| < 2 weeks | N days |
| < 2 months (30 d) | N weeks |
| < 2 years (365 d) | N months |
| else | N years |
