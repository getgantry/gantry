# apple/container 1.3.1

Released 2026-08-29T00:24:57Z — https://github.com/apple/container/releases/tag/1.3.1

---

This patch release addresses a number of security issues in the Containerization package:

- [GHSA-x7pf-2jmj-pgcq](https://github.com/apple/containerization/security/advisories/GHSA-x7pf-2jmj-pgcq) - Creating a container or executing a container process can delete files outside its bundle through an unchecked id
- [GHSA-f689-h8m7-3jp2](https://github.com/apple/containerization/security/advisories/GHSA-f689-h8m7-3jp2) - `ContainerizationOCI` accepts unvalidated OCI descriptor digests, enabling path traversal in the local content store
- [GHSA-r3h2-rgqf-9hv9](https://github.com/apple/containerization/security/advisories/GHSA-r3h2-rgqf-9hv9) - Loading an OCI image layout can read host files through a symlink
- [GHSA-mx96-5vvg-x2mg](https://github.com/apple/containerization/security/advisories/GHSA-mx96-5vvg-x2mg) - CVE-2026-65388 - `RegistryClient` follows the `WWW-Authenticate` realm without validating its host or scheme
- [GHSA-697p-8837-37h3](https://github.com/apple/containerization/security/advisories/GHSA-697p-8837-37h3) - Unpacking a crafted image layer with a long(invalid) file name crashes the unpacking process
- [GHSA-g3rx-2m58-rr63](https://github.com/apple/containerization/security/advisories/GHSA-g3rx-2m58-rr63) - Unpacking a crafted image layer with an invalid length extended-attribute name crashes the unpacking process

## What's Changed
* Add container skill by @crosbymichael in https://github.com/apple/container/pull/2154
* Fix tmpfs mount source field left empty for --mount type=tmpfs by @sivasath16 in https://github.com/apple/container/pull/2138
* Update to containerization 0.42.0 by @katiewasnothere in https://github.com/apple/container/pull/2207

## New Contributors
* @sivasath16 made their first contribution in https://github.com/apple/container/pull/2138

**Full Changelog**: https://github.com/apple/container/compare/1.3.0...1.3.1
