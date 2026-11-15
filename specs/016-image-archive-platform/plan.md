<!-- STE deviation: spec-kit template headings, task format, product names, CLI flags and paths stay verbatim. -->
# Implementation Plan: Image Archives With a Platform

**Branch**: `fix/image-archive-platform` | **Date**: 2026-11-15 | **Spec**: [spec.md](spec.md)

## Summary

`ImageArchive.appleSaveArguments` gets an optional platform. `ImageArchive.applePlatform` selects it from the images of the save and the host architecture. It uses `ImageScanPlan.platformString`, so the names are the same as in the image scan (spec 011). `HostSession.saveImages` reads the images from `images` and `info`.

## Constitution Check

- Principle II (logic in packages with tests): the selection is a pure function in AppCore with unit tests.
- Principle III (version-gated CLI support): `--platform` is in `container image save` since 1.0.

## Files

- `Packages/AppCore/Sources/AppCore/Storage/VolumeTransfer.swift`
- `Packages/AppCore/Sources/AppCore/Storage/HostSession+Storage.swift`
- `Packages/AppCore/Tests/AppCoreTests/StorageTests.swift`
