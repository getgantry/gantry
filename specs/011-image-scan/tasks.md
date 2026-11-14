---

description: "Task list for image scan and SBOM"
---

<!-- STE deviation: spec-kit template headings, task format (one line per task, so long task lines), product names, Swift type names, CLI flags and paths stay verbatim. -->
# Tasks: Image Scan and SBOM

**Input**: Design documents from `/specs/011-image-scan/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/scanner-commands.md

**Tests**: Required for the logic in AppCore (constitution principle II). Parser tests use fixtures from real Trivy 0.76.2 and Grype 0.121.3 reports. The views get a live check with `scripts/gantry-ctl`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: The user story of the task (US1 to US5)

## Phase 1: Setup of the feature folder

- [x] T001 Create the folder Packages/AppCore/Sources/AppCore/ImageScan/ and keep the research reports of research.md on the external disk (/Volumes/SanDisk2Tb/builds/gantry/image-scan/work) as the fixture source

## Phase 2: Foundational (blocks all stories)

- [x] T002 [P] Add `ScannerKind` (`trivy`, `grype`), `InstalledScanner`, the search order "`GANTRY_TRIVY` or `GANTRY_GRYPE`, then the folders of `PATH`, then `/opt/homebrew/bin`, `/usr/local/bin`" with an injected environment and `isExecutable` check, the version parse of `Version: x.y.z`, and the minimum versions Trivy 0.50.0 and Grype 0.74.0 in Packages/AppCore/Sources/AppCore/ImageScan/ImageScanner.swift
- [x] T003 [P] Add `ImageScanPlan` (`appleArchive(reference, platform)`, `dockerArchive(reference)`, `registry(reference, platform)`) and `ScanSource`; "Apple and SSH plans need a tag that is not `<none>:<none>`. The local Docker plan uses the ID when there is no tag" in Packages/AppCore/Sources/AppCore/ImageScan/ImageScanPlan.swift
- [x] T004 [P] Add `ScanCommand` with the arguments of contracts/scanner-commands.md for scan and SBOM, and the Apple export and unpack arguments, in Packages/AppCore/Sources/AppCore/ImageScan/ScanCommand.swift
- [x] T005 [P] Add `VulnerabilitySeverity` (order critical, high, medium, low, negligible, unknown; case-insensitive parse; unknown values become `unknown`), `FixState`, `VulnerabilityFinding`, `ScanReport` with groups and counts, link fallback (`CVE-` to cve.org, `GHSA-` to GitHub Advisories), `TrivyReportParser` and `GrypeReportParser` in Packages/AppCore/Sources/AppCore/ImageScan/ScanReport.swift
- [x] T006 Add the fixtures cut from the real reports (Trivy and Grype for `postgres:16-alpine`, and the reports of `alpine:latest`) in Packages/AppCore/Tests/AppCoreTests/ImageScanFixtures.swift
- [x] T007 Add tests for T002 to T005 (search order, version parse and minimum, plans per host kind, command arguments, both parsers with severity counts, fix states, missing `Vulnerabilities`, link fallback) in Packages/AppCore/Tests/AppCoreTests/ImageScanTests.swift

## Phase 3: User Story 1 - Scan a local image (P1) MVP

**Goal**: one image on an Apple host or the local Docker host is scanned and the findings show in severity groups.

**Independent Test**: scan `postgres:16-alpine` on the Apple host; the counts agree with the JSON report of the tool.

- [x] T008 [US1] Add `ScanProcessRunning` (default on `ChildProcess.run`), `ScanFileSystem` (default on `FileManager`) and `ImageScanModel` with the states of data-model.md, scanner selection (Trivy first), the steps export, unpack, scan, and `close()` that removes the temporary folder, in Packages/AppCore/Sources/AppCore/ImageScan/ImageScanModel.swift
- [x] T009 [US1] Add `HostSession.imageScanPlan(for:)` and the export closure (`container image save --platform` with the host CLI override for Apple hosts, `saveImages` for the local Docker host) in Packages/AppCore/Sources/AppCore/ImageScan/HostSession+ImageScan.swift
- [x] T010 [US1] Add model tests with fake runner and file system: the step order, the arguments sent, the parsed report, a failed scan with the stderr tail, and the temporary folder removed on `close()`, in Packages/AppCore/Tests/AppCoreTests/ImageScanTests.swift
- [x] T011 [US1] Add `ImageScanSheet` with helper views (severity summary, finding row with link, scanner picker) in App/Views/Images/ImageScanSheet.swift
- [x] T012 [US1] Add "Scan for Vulnerabilities…" to the image context menu and the image detail toolbar in App/Views/Images/ImageListView.swift

## Phase 4: User Story 2 - No scanner is installed (P1)

**Goal**: without a scanner, the sheet shows install help and installs nothing.

**Independent Test**: start the app with no scanner; the sheet shows the help and no error.

- [x] T013 [US2] Add the `noScanner` and `unsupported` states and `detect()` (Check Again) to `ImageScanModel` in Packages/AppCore/Sources/AppCore/ImageScan/ImageScanModel.swift, with tests in Packages/AppCore/Tests/AppCoreTests/ImageScanTests.swift
- [x] T014 [US2] Add the install help view (Homebrew commands, links to the install pages, Check Again) in App/Views/Images/ImageScanSheet.swift

## Phase 5: User Story 3 - Cancel a long scan (P1)

**Goal**: Cancel and closing the sheet stop the child process and remove the temporary files.

**Independent Test**: cancel a scan; no scanner process stays and the temporary folder is gone.

- [x] T015 [US3] Add `cancel()` and the `cancelled` state to `ImageScanModel`, and test with a fake runner that waits for cancellation (gate on events, no sleeps) in Packages/AppCore/Sources/AppCore/ImageScan/ImageScanModel.swift and Packages/AppCore/Tests/AppCoreTests/ImageScanTests.swift
- [x] T016 [US3] Show the step, the elapsed time and the Cancel button, and call `close()` when the sheet goes away, in App/Views/Images/ImageScanSheet.swift

## Phase 6: User Story 4 - Export an SBOM (P2)

**Goal**: the user saves a CycloneDX or SPDX file with a save panel.

**Independent Test**: export CycloneDX and SPDX after a Trivy scan; both files are valid.

- [x] T017 [US4] Add `exportSBOM(format:to:)` to `ImageScanModel`: write to a temporary file, move to the user path after success, remove the partial file on failure or cancel; SPDX only with Trivy; tests in Packages/AppCore/Sources/AppCore/ImageScan/ImageScanModel.swift and Packages/AppCore/Tests/AppCoreTests/ImageScanTests.swift
- [x] T018 [US4] Add the Export SBOM menu and the `NSSavePanel` in App/Views/Images/ImageScanSheet.swift

## Phase 7: User Story 5 - Remote Docker host (P3)

**Goal**: on an SSH Docker host, Gantry scans the registry copy of the tag and says so.

**Independent Test**: the plan of an SSH host is `registry`, and the sheet shows the note.

- [x] T019 [US5] Use the `registry` plan for SSH hosts and hide the action for untagged images, with tests, in Packages/AppCore/Sources/AppCore/ImageScan/HostSession+ImageScan.swift and Packages/AppCore/Tests/AppCoreTests/ImageScanTests.swift
- [x] T020 [US5] Show the registry note in App/Views/Images/ImageScanSheet.swift

## Phase 8: Polish and cross-cutting

- [x] T021 Add the new strings with 28 languages to App/Localizable.xcstrings and Packages/AppCore/Sources/AppCore/Resources/Localizable.xcstrings; `scripts/check-localization.py` reports 0 problems
- [x] T022 Build the Debug app with `xcodebuild -jobs 3 -derivedDataPath /Volumes/SanDisk2Tb/builds/gantry/image-scan/DerivedData` and run the AppCore tests with `--filter "ScannerDetectionTests|ImageScanPlanTests|ScanReportParserTests|ImageScanModelTests"`
- [x] T025 Add the gated live test (real `container image save`, Trivy 0.76.2 and Grype 0.121.3 on `alpine:latest`, CycloneDX and SPDX export, cancel) in Packages/AppCore/Tests/AppCoreTests/LiveImageScanTests.swift
- [x] T026 Add the gated live Docker test over SSH (`saveImages` archive with both scanners, the registry plan of an SSH host with both scanners) in Packages/AppCore/Tests/AppCoreTests/LiveImageScanTests.swift
- [x] T023 Live check of quickstart.md steps 2 to 6 with `scripts/gantry-ctl` and `GANTRY_APP` set to this build
  - Setup (2026-11-14): Debug build, Apple CLI 1.7.1, test host list.
  - Result: `alpine:latest` with Trivy showed 1 Medium (CVE-2026-4738, zlib) with a link. CycloneDX 1.7 and SPDX-2.3 files came from the save panel. `postgres:16-alpine` showed 1 Critical, 44 High, 38 Medium, 3 Low and 2 Unknown.
  - Result: on `metabase/metabase:v0.65.3.6` with Grype, the sheet showed "Unpacking the image…" and "Scanning with Grype…" with the elapsed time. Stop showed "Scan Cancelled". The `grype` process stopped, and the temporary folder was gone.
  - Result: the app started with `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and without the overrides. The sheet showed the install help with the Homebrew commands, two install links and Check Again.
  - Bug found: the window went to another Space. Then a new sheet stayed on "Looking for Trivy and Grype…". A closed sheet also kept its temporary folder. Fixed in T027.
- [x] T027 Start the detection from the model (`ImageScanModel.startDetection()`) when the sheet request is made, not from `.task`. Close the old model when the request changes or the detail view shows another image. Test `startDetectionRunsOnceWithoutTheView` in Packages/AppCore/Tests/AppCoreTests/ImageScanTests.swift. Live: a link that selects another image during an open sheet now removes the temporary folder.
- [x] T024 Rebase on `origin/main`, open the pull request "feat: scan images for vulnerabilities with trivy or grype"

## Dependencies

- Phase 2 blocks all stories. T007 needs T002 to T006.
- US1 (T008 to T012) is the MVP. US2, US3 and US4 extend the model and the sheet of US1, so they come after it. US5 needs only T009.
- T021 to T024 come last.

## Parallel Execution

- T002, T003, T004 and T005 are in different files and can be done in parallel.
- After T008, the model work of US2 (T013), US3 (T015) and US4 (T017) touches the same file, so do it in sequence; the view tasks T014, T016, T018 and T020 are also in one file.

## Implementation Strategy

1. Phase 2 and US1: a scan that works on the Apple host.
2. US2 and US3: the missing-tool help and Cancel, because a scan without them is not safe to ship.
3. US4, then US5.
4. Strings, build, live check, pull request.
