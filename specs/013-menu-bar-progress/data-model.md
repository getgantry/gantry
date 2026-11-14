<!-- STE deviation: Swift type and field names stay verbatim. -->
# Data Model: Progress of Pull, Build and Compose in the Menu Bar

## OperationProgress (value, AppCore)

| Field | Type | Rule |
| --- | --- | --- |
| `items` | `ItemProgress?` | `done` from 0 to `total`; `total` above 0 |
| `bytes` | `ByteProgress?` | `done` from 0 to `total`; `total` above 0 |
| `fraction` | computed `Double?` | bytes fraction first, then items fraction |
| `detailText` | computed `String?` | "3 of 7 layers · 12 MB of 45 MB" |

`ItemProgress.Unit`: `layers`, `steps`, `services`, `items`. Each unit has its own plural string.

## LongOperation (existing, changed)

- New: `progress: OperationProgress` (default empty).
- New: `report(_ progress: OperationProgress, status: String?)` sets `progress`, `progressText` and `fraction` (from `progress.fraction`). It does nothing after the finish.

## OperationKind (existing, changed)

- New cases: `composeDown`, `composePull`.

## PullProgressTracker (value, AppCore)

- `mutating apply(_ line: PullProgress)`.
- `layerOrder: [String]`, `layers: [String: PullProgress]`, `statusLine: String`.
- `progress: OperationProgress`: layers done of all layers, bytes of the sized layers.
- `fraction: Double?`: bytes fraction, else the apple/container percent, else layers fraction.

## BuildStepParser (value, AppCore)

- `mutating consume(_ text: String)`; `step: Int?`, `total: Int?`, `lastLine: String?`.
- `progress: OperationProgress` with unit `steps`.

## MenuBarActivity (value, AppCore)

- Input: `[LongOperation]` in start order, `now`.
- `running`: newest first, at most 5. `hiddenRunning`: the rest count.
- `recent`: finished in the last 600 s, last finished first, at most 3.
- `runningCount`, `isVisible` (running or recent not empty).
- `static func elapsed(from:to:) -> String` for finished rows ("1:05", "1:02:03").

## DestructiveAction.Kind (existing, changed)

- New: `composeDown`. Built by `DestructiveAction.composeDown(project:containers:)`. Impact: running containers stop.
