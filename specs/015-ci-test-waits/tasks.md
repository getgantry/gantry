# Tasks: Tests That Wait for Events

**Input**: `/specs/015-ci-test-waits/`

- [x] T001 [US1] In `terminateClosesConnection`, wait until `closed.wasClosed` is true, at most 300 × 10 ms
- [x] T002 [US1] In `writeFailureSurfacesViaOnError`, wait until the error arrives, at most 300 × 10 ms
- [x] T003 Run `swift test --filter ExecSessionTests` for AppCore (7 tests pass)
- [ ] T004 Check SC-001: three CI runs of the AppCore job pass
