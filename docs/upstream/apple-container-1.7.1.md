# apple/container 1.7.1

Released 2026-11-06T23:56:02Z — https://github.com/apple/container/releases/tag/1.7.1

---

## Highlights

⌨️ denotes breaking CLI changes.

👩‍💻 denotes breaking API changes.

- Core
  - [`container stats` now reports `cpuUtilization` in JSON, YAML, and TOML output](https://github.com/apple/container/pull/2146)
  - [Image snapshots and container filesystems are now excluded from Time Machine backups](https://github.com/apple/container/pull/2412)
  - [Default Kata kernel is now 4.3.1 (`vmlinux-6.18.56-208-debug`)](https://github.com/apple/container/pull/2447)
  - [Updated Containerization to 0.54.0](https://github.com/apple/container/pull/2443)
- Networking
  - [Default DNS nameservers, search domains, and options can now be set in `config.toml`](https://github.com/apple/container/pull/1614)
- Build
  - [Fixed `container build` failures with newer BuildKit](https://github.com/apple/container/pull/2428) and [missing build context for steps that need the full context](https://github.com/apple/container/pull/2414)
- Kubernetes
  - ⌨️ [New `--shared-image-store` option on `container cluster run` to use the `container` image store from cluster nodes; removed the `load-image` subcommand](https://github.com/apple/container/pull/2437)
  - ⌨️ [`container cluster ls` now shows one row per cluster; use `--nodes` for the per-node view](https://github.com/apple/container/pull/2451)
  - ⌨️ [Container lifecycle commands no longer operate on cluster nodes](https://github.com/apple/container/pull/2462)
  - [Worker node CPU and memory can now be set with `--workers count=<n>,cpus=<n>,memory=<size>`](https://github.com/apple/container/pull/2448)

## What's Changed
* Send an :authority on the builder gRPC connection by @jglogan in https://github.com/apple/container/pull/2428
* Adds `container cluster` example. by @jglogan in https://github.com/apple/container/pull/2433
* Update container-builder-shim to 0.13.3. by @jglogan in https://github.com/apple/container/pull/2434
* use macos 27 runners by @madrob in https://github.com/apple/container/pull/2436
* Fix empty followpaths handling in BuildFSSync by @onlyarnav in https://github.com/apple/container/pull/2414
* Document container clean in the reclaim disk space guide by @lucasbrito-wdt in https://github.com/apple/container/pull/2413
* Bump to use containerization 0.54.0 by @adityaramani in https://github.com/apple/container/pull/2443
* feat(stats): report cpuUtilization in the machine-readable formats by @guanchzhou in https://github.com/apple/container/pull/2146
* [k8s plugin] Create a cluster bootstrapper by @katiewasnothere in https://github.com/apple/container/pull/2416
* Update recommended kernel to kata 4.3.1 release vmlinux-6.18.56-208-debug by @katiewasnothere in https://github.com/apple/container/pull/2447
* Add TOML configuration for default DNS nameservers, search, options by @0xMH in https://github.com/apple/container/pull/1614
* Add the ability to share container's image store with container cluster by @crosbymichael in https://github.com/apple/container/pull/2437
* Reduce install package size and install footprint. by @jglogan in https://github.com/apple/container/pull/2458
* Add reference to apple/container-examples and remove examples/ out of this repo by @michaelzhang114 in https://github.com/apple/container/pull/2457
* Create container-core-clusters XPC service by @adityaramani in https://github.com/apple/container/pull/2451
* Exclude recreatable container data from Time Machine by @abdullahtas0 in https://github.com/apple/container/pull/2412
* Clean the `cluster-shim` build files with `make clean` by @dkovba in https://github.com/apple/container/pull/2463
* Quiet the `cluster-shim` build output and show the swift progress in place by @dkovba in https://github.com/apple/container/pull/2461
* Do not allow high level container lifecycle commands to operate on cluster nodes by @katiewasnothere in https://github.com/apple/container/pull/2462
* Switch to copy blobs by @crosbymichael in https://github.com/apple/container/pull/2470
* Add option to set cpus and memory resources for worker nodes of cluster by @katiewasnothere in https://github.com/apple/container/pull/2448
* Removed bug-report-how-to.md as this info is now consolidated in CONTRIBUTING.md by @michaelzhang114 in https://github.com/apple/container/pull/2459
* Move HostStoreServer into a library so tests don't link the executable by @katiewasnothere in https://github.com/apple/container/pull/2477

## New Contributors
* @madrob made their first contribution in https://github.com/apple/container/pull/2436
* @onlyarnav made their first contribution in https://github.com/apple/container/pull/2414
* @lucasbrito-wdt made their first contribution in https://github.com/apple/container/pull/2413
* @abdullahtas0 made their first contribution in https://github.com/apple/container/pull/2412

**Full Changelog**: https://github.com/apple/container/compare/1.6.1...1.7.1
