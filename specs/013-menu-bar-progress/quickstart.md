<!-- STE deviation: commands, links and paths stay verbatim. -->
# Quickstart: check the menu bar progress

## Tests

```
cd Packages/AppCore
swift test --scratch-path /Volumes/SanDisk2Tb/builds/gantry/menu-bar-progress/AppCore \
  --filter 'MenuBarActivity|PullProgressTracker|BuildStepParser|ComposeProject|AppLink|OperationCenter'
python3 scripts/check-localization.py
```

Expected: all tests pass; the check reports 0 problems.

## Live check (Debug build)

1. Build: `xcodebuild -scheme Gantry -configuration Debug -jobs 3 -derivedDataPath /Volumes/SanDisk2Tb/builds/gantry/menu-bar-progress/DerivedData build`.
2. Start the built app. Set `GANTRY_APP=menu-bar-progress/DerivedData` for `scripts/gantry-ctl`.
3. `scripts/gantry-ctl 'debug/pull?ref=docker.io/library/postgres:17'`. Then `scripts/gantry-ctl 'debug/activity?path=/abs/a.json'`. Expected: `runningCount` 1, a row with kind `pull` and a detail text with layers or a percent.
4. `scripts/gantry-ctl 'debug/menubar?path=/abs/menubar.png'`. Expected: the panel image shows the Activity section with the bar, the detail and the time.
5. `scripts/gantry-ctl debug/cancel`, then `debug/activity` again. Expected: `runningCount` 0, a recent row with state `cancelled`.
6. Compose: run Compose up of a two-service file on the apple/container host, then Pull Images and Compose Down on its group header. `debug/activity` shows kinds `composePull` and `composeDown`. Remove the test containers.
