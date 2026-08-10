# apple/container 1.2.2

Released 2026-08-08T01:33:50Z — https://github.com/apple/container/releases/tag/1.2.2

---

This release fixes a glitch that prevented `container k8s` working when installed from the release package.

## What's Changed
* Integration test: fix username/uid flake. by @jglogan in https://github.com/apple/container/pull/2086
* refactor: extract K8s logic into ContainerK8s library target by @jshi991 in https://github.com/apple/container/pull/2079
* Refactor `container k8s` to use plugin resource management. by @jglogan in https://github.com/apple/container/pull/2097
* Migrate ProgressBarTests to Swift Testing by @VictorPuga in https://github.com/apple/container/pull/2085

## New Contributors
* @VictorPuga made their first contribution in https://github.com/apple/container/pull/2085

**Full Changelog**: https://github.com/apple/container/compare/1.2.1...1.2.2
