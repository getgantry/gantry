<!-- STE deviation: commands and paths stay verbatim. -->
# Quickstart: Image Scan and SBOM

## Prerequisites

- apple/container running, with `postgres:16-alpine` and `alpine:latest` pulled.
- Trivy or Grype on the Mac. For a test without Homebrew, set `GANTRY_TRIVY` or `GANTRY_GRYPE` to the binary.

## Unit tests

```sh
swift test --package-path Packages/AppCore \
  --scratch-path /Volumes/SanDisk2Tb/builds/gantry/image-scan/AppCore \
  --filter ImageScan
```

Expected: all tests pass. The parser tests agree with the counts of the fixtures: Trivy `postgres:16-alpine` sample and Grype sample (see `ImageScanFixtures.swift`).

## Live check

1. Build the Debug app into `/Volumes/SanDisk2Tb/builds/gantry/image-scan/DerivedData` with `-jobs 3`.
2. Start it with `GANTRY_TRIVY` set. Open Images on the Apple host.
3. Choose Scan for Vulnerabilities on `alpine:latest`. Expected: steps Export, Unpack, Scan, then the findings or "No vulnerabilities found".
4. Export CycloneDX and SPDX. Expected: two JSON files with `bomFormat` and `spdxVersion`.
5. Start a scan of `postgres:16-alpine` and click Cancel. Expected: "Scan cancelled", no `trivy` process, the temporary folder is gone.
6. Start the app with no scanner (`PATH` without the tools, no overrides). Expected: install help with links.
