# Upstream releases

Gantry talks to the [apple/container](https://github.com/apple/container) CLI,
so its releases can add flags worth surfacing, change the JSON Gantry decodes,
or fix behaviour Gantry works around.

The [`Watch apple/container`](../../.github/workflows/upstream-container-watch.yml)
workflow checks upstream weekly and opens a PR for any release Gantry has not
looked at yet. Each PR drops the release notes here as
`apple-container-<tag>.md` and records the tag in
`.github/upstream/apple-container-version.txt` — that file is what tells the
next run which releases have already been reviewed.

These files are a record of what was reviewed, not documentation of Gantry.
What Gantry actually adopted from a release is in
[`CHANGELOG.md`](../../CHANGELOG.md).
