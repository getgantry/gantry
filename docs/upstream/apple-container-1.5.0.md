# apple/container 1.5.0

Released 2026-09-29T02:33:21Z — https://github.com/apple/container/releases/tag/1.5.0

---

## Highlights

⌨️ denotes breaking CLI changes.

👩‍💻 denotes breaking API changes.

- Security
  - [GHSA-44v5-vx46-ghv6](https://github.com/apple/container/security/advisories/GHSA-44v5-vx46-ghv6) - K8s Plugin: sanitize kubeconfig values from guest before merging with host kubeconfig
- Core
  - [Commands now run when the image entrypoint is empty](https://github.com/apple/container/pull/2296)
  - [Fixed container egress loss after localhost DNS changes](https://github.com/apple/container/pull/2256)
  - [Better error message for unknown commands](https://github.com/apple/container/pull/2311)
- Kubernetes
  - ⌨️ [Removed `container k8s start` for now. To restart a stopped node, delete the cluster and create it again](https://github.com/apple/container/pull/2290)
  - [New `--cni` option on `container k8s create` for a custom CNI manifest](https://github.com/apple/container/pull/2254)
## What's Changed
* Update README as v1.0.0 has been reached by @gvenzl in https://github.com/apple/container/pull/2233
* Fix a compilation warning by @dkovba in https://github.com/apple/container/pull/2251
* Fix container egress loss after localhost DNS changes by @realrajaryan in https://github.com/apple/container/pull/2256
* forwarder: close backend channel immediately if frontend closes by @egernst in https://github.com/apple/container/pull/2260
* docs: use an existing kindest/node tag in the k8s node image example by @saiyam1814 in https://github.com/apple/container/pull/2257
* K8s plugin: Support custom CNI manifest by @katiewasnothere in https://github.com/apple/container/pull/2254
* fix(k8s): correct k8s control plane components version using the user specified node image version by @zdk in https://github.com/apple/container/pull/2271
* Fix Globber dropping directory contents under a symlinked ancestor by @JaewonHur in https://github.com/apple/container/pull/2252
* Remove k8s start command for now by @katiewasnothere in https://github.com/apple/container/pull/2290
* Sync command reference with current CLI options by @rishabhsai in https://github.com/apple/container/pull/2265
* Run commands when image entrypoint is empty by @danielsyauqi in https://github.com/apple/container/pull/2296
* fix(k8s): use the node's configured iptables backend for node prep by @guanchzhou in https://github.com/apple/container/pull/2145
* Update to latest containerization@0.47.0 by @katiewasnothere in https://github.com/apple/container/pull/2301
* Better error message for unknown commands by @realrajaryan in https://github.com/apple/container/pull/2311
* Remove PLUGINS section from help message by @JaewonHur in https://github.com/apple/container/pull/2309
* K8s Plugin: sanitize kubeconfig values from guest before merging with host kubeconfig by @katiewasnothere in https://github.com/apple/container/pull/2310
* Update plugin error test by @realrajaryan in https://github.com/apple/container/pull/2313

## New Contributors
* @gvenzl made their first contribution in https://github.com/apple/container/pull/2233
* @saiyam1814 made their first contribution in https://github.com/apple/container/pull/2257
* @rishabhsai made their first contribution in https://github.com/apple/container/pull/2265
* @danielsyauqi made their first contribution in https://github.com/apple/container/pull/2296
* @guanchzhou made their first contribution in https://github.com/apple/container/pull/2145

**Full Changelog**: https://github.com/apple/container/compare/1.4.1...1.5.0
