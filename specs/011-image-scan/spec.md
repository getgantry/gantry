<!-- STE deviation: spec-kit template headings, the quoted user input, Given-When-Then scenarios, product names, file system names and paths stay verbatim. -->
# Feature Specification: Image Scan and SBOM

**Feature Branch**: `feat/image-scan`

**Created**: 2026-11-14

**Status**: Draft

**Input**: User description: "On an image, a Scan action that runs Trivy or Grype if one is installed (detect in PATH and Homebrew paths; never require or install them; show how to install with a link when missing). Show findings grouped by severity with package, installed and fixed version, CVE link; export SBOM (CycloneDX/SPDX) via save panel. Remote/Apple images: scan by reference or via an exported archive, whichever the tool supports; research and pick the simplest correct path. Parsing of the JSON outputs in AppCore with fixture tests. Long scans show progress and can be cancelled."

## Context

Trivy and Grype are free vulnerability scanners. Many developers install them with Homebrew. Gantry does not include or install them (constitution principle III). When one of them is on the Mac, Gantry can run it on an image and show the result in a native window.

Research on 2026-11-14 (Trivy 0.76.2, Grype 0.121.3, apple/container 1.7.1):

- `container image save` without `--platform` fails for a multi-platform image when the store does not have all platforms. With `--platform os/arch` of the image, it writes an OCI tar archive.
- Trivy (`--input`) and Grype (`oci-archive:`) both refuse this tar, because its first entry is `./`. Both scan the OCI layout after the tar is unpacked into a folder (Trivy `--input DIR`, Grype `oci-dir:DIR`).
- A Docker `save` archive has `manifest.json`. Trivy `--input FILE` and Grype `docker-archive:FILE` scan it directly.
- Both tools scan a registry reference without a local engine (Trivy `--image-src remote`, Grype `registry:REF`), with `--platform`.
- Trivy writes CycloneDX and SPDX JSON. Grype writes CycloneDX JSON only. Grype refuses `spdx-json`.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Scan a local image and read the findings (Priority: P1)

A user selects an image on an Apple `container` host or on the local Docker host and chooses "Scan for Vulnerabilities…". A sheet opens. Gantry exports the image, runs the installed scanner and shows the findings. The findings are in groups by severity: Critical, High, Medium, Low, Negligible, Unknown. Each finding shows the vulnerability ID, the package, the installed version, the fixed version (or "No fix") and a link to the advisory.

**Why this priority**: This is the feature. Without it, nothing else has a value.

**Independent Test**: With Trivy or Grype installed, scan `postgres:16-alpine` on an Apple host. The sheet shows the counts per severity and the list. The counts agree with the JSON output of the same tool on the same image.

**Acceptance Scenarios**:

1. **Given** an Apple host, Trivy installed and the image `postgres:16-alpine`, **When** the user chooses Scan for Vulnerabilities, **Then** the sheet shows progress, and then the findings in severity groups with package, installed version, fixed version and a link.
2. **Given** a scan with no findings, **When** the scan ends, **Then** the sheet says that the scanner found no vulnerabilities.
3. **Given** a finding with the ID `CVE-…`, **When** the user clicks its link, **Then** the advisory page opens in the browser.
4. **Given** both Trivy and Grype are installed, **When** the sheet opens, **Then** the user can select the scanner, and Trivy is the default.

---

### User Story 2 - No scanner is installed (Priority: P1)

A user without Trivy and Grype chooses Scan for Vulnerabilities. The sheet tells the user that Gantry uses Trivy or Grype, shows the Homebrew command for each and gives links to the install pages. Gantry installs nothing.

**Why this priority**: Most users do not have a scanner. The action must not look broken.

**Independent Test**: Start the app with no scanner in PATH or in the Homebrew folders. Open the sheet. It shows the install help and no error.

**Acceptance Scenarios**:

1. **Given** no scanner, **When** the sheet opens, **Then** it shows `brew install trivy`, `brew install grype` and links to the install pages of both tools.
2. **Given** the user installs a scanner while the sheet is open, **When** the user clicks Check Again, **Then** the sheet finds the scanner.

---

### User Story 3 - Cancel a long scan (Priority: P1)

The first scan downloads the vulnerability database, and a large image takes minutes to export. The sheet shows the current step (export, unpack, scan) and a Cancel button. Cancel stops the export or the scanner and removes the temporary files.

**Why this priority**: A scan can take minutes. The user must be able to stop it.

**Independent Test**: Start a scan of a large image and click Cancel during the export or the scan. The sheet shows "Cancelled". No scanner process stays. The temporary folder is gone.

**Acceptance Scenarios**:

1. **Given** a running scan, **When** the user clicks Cancel, **Then** the scanner process stops and the sheet shows that the scan was cancelled.
2. **Given** a running scan, **When** the user closes the sheet, **Then** the scan stops and Gantry removes the temporary files.

---

### User Story 4 - Export an SBOM (Priority: P2)

After a scan, the user chooses Export SBOM and a format: CycloneDX or SPDX. A save panel opens. Gantry runs the scanner in SBOM mode and writes the file to the place that the user selected.

**Why this priority**: SBOMs are necessary for compliance work, but the scan is more important.

**Independent Test**: After a Trivy scan, export CycloneDX and SPDX. Each file is valid JSON with `bomFormat: CycloneDX` or `spdxVersion`.

**Acceptance Scenarios**:

