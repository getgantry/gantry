<!-- STE deviation: command lines stay verbatim. -->
# Contract: Scanner Commands

`OUT` is a file in the temporary folder. `P` is the platform `os/arch[/variant]`.

## Export (Apple host)

```text
container image save --platform P --output TMP/image.tar REF
/usr/bin/tar -xf TMP/image.tar -C TMP/oci
```

## Trivy

| Purpose | Arguments |
|---------|-----------|
| Version | `--version` |
| Scan OCI layout | `image --quiet --timeout 30m --scanners vuln --format json --output OUT --input TMP/oci` |
| Scan Docker archive | `image --quiet --timeout 30m --scanners vuln --format json --output OUT --input TMP/image.tar` |
| Scan registry | `image --quiet --timeout 30m --scanners vuln --format json --output OUT --image-src remote --platform P REF` |
| SBOM | as the scan, with `--format cyclonedx` or `--format spdx-json` and without `--scanners vuln` |

## Grype

| Purpose | Arguments |
|---------|-----------|
| Version | `version` |
| Scan OCI layout | `oci-dir:TMP/oci -q -o json --file OUT` |
| Scan Docker archive | `docker-archive:TMP/image.tar -q -o json --file OUT` |
| Scan registry | `registry:REF --platform P -q -o json --file OUT` |
| SBOM | as the scan, with `-o cyclonedx-json` |

Exit status 0 means success. Any other status is a failure; the sheet shows the last lines of stderr.
