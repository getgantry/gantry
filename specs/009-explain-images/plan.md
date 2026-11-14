<!-- STE deviation: spec-kit template headings, product names, Apple API names, Swift identifiers and paths stay verbatim. -->
# Implementation Plan: Screenshots in Explain This Failure

**Branch**: `feat/explain-images` | **Date**: 2026-11-14 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/009-explain-images/spec.md`

## Summary <!-- slop: spec-kit template heading -->

The Explain window gets an image strip and an "Add Image…" control. Drops, pastes and file choices go to AppCore, which checks the limits, makes each image smaller with ImageIO and keeps it in `ExplainController`. The controller sends the images to the explainer only when the run is on device and the model has the `vision` capability. `FoundationModelsExplainer` puts each image into the prompt as `Attachment<ImageAttachmentContent>` (macOS 27 SDK) after the text context.

API facts, read from `FoundationModels.swiftinterface` of the MacOSX27.2 SDK (Xcode 27.2, research.md R1):

- `SystemLanguageModel` conforms to `LanguageModel` on macOS 27 and has `capabilities: LanguageModelCapabilities`. `LanguageModelCapabilities.contains(.vision)` tells if the model takes images.
- `Attachment<ImageAttachmentContent>.init(_ cgImage: CGImage, orientation:)` and `.label(_:)`, macOS 27. `Attachment` is `PromptRepresentable`, so it goes into a `@PromptBuilder` closure next to a `String`.
- `LanguageModelSession.respond(schema:includeSchemaInPrompt:options:prompt:)` takes a `@PromptBuilder` closure (macOS 26).
- `SystemLanguageModel.tokenCount(for: some PromptRepresentable)` (macOS 26.4) counts an attachment. A live probe on this Mac: one 1024×768 image is 195 tokens.

## Technical Context

**Language/Version**: Swift 6.4, Xcode 27.2 SDK. macOS 27 code is behind `#if compiler(>=6.4)` and `#available(macOS 27.0, *)`, as in `FoundationModelsExplainer.swift`.

**Primary Dependencies**: FoundationModels, ImageIO, CoreGraphics, UniformTypeIdentifiers, SwiftUI, AppKit (pasteboard). No new packages.

**Storage**: none. Images live in memory in the controller of one window.

**Testing**: Swift Testing in `Packages/AppCore/Tests/AppCoreTests/ExplainImageTests.swift` and new cases in `ExplainTests.swift`. Test images are made with `CGContext` and encoded with `CGImageDestination`, so the tests need no files. An opt-in live test extends `LiveExplainTests.swift`.

**Target Platform**: macOS 26 or later. The feature is on macOS 27 only.

**Project Type**: Desktop app (SwiftUI) with local Swift packages.

**Performance Goals**: preparation of one 4000×3000 image takes less than 0.5 s. Each image costs about 200 tokens.

**Constraints**: at most 3 images, at most 20 MB per source, longer side at most 1024 px. Builds go to `/Volumes/SanDisk2Tb/builds/gantry/explain-images/`.

**Scale/Scope**: about 4 new files, 6 changed files, 12 new strings.

## Constitution Check

- I. HIG, macOS 26 minimum: all macOS 27 API is behind `#available` with the 0.27 window as the fallback. The strip uses system thumbnails, an SF Symbol remove button and standard drop and paste. Pass.
- II. Logic in packages: limits, preparation, gating, prompt text and budget are in AppCore with tests. The views only read and send actions. New views are small helper views. Pass.
- III. No required dependencies: the feature works the same for Docker hosts, Apple `container` hosts and operations, because it uses only the Explain window. No CLI call changes. Pass.
- IV. Data and secret safety: images go only to the on-device model (FR-003). The window says that Gantry cannot redact text in images. Images are not saved. Pass.
- V. Strings: all new strings get 28 languages; `scripts/check-localization.py` must pass. Plurals are not needed: the count limit text uses a number in a fixed sentence with a plural variation. Pass.
- Accessibility: the remove button and the add button have labels; the rejection message is text, not color. Pass.

Post-design check: no change. No violations to justify.

## Project Structure

### Documentation (this feature)

```text
specs/009-explain-images/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
└── tasks.md
```

### Source Code (repository root)

```text
Packages/AppCore/Sources/AppCore/Explain/ExplainImage.swift          # new: ExplainImage, limits, preparer, rejection
Packages/AppCore/Sources/AppCore/Explain/ExplainBackend.swift        # explain(_:data:images:)
Packages/AppCore/Sources/AppCore/Explain/ExplainController.swift     # images, add/remove, image gate, restart
Packages/AppCore/Sources/AppCore/Explain/FoundationModelsExplainer.swift  # attachments, vision check, budget
Packages/AppCore/Tests/AppCoreTests/ExplainImageTests.swift          # new
Packages/AppCore/Tests/AppCoreTests/ExplainTests.swift               # controller and responder cases
App/Views/Explain/ExplainAttachments.swift                           # new: strip, add button, drop and paste
App/Views/Explain/ExplainPanel.swift                                 # place the strip, drop target, paste
App/Views/Explain/ExplainTarget.swift                                # wire image support and budget
App/Localizable.xcstrings
Packages/AppCore/Sources/AppCore/Resources/Localizable.xcstrings     # rejection texts
```

**Structure Decision**: extend the existing Explain module. No new package or target.

## Complexity Tracking

No violations.