1. **Given** a scan with Trivy, **When** the user exports CycloneDX, **Then** the file has a CycloneDX document of the image.
2. **Given** a scan with Grype, **When** the user opens the Export SBOM menu, **Then** only CycloneDX is available, and the menu tells that SPDX needs Trivy.
3. **Given** an export that fails, **When** the scanner exits with an error, **Then** the sheet shows the error and Gantry does not leave a partial file.

---

### User Story 5 - Scan an image of a remote Docker host (Priority: P3)

On a Docker host over SSH, Gantry cannot export the image to this Mac. Gantry scans the registry copy of the image tag. The sheet tells the user this before the scan starts.

**Why this priority**: Remote hosts are less common, and the registry copy can differ from the local image.

**Independent Test**: On an SSH Docker host, scan `alpine:3.20`. The sheet shows the note about the registry copy and then the findings.

**Acceptance Scenarios**:

1. **Given** an SSH Docker host and a tagged image, **When** the sheet opens, **Then** it says that Gantry scans the registry copy of the tag.
2. **Given** an SSH Docker host and an untagged image, **When** the user opens the image menu, **Then** the scan action is not available.

---

### Edge Cases

- An untagged image on an Apple host: `container image save` needs a reference. The action is not available. On the local Docker host, Gantry saves the image by its ID.
- The image has no platform in its metadata: Gantry exports without `--platform` and shows the tool error if the export fails.
- The scanner is older than the minimum version: the sheet shows the version and asks the user to update the tool.
- The scanner output is not valid JSON, or the scanner exits with a non-zero status: the sheet shows the last lines of the error output.
- The same vulnerability affects two packages: the list shows two rows.
- A finding has no link from the tool: Gantry makes a link from the ID (`CVE-` to cve.org, `GHSA-` to GitHub Advisories). Other IDs have no link.
- The user cancels the save panel of an SBOM export: Gantry does nothing.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The image context menu and the image detail toolbar MUST have the action "Scan for Vulnerabilities…" on Apple hosts, the local Docker host and SSH Docker hosts (on SSH hosts, only for tagged images).
- **FR-002**: Gantry MUST find Trivy and Grype in this order: the environment overrides `GANTRY_TRIVY` and `GANTRY_GRYPE`, the folders of `PATH`, `/opt/homebrew/bin`, `/usr/local/bin`. Gantry MUST NOT install them and MUST NOT need them for any other feature.
- **FR-003**: With no scanner, the sheet MUST show the Homebrew commands and links to the install pages of Trivy and Grype, and a Check Again button.
- **FR-004**: Gantry MUST read the version of each scanner and MUST NOT run a scanner older than its minimum supported version (Trivy 0.50.0, Grype 0.74.0).
- **FR-005**: For Apple hosts, Gantry MUST export the image with `container image save --platform OS/ARCH`, unpack the archive into a temporary folder and scan the OCI layout.
- **FR-006**: For the local Docker host, Gantry MUST save the image to a temporary archive and scan the archive.
- **FR-007**: For SSH Docker hosts, Gantry MUST scan the registry reference of the tag with the image platform, and MUST tell the user that it scans the registry copy.
- **FR-008**: Gantry MUST parse the JSON report of Trivy and of Grype into one model. The model has the ID, severity, package, installed version, fixed versions, fix state, title and link.
- **FR-009**: The sheet MUST show the findings in groups by severity, from Critical to Unknown, with a count per group. The severity MUST show as text, not by color only.
- **FR-010**: While the scan runs, the sheet MUST show the current step, the elapsed time and a Cancel button.
- **FR-010a**: Cancel MUST stop the child process. Gantry MUST then remove the temporary files. Closing the sheet MUST do the same.
- **FR-011**: Export SBOM MUST offer CycloneDX (both tools) and SPDX (Trivy only). It MUST ask for the file with a save panel.
- **FR-011a**: When the SBOM export fails or the user cancels it, Gantry MUST remove the partial file.
- **FR-012**: Gantry MUST remove the temporary folder when the sheet closes.
- **FR-013**: Every new user-facing string MUST be in the String Catalogs with all 28 languages.

### Key Entities

- **Scanner**: Trivy or Grype, with the path of the binary, its version and the formats it can write.
- **Scan source**: how Gantry gives the image to the scanner: an OCI layout folder, a Docker archive file or a registry reference, with the platform.
- **Finding**: one vulnerability in one package: ID, severity, package name, installed version, fixed versions, fix state, title, link.
- **Scan report**: the scanner, its version, the findings and the counts per severity.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For the fixtures from Trivy 0.76.2 and Grype 0.121.3, the parsed counts per severity agree with the counts in the JSON reports.
- **SC-002**: After Cancel, no scanner or export process of the scan runs, and the temporary folder is removed, in all tests of the scan model.
- **SC-003**: A user without a scanner sees the install help in one step. The sheet shows no error message.
- **SC-004**: A scan of `alpine:latest` on an Apple host with a warm database ends in less than 30 seconds on the development Mac.
- **SC-005**: `scripts/check-localization.py` reports 0 problems.

## Assumptions

- The user installs and updates the scanners. The scanners download their own databases on the first run. Gantry tells the user that this can take time.
- Registry credentials for SSH hosts come from the scanner's own configuration (for example `~/.docker/config.json`). Gantry does not pass passwords to the scanners.
- The temporary files are in the user temporary folder of macOS. A large image needs free disk space for its archive and the unpacked layout.
- Kubernetes images and the MCP server are not in the scope of this feature.
- Scan results are not stored. A new scan runs the tool again.
