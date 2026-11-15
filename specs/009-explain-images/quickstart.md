<!-- STE deviation: commands, paths and product names stay verbatim. -->
# Quickstart: Screenshots in Explain This Failure

## Unit tests

```sh
swift test --package-path Packages/AppCore \
  --scratch-path /Volumes/SanDisk2Tb/builds/gantry/explain-images/AppCore \
  --filter "ExplainImage|ExplainController|GeneratedSchema"
```

Expected: all pass. The tests make images in memory.

## Live model test (opt-in)

```sh
GANTRY_FM_LIVE=1 swift test --package-path Packages/AppCore \
  --scratch-path /Volumes/SanDisk2Tb/builds/gantry/explain-images/AppCore --filter liveExplainWithImage
```

Needs macOS 27, Apple Intelligence on, and a model with `vision`. Expected: the explanation is returned and the model saw one image.

## Live app check

1. Build Debug: `xcodebuild -project Gantry.xcodeproj -scheme Gantry -configuration Debug -jobs 3 -derivedDataPath /Volumes/SanDisk2Tb/builds/gantry/explain-images/DerivedData build`.
2. Start the build. Make a failed container on the Apple `container` host: `container run --name gei-fail alpine sh -c 'echo boom >&2; exit 3'`.
3. Open Explain for `gei-fail`. Expected on macOS 27 with vision: an "Add Image…" button and a drop hint.
4. Paste a screenshot (Command-V). Expected: a thumbnail, the note about images, a new analysis.
5. Turn on "Use Private Cloud Compute" (if available), open Explain again. Expected: no attach control.
6. Remove the container: `container rm gei-fail`.
