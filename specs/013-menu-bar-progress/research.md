<!-- STE deviation: spec-kit headings, Swift and Apple API names, CLI output samples and paths stay verbatim. -->
# Research: Progress of Pull, Build and Compose in the Menu Bar

## R1. Live Activities on macOS

- Decision: do not use Live Activities.
- Rationale: in `MacOSX27.2.sdk`, `ActivityKit.framework/.../arm64e-apple-macos.swiftinterface` has 73 `@available(macOS, unavailable)` marks, on `Activity.request(...)` and on all other public API. No public macOS API exists.
- Alternatives considered: a widget with a timeline (Gantry has `Widgets/`). A widget cannot show live bytes, and the brief asks for the menu bar.

## R2. Which model to use

- Decision: use `OperationCenter` and `LongOperation` (`model.operations`), the model of the toolbar Activity list.
- Rationale: every long operation (pull, build, Compose up, bulk, storage, installs) already goes through it, with cancel, finish states and the notification hook `onFinish`.
- Alternatives considered: a separate menu bar model. It would copy the state and the cancel path.

## R3. Pull progress format

- Docker: JSON lines with `id`, `status` ("Pulling fs layer", "Downloading", "Download complete", "Extracting", "Pull complete", "Already exists") and `progressDetail.current` and `total` in bytes.
- apple/container: `container image pull --progress plain` lines, translated by `AppleContainerJSON.pullProgressJSON(fromCLILine:)` into lines without `id` and with `current` and `total` set to a percent of 100.
- Decision: `PullProgressTracker` counts layers by `id`. A layer is done after "Pull complete", "Already exists" or "Download complete" followed by extraction end. Bytes sum the layers that report `total`. A line without `id` and with `total == 100` is an overall percent (apple/container).

## R4. Build step format

- Docker over the engine API (classic builder): `Step 2/7 : RUN make`.
- apple/container (`container build --progress plain`, BuildKit): `#7 [2/5] RUN make`, also `#7 [stage-1 2/5] COPY ...`. Lines such as `#1 [internal] load build definition` have no step.
- Decision: `BuildStepParser` takes text chunks, splits them into lines, and keeps the highest step and the last total. For multi-stage BuildKit output the total of the stage in the last line is used.

## R5. Compose down and Compose pull

- Decision: reuse `HostSession.performBulk` with a new kind and title. Down plans `.remove(force: true)` on the project containers, then removes the networks with the label `com.docker.compose.project=<project>`. Pull plans `.pull` on the image references of the project containers. A reference that is an image id (`sha256:`) is skipped.
- Rationale: the bulk engine gives concurrency, cancel, per-item log, failure report and refresh.
- Alternatives considered: run `docker compose`. Gantry has no required dependency on the Compose CLI, and apple/container has none.

## R6. Menu bar label

- Decision: `MenuBarExtra(isInserted:content:label:)` with a label view: the `MenuBarIcon` image, and the running count as text when it is above 0.
- Rationale: a menu bar label renders an image and text. An animation or a color dot would show status by color only.

## R7. Notifications

- Decision: no change to `ContainerNotifier.presentOperation`. It posts for each finished operation when Gantry is not active, with the `operationFinished` category and its Show action, and skips a cancel.
