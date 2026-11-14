<!-- STE deviation: commands and paths stay verbatim. -->
# Quickstart: check Build History

## Tests

```sh
swift test --package-path Packages/DockerKit --scratch-path /Volumes/SanDisk2Tb/builds/gantry/build-history/DockerKit --filter "BuildProgress|BuildxHistory"
swift test --package-path Packages/AppCore --scratch-path /Volumes/SanDisk2Tb/builds/gantry/build-history/AppCore --filter "BuildHistory|Buildx"
python3 scripts/check-localization.py
```

Expected: all tests pass, 0 localization problems.

Live test against the installed `container` CLI (builds and removes `gbh-live:*`):

```sh
GANTRY_BUILD_HISTORY_LIVE=1 swift test --package-path Packages/AppCore --scratch-path /Volumes/SanDisk2Tb/builds/gantry/build-history/AppCore --filter LiveBuildHistory
```

## Live check (Apple host)

1. Build the Debug app with `xcodebuild -jobs 3 -derivedDataPath /Volumes/SanDisk2Tb/builds/gantry/build-history/DerivedData`.
2. Start it, set `GANTRY_APP` to the build, and open `gantry://host/<apple-host>/builds` with `scripts/gantry-ctl`.
3. Build a small Dockerfile (tag `gbh-live:1`) two times, and a Dockerfile with `RUN exit 3`.
4. Snapshot the Builds section. Expected: three records (Succeeded, Succeeded with all steps cached, Failed with the failed step marked).
5. Quit the app and start it again. Expected: the records are still there.
6. Remove the `gbh-` images.
