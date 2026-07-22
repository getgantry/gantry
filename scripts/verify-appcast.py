#!/usr/bin/env python3
"""Check that appcast.xml will actually deliver a release to existing installs.

Sparkle decides an update is newer by comparing `sparkle:version`
(CFBundleVersion), not the marketing version. A release that ships without
incrementing the build number publishes perfectly happily and is then silently
never offered to anyone — that happened on 0.13.0. This asserts the things that
have to hold for auto-update to work:

  * the newest item is the version we just released
  * its build number is strictly greater than every other item's
  * it carries a non-empty EdDSA signature
  * its enclosure URL points at this version's tag

Usage: scripts/verify-appcast.py <version> [path/to/appcast.xml]
"""

import re
import sys
import xml.etree.ElementTree as ET


def fail(message: str) -> None:
    print(f"appcast check failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    if len(sys.argv) < 2:
        fail("usage: verify-appcast.py <version> [appcast.xml]")
    version = sys.argv[1]
    path = sys.argv[2] if len(sys.argv) > 2 else "appcast.xml"

    source = open(path, encoding="utf-8").read()
    match = re.search(r'xmlns:sparkle="([^"]+)"', source)
    if not match:
        fail(f"{path} declares no sparkle namespace")
    sparkle = match.group(1)

    items = ET.fromstring(source).findall("./channel/item")
    if not items:
        fail(f"{path} has no <item> entries")

    def attr(item, name):
        """Read a Sparkle value from either a child element or the enclosure.

        generate_appcast has emitted both shapes across versions.
        """
        node = item.find(f"{{{sparkle}}}{name}")
        if node is not None and node.text:
            return node.text.strip()
        enclosure = item.find("enclosure")
        if enclosure is None:
            return None
        return enclosure.get(f"{{{sparkle}}}{name}")

    def build(item) -> int:
        raw = attr(item, "version")
        try:
            return int(raw)
        except (TypeError, ValueError):
            fail(f"item has a non-numeric sparkle:version: {raw!r}")

    # Look the release up by name rather than by highest build number: when a
    # release forgets to bump the build, picking "the newest" by build number
    # silently selects the previous release and misreports what is wrong.
    released = [item for item in items if attr(item, "shortVersionString") == version]
    if not released:
        present = sorted({attr(item, "shortVersionString") for item in items})
        fail(f"no item for {version!r}; {path} has {present}")
    if len(released) > 1:
        fail(f"{path} has {len(released)} items for {version!r}")
    newest = released[0]

    others = [build(item) for item in items if item is not newest]
    if others and build(newest) <= max(others):
        fail(
            f"build number {build(newest)} is not greater than the previous "
            f"{max(others)} — Sparkle would never offer this update"
        )

    if not attr(newest, "edSignature"):
        fail("newest item has no EdDSA signature")

    enclosure = newest.find("enclosure")
    url = enclosure.get("url") if enclosure is not None else ""
    if f"/v{version}/" not in (url or ""):
        fail(f"enclosure URL does not point at v{version}: {url!r}")

    print(f"appcast OK: {version}, build {build(newest)}, signed, {url}")


if __name__ == "__main__":
    main()
