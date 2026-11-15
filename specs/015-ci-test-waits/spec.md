<!-- STE deviation: spec-kit template headings, task format, product names, CLI flags and paths stay verbatim. -->
# Feature Specification: Tests That Wait for Events

**Feature Branch**: `test/exec-session-waits`
**Created**: 2026-11-15
**Status**: Implemented

## User Scenarios and Testing

### User Story 1 - CI gives the same result as a local run (Priority: P1)

A maintainer opens a pull request. The AppCore tests pass on the CI runner when they pass on the Mac.

**Why this priority**: A false failure blocks the merge of an unrelated pull request (PR #73 on 2026-11-15).

**Independent Test**: Run `ExecSessionTests` on a loaded machine. The result does not change.

**Acceptance Scenarios**:

1. **Given** a slow CI runner, **When** `terminateClosesConnection` runs, **Then** the test waits for the close. The wait is 3 s at most.
2. **Given** a slow CI runner, **When** `writeFailureSurfacesViaOnError` runs, **Then** the test waits for the error. The wait is 3 s at most.
3. **Given** a slow CI runner, **When** `sendPumpsToConnection` runs, **Then** the test waits for the two writes. The wait is 3 s at most.

## Requirements

- **FR-001**: The tests in `ExecSessionTests` MUST NOT use a fixed sleep as the only wait before an assertion.
- **FR-002**: Each wait MUST end at the event, with a time limit of 3 s.

## Success Criteria

- **SC-001**: `ExecSessionTests` passes on CI in the next three runs of the AppCore job.
