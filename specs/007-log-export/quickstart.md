<!-- STE deviation: commands, paths and product names stay verbatim. -->
# Quickstart: Validate Export Container Logs

## Prerequisites

- Apple `container` 1.7.1 with `container system start`.
- A Debug build in `/Volumes/SanDisk2Tb/builds/gantry/log-export/DerivedData`.

## Unit tests

```sh
cd Packages/AppCore
swift test --scratch-path /Volumes/SanDisk2Tb/builds/gantry/log-export/appcore --filter "LogExport|CommandPalette"
```

Expected: all tests pass.

## Localization

```sh
python3 scripts/check-localization.py
```

Expected: 0 problems.

## Live check (Apple host)

1. Start a test container that writes known lines:
   `container run -d --name gle-logs alpine sh -c 'for i in $(seq 1 300); do echo "INFO line $i"; [ $((i % 25)) = 0 ] && echo "ERROR fail $i"; done; sleep 3600'`
2. Start the Debug build with `GANTRY_APP` set to it, and open the Logs tab of `gle-logs` with `scripts/gantry-ctl`.
3. Set the level filter to Error and up. The view shows 12 lines.
4. Press Shift-Command-E. The save panel opens with `gle-logs-<date>-<time>.log`.
5. Save. The file has the 12 `ERROR` lines.
6. Open the display menu. Show Timestamps and the time range are disabled with the help text.
7. Remove the container: `container rm -f gle-logs`.
