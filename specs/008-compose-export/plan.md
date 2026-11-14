<!-- STE deviation: spec-kit template headings, Swift identifiers, Compose keys, file names and paths stay verbatim. -->
# Implementation Plan: Export a Running Container as a Compose File

**Branch**: `feat/compose-export` | **Date**: 2026-11-14 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/008-compose-export/spec.md`

## Summary

A new AppCore type `ComposeExporter` makes Compose YAML from one or more `ComposeExportSource` values. Each source holds the raw inspect JSON of a container, the raw inspect JSON of its image, and the host kind. Docker sources are read from the Docker Engine inspect shape. Apple `container` sources are read from the original CLI object that the transport keeps under the `AppleContainer` key. The exporter builds a Yams node tree with a fixed key order and safe quoting, and returns the YAML, the warnings and the masked variables. A thin SwiftUI sheet shows the result and saves or copies it.

## Technical Context

**Language/Version**: Swift 6.1 (tools), Swift 6 language mode, SwiftUI on macOS 26

**Primary Dependencies**: Yams (already an AppCore dependency) for YAML output and the round-trip parse; DockerKit for the inspect calls

**Storage**: The file that the user selects in the save panel. No app storage.

**Testing**: Swift Testing in `Packages/AppCore/Tests/AppCoreTests/ComposeExportTests.swift`, with inline fixtures: one Docker Engine inspect (container and image), one Apple `container` 1.7.1 inspect copied from a live run on 2026-11-14

**Target Platform**: macOS 26 or later

**Project Type**: Native macOS app with Swift packages

**Performance Goals**: The sheet shows the YAML in less than 1 second for 10 containers on a local host (one container inspect and one image inspect for each container)

**Constraints**: No new dependency. No change to the DockerKit translation of Apple inspect data (the exporter reads the original CLI object). No Foundation Models header (optional in the input, out of scope).

**Scale/Scope**: About 700 lines of logic in AppCore, one sheet and three menu entries in the app, about 30 new strings

## Constitution Check

| Principle | Check | Result |
|-----------|-------|--------|
| I. Native Mac app, HIG first | The sheet uses a standard sheet with a toolbar-free bottom button row (Done, Copy, Save…). The YAML is monospaced and selectable. Warnings use an SF Symbol and text, not color only. | Pass |
| II. Logic in packages, tests | All mapping, masking, quoting and warnings are in AppCore `Compose/ComposeExport*.swift`. The view only shows the result and calls the exporter again when the user changes an option. The tests use fixtures; the Apple fixture comes from a live `container inspect`. | Pass |
| III. No required deps, version gates | The feature uses only the inspect calls that each host already supports. Apple fields that are absent on older CLI versions are optional. | Pass |
| IV. Data and secret safety | Secret-like environment values are masked by default and replaced with `${NAME}`. A file with an included secret is written with `0600`. Nothing is logged. The feature changes no container. | Pass |
| V. Every string in every language | New strings go into `App/Localizable.xcstrings` and `Packages/AppCore/Sources/AppCore/Resources/Localizable.xcstrings` with 28 languages. `scripts/check-localization.py` must report 0 problems. | Pass |

## Research

### R1: Read the Apple data from the original CLI object

- **Decision**: For Apple `container` hosts, read `AppleContainer.configuration` from the raw inspect body.
- **Rationale**: The Docker-shaped translation loses data that the export needs: the volume name (it gives the path of `volume.img`), the `ro` option of a bind (it is in `options`, not in `readOnly`), the user (`initProcess.user.raw.userString`), capabilities, tmpfs mounts and all networks. A change to the translation can change other screens, so the exporter reads the original object.
- **Alternatives considered**: Extend `AppleContainerJSON.containerInspectBody`. Rejected for this feature: larger scope and a risk to the Overview tab.

### R2: Process mapping on Apple hosts

- **Decision**: `container inspect` gives one process (`executable` and `arguments`). If the process is equal to the image entrypoint and command, omit both. If the process starts with the image entrypoint, emit only `command` with the rest. Else emit `entrypoint` with the full process, which also clears the image command in Compose.
- **Rationale**: Each case starts the same process under Compose.

### R3: Docker process mapping

- **Decision**: If `Config.Entrypoint` is equal to the image entrypoint, omit it and emit `Cmd` only when it differs from the image command. If the entrypoint differs, emit it and emit `Cmd` too, because a new entrypoint clears the image command.

### R4: YAML output

- **Decision**: Build a `Yams.Node` tree with ordered mappings, serialize with `Yams.serialize(node:)`. A string is plain only when it matches a safe pattern and is not a YAML 1.1 keyword (`yes`, `no`, `on`, `off`, `true`, `false`, `null`, `~`) and is not a number. Else it is double-quoted. Port strings are always quoted.
- **Rationale**: Yams escapes the text correctly. The fixed order gives a stable diff and readable files.
- **Alternatives considered**: `Yams.dump` of a dictionary: random key order and no control of quoting.

### R5: Secret detection

- **Decision**: Reuse `SecretRedactor.isSecretName` and `SecretRedactor.looksRandom`. A masked value becomes `${NAME}`.
- **Rationale**: The same rules as the Explain feature; Compose reads `${NAME}` from the shell or from `.env`.

### R6: Fields that Compose cannot express

- Docker: `AutoRemove` (`--rm`), anonymous volumes (data is not copied), legacy `Links`, an image known only by ID or digest, `network_mode: container:<id>` to a container outside the export, binds on a remote host, an image that Gantry could not inspect.
- Apple: custom kernel and kernel arguments (Gantry labels), `rosetta`, `virtualization`, `ssh`, `publishedSockets`, the DNS domain, and the note that CPU and memory are always set.

## Data Model

- `ComposeExportSource`: `containerInspect: Data`, `imageInspect: Data?`, `isAppleContainer: Bool`, `isRemoteHost: Bool`.
- `ComposeExportOptions`: `includedSecrets: Set<ComposeExportSecret>`.
- `ComposeExportSecret`: `service: String`, `variable: String`; `Hashable`, `Identifiable`.
- `ComposeExportWarning`: `service: String`, `message: String`; `Hashable`, `Identifiable`.
- `ComposeExportResult`: `yaml: String`, `warnings: [ComposeExportWarning]`, `secrets: [ComposeExportSecret]`, `includesSecretValues: Bool`.
- `ComposeExporter.export(_ sources:, options:) throws -> ComposeExportResult`. It throws only when a container inspect body is not valid JSON.
- `HostSession.composeExportSources(for ids:) async -> [ComposeExportSource]`: inspects each container and its image.

## Project Structure

### Documentation (this feature)

```text
specs/008-compose-export/
├── spec.md
├── plan.md
├── tasks.md
└── checklists/requirements.md
```

### Source Code (repository root)

```text
Packages/AppCore/Sources/AppCore/Compose/
├── ComposeExport.swift          # public types, exporter entry, YAML node building
├── ComposeExport+Docker.swift   # Docker inspect → service draft
├── ComposeExport+Apple.swift    # Apple container inspect → service draft
└── ComposeExport+Session.swift  # HostSession.composeExportSources
Packages/AppCore/Tests/AppCoreTests/
├── ComposeExportTests.swift
└── ComposeExportFixtures.swift
App/Views/Compose/
└── ComposeExportSheet.swift     # preview sheet, Save, Copy, menu items
```

**Structure Decision**: The logic sits next to the Compose parser and runner in AppCore. The sheet sits next to `ComposeUpSheet.swift`.

## Complexity Tracking

No constitution violations.
