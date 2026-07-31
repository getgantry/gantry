# apple/container 1.2.0

Released 2026-07-29T00:41:28Z — https://github.com/apple/container/releases/tag/1.2.0

---

## What's Changed
* Add TestCLISystemLogs and TestCLITermIO integration tests in new integration test suite by @katiewasnothere in https://github.com/apple/container/pull/1879
* Restore reverted migrations, migrate last tests. by @jglogan in https://github.com/apple/container/pull/1880
* Removes obsolete CLITests directory. by @jglogan in https://github.com/apple/container/pull/1886
* Integration coverage xpc helpers by @noah-thor in https://github.com/apple/container/pull/1551
* Upgrade grpc-swift-nio-transport to 2.9.0 and remove HTTP2ConnectBuff… by @adityabagchi24 in https://github.com/apple/container/pull/1790
* Updates containerization to 0.36.0. by @jglogan in https://github.com/apple/container/pull/1912
* Use containerization version 0.37.0 by @adityaramani in https://github.com/apple/container/pull/1932
* Verify kernel archive integrity by @haoruilee in https://github.com/apple/container/pull/1703
* Add commit/issue alert to PR template. by @jglogan in https://github.com/apple/container/pull/1945
* Remove `--skip-build` from test Makefile target. by @jglogan in https://github.com/apple/container/pull/1951
* Restore `--skip-build`, enable `import testable` for release builds. by @jglogan in https://github.com/apple/container/pull/1955
* [package]: bump container-builder-shim to 0.13.0 by @saehejkang in https://github.com/apple/container/pull/1953
* Validate container ID from XPC requests by @katiewasnothere in https://github.com/apple/container/pull/1956
* Remove force unwraps on XPC error set/get by @katiewasnothere in https://github.com/apple/container/pull/1958
* Do not follow destination symlink when copying user configuration by @katiewasnothere in https://github.com/apple/container/pull/1957
* Fix machine ID length test. by @jglogan in https://github.com/apple/container/pull/1971
* Address flaky TestCLIKernelSetSerial suite. by @jglogan in https://github.com/apple/container/pull/1976
* [gitignore]: ignore vscode workspace files by @saehejkang in https://github.com/apple/container/pull/1966
* Update containerization dependency with new EXT4Unpacker func definition by @katiewasnothere in https://github.com/apple/container/pull/1973
* Periodic dependency updates. by @jglogan in https://github.com/apple/container/pull/1981
* Use ordered journal mode for unpacked images. by @jglogan in https://github.com/apple/container/pull/1974
* Reword DNS container name resolution doc information by @katiewasnothere in https://github.com/apple/container/pull/1960
* ci: bump the github-actions group across 1 directory with 3 updates by @dependabot[bot] in https://github.com/apple/container/pull/1983
* Pass build config in when building protoc dependencies by @katiewasnothere in https://github.com/apple/container/pull/1972
* Container test fixture package by @katiewasnothere in https://github.com/apple/container/pull/1887
* Downgrade swift-collections to 1.5.1. by @jglogan in https://github.com/apple/container/pull/1984
* Use `enum` for warmup images. by @jglogan in https://github.com/apple/container/pull/1990
* Add missing dependencies to new ContainerTestSupport package by @katiewasnothere in https://github.com/apple/container/pull/1994
* Add OCI maskedPaths and readonlyPaths support to Container API. by @jglogan in https://github.com/apple/container/pull/1996
* Integration test - miscellaneous fixture and test refinements. by @jglogan in https://github.com/apple/container/pull/1993
* Use log instead of print for system start status messages by @adityabagchi24 in https://github.com/apple/container/pull/1889
* Fix BuilderStart race, parallelize `container build` tests. by @jglogan in https://github.com/apple/container/pull/2002
* Allow custom kernel boot args via --kernel-arg by @arirubinstein in https://github.com/apple/container/pull/1744
* fix: Increase XPC timeout for Machine API operations by @dev-kvt in https://github.com/apple/container/pull/2006
* Update containerization import to latest 0.40.0 by @katiewasnothere in https://github.com/apple/container/pull/2028
* Fix image env vars, build context checks, TCP/UDP port forward buffer, and validate plugin name by @katiewasnothere in https://github.com/apple/container/pull/2027
* Update containerization import to 0.40.1 by @katiewasnothere in https://github.com/apple/container/pull/2038

## New Contributors
* @haoruilee made their first contribution in https://github.com/apple/container/pull/1703
* @arirubinstein made their first contribution in https://github.com/apple/container/pull/1744
* @dev-kvt made their first contribution in https://github.com/apple/container/pull/2006

**Full Changelog**: https://github.com/apple/container/compare/1.1.0...1.2.0
