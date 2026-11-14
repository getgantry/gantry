<!-- STE deviation: commands and paths stay verbatim. -->
# Quickstart: Image Scan and SBOM

## Prerequisites

- apple/container running, with `postgres:16-alpine` and `alpine:latest` pulled.
- Trivy or Grype on the Mac. For a test without Homebrew, set `GANTRY_TRIVY` or `GANTRY_GRYPE` to the binary.

## Unit tests

```sh
swift test --package-path Packages/AppCore \
  --scratch-path /Volumes/SanDisk2Tb/builds/gantry/image-scan/AppCore \
  --filter "ScannerDetectionTests|ImageScanPlanTests|ScanReportParserTests|ImageScanModelTests"
```

Expected: all tests pass. The parser tests agree with the counts of the fixtures: Trivy `postgres:16-alpine` sample and Grype sample (see `ImageScanFixtures.swift`).

## Live pipeline test (no GUI)

```sh
GANTRY_SCAN_LIVE=1 TMPDIR=/Volumes/SanDisk2Tb/builds/gantry/image-scan/tmp/ \
  TRIVY_CACHE_DIR=/Volumes/SanDisk2Tb/builds/gantry/image-scan/cache/trivy \
  GRYPE_DB_CACHE_DIR=/Volumes/SanDisk2Tb/builds/gantry/image-scan/cache/grype \
  GANTRY_TRIVY=/path/to/trivy GANTRY_GRYPE=/path/to/grype \
  swift test --package-path Packages/AppCore \
  --scratch-path /Volumes/SanDisk2Tb/builds/gantry/image-scan/AppCore --filter LiveImageScanTests
```

Expected: the real export, unpack, scan and SBOM export pass for both scanners, and a cancel leaves no `gantry-scan-` folder.

## Live check

1. Build the Debug app into `/Volumes/SanDisk2Tb/builds/gantry/image-scan/DerivedData` with `-jobs 3`.
2. Start it with `GANTRY_TRIVY` set. Open Images on the Apple host.
3. Choose Scan for Vulnerabilities on `alpine:latest`. Expected: steps Export, Unpack, Scan, then the findings or "No vulnerabilities found".
4. Export CycloneDX and SPDX. Expected: two JSON files with `bomFormat` and `spdxVersion`.
5. Start a scan of `postgres:16-alpine` and click Cancel. Expected: "Scan cancelled", no `trivy` process, the temporary folder is gone.
6. Start the app with no scanner (`PATH` without the tools, no overrides). Expected: install help with links.
