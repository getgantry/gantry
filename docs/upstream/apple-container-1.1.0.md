# apple/container 1.1.0

Released 2026-07-06T19:47:13Z — https://github.com/apple/container/releases/tag/1.1.0

---

## Highlights 

⌨️ denotes breaking CLI changes.

👩‍💻 denotes breaking API changes.

- Core
  - [Unix domain socket mounts now work in non-root containers](https://github.com/apple/container/issues/1750).
- Storage
  - [Fix `container cp` failures with relative source paths](https://github.com/apple/container/issues/1738)

## What's Changed
* Bump containerization to `0.33.4` by @dkovba in https://github.com/apple/container/pull/1650
* add standalone container machine document by @crosbymichael in https://github.com/apple/container/pull/1674
* Adds container machine example. by @jglogan in https://github.com/apple/container/pull/1676
* Always update default network with system configuration values by @katiewasnothere in https://github.com/apple/container/pull/1686
* ci: bump actions/checkout from 6.0.2 to 6.0.3 in the github-actions group across 1 directory by @dependabot[bot] in https://github.com/apple/container/pull/1640
* Fix duplicate "(default: 3)" in --max-concurrent-downloads help text by @CharlieTLe in https://github.com/apple/container/pull/1725
* add container machine nested virt by @crosbymichael in https://github.com/apple/container/pull/1742
* Pin xcode swift version in CI to 6.3 by @katiewasnothere in https://github.com/apple/container/pull/1746
* Propagate permissions for all host-to-container socket mounts. by @jglogan in https://github.com/apple/container/pull/1751
* Fix CLITest when run in xcode by @mareksapota in https://github.com/apple/container/pull/1775
* [package]: bump containerization to 0.34.0 by @saehejkang in https://github.com/apple/container/pull/1774
* fix(cp): resolve relative host paths against current directory by @adityabagchi24 in https://github.com/apple/container/pull/1741
* fix: replace try! with try? for stdout/stderr writes in ProcessIO by @SEPURI-SAI-KRISHNA in https://github.com/apple/container/pull/1784
* fix: remove force-unwrap on session dictionary in DefaultNetworkService by @SEPURI-SAI-KRISHNA in https://github.com/apple/container/pull/1787
* Log the graceful-stop error instead of silently discarding it in gracefulStopContainer by @radheradhe01 in https://github.com/apple/container/pull/1782
* Disable flaky CLI test temporarily. by @jglogan in https://github.com/apple/container/pull/1828
* Fix/exec empty arguments crash by @SEPURI-SAI-KRISHNA in https://github.com/apple/container/pull/1783
* Remove network variant computation from API server. by @jglogan in https://github.com/apple/container/pull/1814
* Remove duplicate release workflow that double-builds and races on every tag by @radheradhe01 in https://github.com/apple/container/pull/1781
* perf(parser): add collection capacity hints to known-size loops by @hluaguo in https://github.com/apple/container/pull/1791
* fix: propagate error from createDirectory in system start by @SEPURI-SAI-KRISHNA in https://github.com/apple/container/pull/1785
* ci: bump the github-actions group across 1 directory with 2 updates by @dependabot[bot] in https://github.com/apple/container/pull/1792
* Route `container image save` reference list to stderr in stdout mode by @costajohnt in https://github.com/apple/container/pull/1804
* Enhanced test fixtures for integration tests. by @jglogan in https://github.com/apple/container/pull/1834
* Migrate some container tests, remove concurrent demo tests. by @jglogan in https://github.com/apple/container/pull/1840
* Update containerization import to 0.35.0 by @katiewasnothere in https://github.com/apple/container/pull/1842
* Adds build fixture and migrates build CLI tests. by @jglogan in https://github.com/apple/container/pull/1848
* Migrates container machine tests. by @jglogan in https://github.com/apple/container/pull/1856
* Migrate basic system tests to new test support types. by @jglogan in https://github.com/apple/container/pull/1841
* Migrates network integration tests. by @jglogan in https://github.com/apple/container/pull/1858
* Migrate registry tests to new test support types. by @jglogan in https://github.com/apple/container/pull/1845
* Add checksum validation to hawkeye installation by @katiewasnothere in https://github.com/apple/container/pull/1869
* Migrate image, volume and miscellaneous system tests. by @jglogan in https://github.com/apple/container/pull/1868
* Migrates container create, run-lifecycle, exec, remove, copy. by @jglogan in https://github.com/apple/container/pull/1844
* Migrates container run integration tests. by @jglogan in https://github.com/apple/container/pull/1857
* Ensure test filenames match test suite names and each file has a single suite defined by @katiewasnothere in https://github.com/apple/container/pull/1877
* Finalize Makefile for integration test rework. by @jglogan in https://github.com/apple/container/pull/1878

## New Contributors
* @CharlieTLe made their first contribution in https://github.com/apple/container/pull/1725
* @mareksapota made their first contribution in https://github.com/apple/container/pull/1775
* @adityabagchi24 made their first contribution in https://github.com/apple/container/pull/1741
* @SEPURI-SAI-KRISHNA made their first contribution in https://github.com/apple/container/pull/1784
* @radheradhe01 made their first contribution in https://github.com/apple/container/pull/1782
* @hluaguo made their first contribution in https://github.com/apple/container/pull/1791
* @costajohnt made their first contribution in https://github.com/apple/container/pull/1804

**Full Changelog**: https://github.com/apple/container/compare/1.0.0...1.1.0
