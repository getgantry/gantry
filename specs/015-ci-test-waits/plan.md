<!-- STE deviation: spec-kit template headings, task format, product names, CLI flags and paths stay verbatim. -->
# Implementation Plan: Tests That Wait for Events

**Branch**: `test/exec-session-waits` | **Date**: 2026-11-15 | **Spec**: [spec.md](spec.md)

## Summary

Three tests in `Packages/AppCore/Tests/AppCoreTests/ExecAndHeadlessTests.swift` slept 50 ms or 100 ms and then checked the result. On a loaded CI runner, the event can come later. Replace each sleep with a loop that checks the condition every 10 ms, at most 300 times.

## Constitution Check

- Principle II (logic in packages with tests): only test code changes. No product code changes.

## Files

- `Packages/AppCore/Tests/AppCoreTests/ExecAndHeadlessTests.swift`
