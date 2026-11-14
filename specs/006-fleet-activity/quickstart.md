<!-- STE deviation: commands, paths and product names stay verbatim. -->
# Quickstart: Fleet Activity Table

## Prerequisites

- apple/container 1.7.1 with `container system start` done.
- External disk `/Volumes/SanDisk2Tb` mounted.

## Unit tests

```sh
swift test --package-path Packages/AppCore --scratch-path /Volumes/SanDisk2Tb/builds/gantry/fleet-activity/AppCore --filter 'FleetActivity|ContainerUptime|AppLink'
swift test --package-path Packages/DockerKit --scratch-path /Volumes/SanDisk2Tb/builds/gantry/fleet-activity/DockerKit --filter 'DockerHumanDuration|AppleContainer'
swift test --package-path Packages/GantryMCP --scratch-path /Volumes/SanDisk2Tb/builds/gantry/fleet-activity/GantryMCP --filter FleetActivity
python3 scripts/check-localization.py
```

Expected: all tests pass, and the localization check reports 0 problems.

## Live check

1. Start two test containers: `container run -d --name gfa-web docker.io/library/alpine:latest sleep 3600` and `container run -d --name gfa-busy docker.io/library/alpine:latest sh -c 'while :; do :; done'`.
2. Build the Debug app with `xcodebuild -jobs 3 -derivedDataPath /Volumes/SanDisk2Tb/builds/gantry/fleet-activity/DerivedData` and open it.
3. `GANTRY_APP=fleet-activity scripts/gantry-ctl open/usage`, wait 15 s, then `scripts/gantry-ctl snapshot /abs/usage.png` and `scripts/gantry-ctl state /abs/state.json`.
4. Expected: the selection is `usage`. The table shows `gfa-busy` first (CPU about 100 %), then `gfa-web`. The uptime column shows seconds or minutes.
5. Remove the test containers: `container rm -f gfa-web gfa-busy`.
