# Tasks: Image Archives With a Platform

**Input**: `/specs/016-image-archive-platform/`

- [x] T001 [US1] Add an optional `platform` to `ImageArchive.appleSaveArguments` in `Packages/AppCore/Sources/AppCore/Storage/VolumeTransfer.swift`
- [x] T002 [US1] Add `ImageArchive.applePlatform(for:images:hostArchitecture:)`: one shared image platform, else the host platform
- [x] T003 [US1] Use it in `HostSession.saveImages` for Apple hosts in `Packages/AppCore/Sources/AppCore/Storage/HostSession+Storage.swift`
- [x] T004 [US1] Unit tests in `Packages/AppCore/Tests/AppCoreTests/StorageTests.swift`
- [x] T005 Run the `StorageTests` and `ImageScanTests` suites of AppCore
- [x] T006 Check SC-001: `container image save --platform linux/arm64` writes the tar file for `alpine:3.22`, and the command with no `--platform` fails
