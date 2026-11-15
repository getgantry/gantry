# Tasks: Tests That Wait for Events

**Input**: `/specs/015-ci-test-waits/`

- [x] T001 [US1] In `terminateClosesConnection`, wait until `closed.wasClosed` is true, at most 300 × 10 ms
- [x] T002 [US1] In `writeFailureSurfacesViaOnError`, wait until the error arrives, at most 300 × 10 ms
- [x] T005 [US1] In `sendPumpsToConnection`, wait until two writes arrive, at most 300 × 10 ms (it failed on the CI rerun of PR #73)
- [x] T003 Run `swift test --filter ExecSessionTests` for AppCore (7 tests pass)
- [x] T006 [US1] In `DiskAccessGateTests`, make the probe in `slowCheckReportsThePermissionPrompt` 5 s and in `cancelEndsTheWaitAtOnce` 6 s, with a limit of 3 s (the 800 ms limit failed on the CI run of PR #73)
- [x] T004 Check SC-001: three CI runs of the AppCore job pass (PRs #73, #72, #70, #66 and #80)
