# apple/container 1.4.1

Released 2026-09-09T01:28:43Z — https://github.com/apple/container/releases/tag/1.4.1

---

This release addresses two security issues in the Containerization package:

- [GHSA-4587-w9mm-xxvh](https://github.com/apple/containerization/security/advisories/GHSA-4587-w9mm-xxvh) - OCI image load follows symlinks for `oci-layout` and `index.json` outside the extraction directory
- [GHSA-rgqp-277h-gcwj](https://github.com/apple/containerization/security/advisories/GHSA-rgqp-277h-gcwj) - `UnixType.init(path:)` uses a macOS length limit longer than the `sockaddr_un.sun_path` buffer it copies into

There was no 1.4.0 release, we had to discard that tag so this release contains every change since 1.3.1.

## Highlights

⌨️ denotes breaking CLI changes.

👩‍💻 denotes breaking API changes.

- Core
  - [New `container clean` command](https://github.com/apple/container/pull/1949)
  - 👩‍💻 [`container system status` now reports host, client, paths, and resources](https://github.com/apple/container/pull/1769)
  - [JSON output no longer escapes forward slashes](https://github.com/apple/container/pull/2205)
  - [Updated Containerization to 0.45.0](https://github.com/apple/container/pull/2250)

## What's Changed
* Avoid escaping slashes in JSON output by @taljeon in https://github.com/apple/container/pull/2205
* Enhance `container system status` command output by @muk2 in https://github.com/apple/container/pull/1769
* Updates containerization to 0.43.0. by @jglogan in https://github.com/apple/container/pull/2208
* [container]: add clean command by @saehejkang in https://github.com/apple/container/pull/1949
* fix: handle container clean failing on read-only named volume mounts by @zdk in https://github.com/apple/container/pull/2228
* ci: bump softprops/action-gh-release from 3.0.2 to 3.0.3 in the github-actions group by @dependabot[bot] in https://github.com/apple/container/pull/2226
* Fix a compilation error by @dkovba in https://github.com/apple/container/pull/2234
* Remove security markdown in favor of inherited security guidelines by @katiewasnothere in https://github.com/apple/container/pull/2249
* docs: remove broken troubleshooting.md link in technical overview by @zdk in https://github.com/apple/container/pull/2227
* Fix compilation warnings by @dkovba in https://github.com/apple/container/pull/2235
* docs: Add k8s plugin reference by @egernst in https://github.com/apple/container/pull/2244
* Bump CZ to 0.45.0 by @realrajaryan in https://github.com/apple/container/pull/2250

## New Contributors
* @taljeon made their first contribution in https://github.com/apple/container/pull/2205
* @muk2 made their first contribution in https://github.com/apple/container/pull/1769

**Full Changelog**: https://github.com/apple/container/compare/1.3.1...1.4.1
