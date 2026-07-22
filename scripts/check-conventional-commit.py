#!/usr/bin/env python3
"""Validate a Conventional Commits subject line.

Version numbers and changelog entries are derived from these, so a subject that
doesn't parse isn't a style nit — release-please silently drops it, and a `feat`
typed as `feature` means the release that should have bumped the minor version
quietly doesn't.

Usage: scripts/check-conventional-commit.py "<subject>"
"""

import re
import sys

# The types release-please is configured for (see release-please-config.json).
TYPES = ["feat", "fix", "build", "chore", "ci", "docs", "style", "refactor", "perf", "test"]

# type(optional scope)optional ! : space description
PATTERN = re.compile(
    r"^(?P<type>[a-z]+)"
    r"(?:\((?P<scope>[^()\s]+)\))?"
    r"(?P<breaking>!)?"
    r": (?P<description>.+)$"
)

# Titles GitHub generates for merges and reverts, which nobody types by hand.
EXEMPT = re.compile(r"^(?:Merge |Revert )")


def main() -> None:
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        sys.exit("usage: check-conventional-commit.py \"<subject>\"")
    subject = sys.argv[1].strip().splitlines()[0]

    if EXEMPT.match(subject):
        print(f"skipped (generated title): {subject}")
        return

    match = PATTERN.match(subject)
    if not match:
        sys.exit(
            f"'{subject}' is not a Conventional Commit.\n"
            f"Expected: <type>[(scope)][!]: <description>\n"
            f"Types: {', '.join(TYPES)}\n"
            f"Example: feat(machines): boot with nested virtualization"
        )

    kind = match.group("type")
    if kind not in TYPES:
        sys.exit(
            f"'{kind}' is not a type this project uses.\n"
            f"Types: {', '.join(TYPES)}"
        )

    description = match.group("description")
    if description[0].isupper():
        sys.exit(f"description should start lowercase: '{description}'")
    if description.endswith("."):
        sys.exit(f"description should not end with a period: '{description}'")

    bump = "major" if match.group("breaking") else {"feat": "minor", "fix": "patch"}.get(kind, "none")
    print(f"OK: {subject}  (version bump: {bump})")


if __name__ == "__main__":
    main()
