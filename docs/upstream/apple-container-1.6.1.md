# apple/container 1.6.1

Released 2026-10-23T23:26:12Z — https://github.com/apple/container/releases/tag/1.6.1

---

⌨️ denotes breaking CLI changes.

👩‍💻 denotes breaking API changes.

- Core
  - [Fix signals not properly passed to container processes](https://github.com/apple/container/pull/2276)
- Kubernetes
  - [Fix problems when creating clusters concurrently](https://github.com/apple/container/pull/2276)
  - [Rename to `container cluster`](https://github.com/apple/container/pull/2427)

## What's Changed
* Fix host port conflicts and leftover failed nodes during cluster creation by @dkovba in https://github.com/apple/container/pull/2399
* Fix forwarded process signal encoding by @vincent-peng in https://github.com/apple/container/pull/1778
* Remove SIGWINCH from signal kill set by @ArasanDev in https://github.com/apple/container/pull/1854
* Infer platform and runtime from OCI image by @noah-thor in https://github.com/apple/container/pull/2422
* rename to container cluster by @crosbymichael in https://github.com/apple/container/pull/2427

## New Contributors
* @vincent-peng made their first contribution in https://github.com/apple/container/pull/1778
* @ArasanDev made their first contribution in https://github.com/apple/container/pull/1854

**Full Changelog**: https://github.com/apple/container/compare/1.6.0...1.6.1
