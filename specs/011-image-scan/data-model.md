<!-- STE deviation: Swift type and case names stay verbatim. -->
# Data Model: Image Scan and SBOM

## ScannerKind

`trivy`, `grype`. Fields: display name, Homebrew formula, install page URL, minimum version, environment override (`GANTRY_TRIVY`, `GANTRY_GRYPE`), version arguments, SBOM formats (Trivy: CycloneDX and SPDX; Grype: CycloneDX).

## InstalledScanner

`kind`, `path`, `version` (a string, `nil` when the output had no version). `isSupported` is true when the version is unknown or at least the minimum.

## ImageScanPlan

What the export step does and what the scanner reads.

- `appleArchive(reference, platform)`: `container image save`, unpack, source `ociLayout(folder)`.
- `dockerArchive(reference)`: `saveImages`, source `dockerArchive(file)`.
- `registry(reference, platform)`: no export, source `registry(reference)`.

`platform` is `os/arch[/variant]` or `nil`. Validation: Apple and SSH plans need a tag that is not `<none>:<none>`. The local Docker plan uses the ID when there is no tag.

## ScanSource

`ociLayout(path)`, `dockerArchive(path)`, `registry(reference)`, and the optional platform.

## VulnerabilitySeverity

`critical`, `high`, `medium`, `low`, `negligible`, `unknown`, in this order. Parse is case-insensitive. A value that is not known becomes `unknown`.

## FixState

`fixed`, `notFixed`, `wontFix`, `unknown`.

## VulnerabilityFinding

`id` (row identity, unique in the report), `vulnerabilityID`, `severity`, `packageName`, `packageType`, `installedVersion`, `fixedVersions [String]`, `fixState`, `title`, `url` (tool URL, or made from the ID).

## ScanReport

`scanner`, `scannerVersion`, `findings`, `groups` (severity and its findings, only groups with findings, sorted by package then ID), `count(of:)`, `total`.

## SBOMFormat

`cycloneDX`, `spdx`. File name suffix `.cdx.json` and `.spdx.json`.

## ImageScanModel state

```text
detecting -> noScanner | ready
ready -> running(step) -> finished(report) | failed(message) | cancelled
finished | failed | cancelled -> running (scan again)
```

`step`: `exporting`, `unpacking`, `scanning`. SBOM export has its own state: `idle`, `running(format)`, `failed(message)`, `saved(path)`. The prepared source stays in the temporary folder for the SBOM export and for a second scan until `close()`.
