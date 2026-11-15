<!-- STE deviation: product names, CLI flags, error text and paths stay verbatim. -->
# Research: Image Scan and SBOM

All tests on 2026-11-14 on the development Mac: apple/container 1.7.1, Trivy 0.76.2, Grype 0.121.3 (release binaries, checksums verified, kept on the external disk only for this research).

## R1. How to give an Apple image to the scanner

- `container image save --output pg.tar postgres:16-alpine` fails with `Error: content with digest sha256:… ` when the local store does not have all platforms of the index.
- `container image save --platform linux/arm64 --output pg.tar postgres:16-alpine` writes an OCI tar (`oci-layout`, `index.json`, `blobs/`). Its entries start with `./`.
- `trivy image --input pg.tar` fails: "unable to open pg.tar as a Docker image: file manifest.json not found in tar" and "unable to open pg.tar as an OCI Image: stat pg.tar/index.json: not a directory".
- `grype oci-archive:pg.tar` fails: "potential path traversal attack with entry: "./"".
- After `tar -xf pg.tar -C pg-oci`, `trivy image --input pg-oci` and `grype oci-dir:pg-oci` both scan the image (88 and 30 findings).

**Decision**: export with `--platform OS/ARCH[/VARIANT]`, unpack with `/usr/bin/tar` into the temporary folder, delete the tar, scan the folder.
**Rationale**: the only path that both tools accept for Apple images. Scan by reference does not work, because the tools cannot read the Apple image store.
**Alternatives considered**: scan by registry reference (scans a different copy, needs the network, fails for local builds); repack the tar without `./` (more code, same result).

## R2. Local Docker host

A `docker save` archive has `manifest.json`. Trivy `--input FILE` and Grype `docker-archive:FILE` read it.

**Decision**: save through the existing `HostSession.saveImages` into the temporary folder and scan the file. Untagged images are saved by ID.
**Rationale**: the same code path as Save to Archive. It does not depend on the socket path of the Docker engine, which Gantry knows and the scanners do not.
**Alternatives considered**: `--image-src docker` and `docker:REF`. The scanners then look for the engine socket themselves and miss Colima or custom sockets.

## R3. Docker host over SSH

The image is on another machine. Gantry cannot save it to this Mac without a large transfer.

**Decision**: scan the registry copy: Trivy `--image-src remote --platform P REF`, Grype `registry:REF --platform P`. Both worked for `alpine:3.20`. The sheet tells the user that the registry copy is scanned. Untagged images have no action.
**Alternatives considered**: stream `docker save` over SSH to the Mac (slow, uses disk, larger change).

## R4. SBOM formats

Trivy: `--format cyclonedx` and `--format spdx-json` work. Grype: `-o cyclonedx-json` works, `-o spdx-json` exits 1 (not a Grype format).

**Decision**: CycloneDX for both, SPDX only with Trivy. The tool writes to a temporary file; Gantry moves it to the user's path after success.

## R5. Detection and versions

`trivy --version` prints `Version: 0.76.2`. `grype version` prints `Version:             0.121.3`. A GUI app gets a short `PATH`, so Gantry also looks in `/opt/homebrew/bin` and `/usr/local/bin`.

**Decision**: minimum Trivy 0.50.0 and Grype 0.74.0 (all flags above exist there). An unknown version is allowed, as in `ContainerTooling`.

## R6. Report formats

- Trivy JSON (`SchemaVersion` 2): `Results[]` with `Target`, `Class`, `Type`, and `Vulnerabilities[]` (missing when there are none) with `VulnerabilityID`, `PkgName`, `InstalledVersion`, `FixedVersion` (comma-separated, can be missing), `Status` (`fixed`, `affected`, `will_not_fix`, `fix_deferred`, `end_of_life`, `unknown`), `Severity` (upper case), `Title`, `PrimaryURL`. `Trivy.Version` gives the version.
- Grype JSON: `matches[]` with `vulnerability.id`, `vulnerability.severity` (title case, also `Negligible`), `vulnerability.dataSource`, `vulnerability.fix.versions[]` and `fix.state` (`fixed`, `not-fixed`, `wont-fix`, `unknown`), `vulnerability.description`, `artifact.name`, `artifact.version`, `artifact.type`. `descriptor.version` gives the version.

**Decision**: two parsers with `Decodable` types that keep only these fields, into one `VulnerabilityFinding`.

## R7. Progress and cancel

Trivy prints a progress bar with carriage returns on stderr; Grype prints a terminal UI. Both are noise in a sheet.

**Decision**: run with `--quiet` / `-q`, show the step (export, unpack, scan) and the elapsed time. Cancel the Swift task: `ChildProcess.run` sends SIGTERM to the child. On error, show the last lines of stderr.
