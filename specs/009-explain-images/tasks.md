<!-- STE deviation: spec-kit template headings, Swift identifiers, product names and paths stay verbatim. -->
# Tasks: Screenshots in Explain This Failure

**Input**: Design documents from `/specs/009-explain-images/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md

**Tests**: the constitution requires Swift Testing tests for AppCore logic.

## Phase 1: Setup

- [ ] T001 Read the Foundation Models image API in the installed SDK and record it in specs/009-explain-images/research.md (R1), with a live probe of `capabilities.contains(.vision)` and the token cost of one image

## Phase 2: Foundational (blocks all stories)

- [ ] T002 Add `ExplainImage`, `ExplainImageLimits` (`maxCount` 3, `maxBytes` 20 × 1024 × 1024, `maxPixelSide` 1024), `ExplainImageRejection` (`tooMany`, `tooLarge`, `notAnImage`, localized texts) and `ExplainImagePreparer` (ImageIO thumbnail, orientation applied, no upscale) in Packages/AppCore/Sources/AppCore/Explain/ExplainImage.swift
- [ ] T003 Change `FailureExplaining.explain` to take `images: [ExplainImage]` and keep a two-argument convenience in Packages/AppCore/Sources/AppCore/Explain/ExplainBackend.swift
- [ ] T004 [P] Tests for the preparer and limits (downscale 4000×3000 to 1024×768, small image unchanged, EXIF orientation, not an image, too large) in Packages/AppCore/Tests/AppCoreTests/ExplainImageTests.swift

## Phase 3: User Story 1 - Attach a screenshot and get an explanation that uses it (P1)

**Goal**: images go to the on-device model with the context.

**Independent test**: controller and explainer tests with a fake responder; live test with the real model.

- [ ] T005 [US1] `ExplainController`: `images`, `lastRejection`, `addImages(_:)`, `removeImage(id:)`, restart on change, images and image count passed to the explainer and to `gather` in Packages/AppCore/Sources/AppCore/Explain/ExplainController.swift
- [ ] T006 [US1] `ExplainModelResponder.respond(instructions:prompt:images:tools:)`; `SystemModelResponder` builds the prompt with `Attachment(cgImage).label(name)` on macOS 27; the prompt says that the user attached N screenshots; the overflow retry keeps the images; instructions mention screenshots in Packages/AppCore/Sources/AppCore/Explain/FoundationModelsExplainer.swift
- [ ] T007 [US1] `FoundationModelsBudget.promptLimit(for:data:imageCount:)` reserves the measured token cost of the images in Packages/AppCore/Sources/AppCore/Explain/FoundationModelsExplainer.swift
- [ ] T008 [P] [US1] Tests: controller passes images and restarts on add and remove; explainer sends images to the responder and keeps them on retry; prompt text names the images in Packages/AppCore/Tests/AppCoreTests/ExplainTests.swift
- [ ] T009 [US1] Image strip (thumbnails with a labeled remove button), "Add Image…" with `fileImporter`, drop target and paste command, privacy note in App/Views/Explain/ExplainAttachments.swift and App/Views/Explain/ExplainPanel.swift
- [ ] T010 [US1] Wire the image gate and the image budget for containers and operations in App/Views/Explain/ExplainTarget.swift
- [ ] T011 [US1] Opt-in live test `liveExplainWithImage` with the real on-device model in Packages/AppCore/Tests/AppCoreTests/LiveExplainTests.swift

## Phase 4: User Story 2 - No attach control where images cannot be used (P1)

**Goal**: hidden on macOS 26, without `vision`, with Private Cloud Compute, and when Explain is not available.

- [ ] T012 [US2] `FoundationModelsAvailability.supportsImages(for:)`: macOS 27, `.onDevice` and `capabilities.contains(.vision)`; false for `.privateCloud` in Packages/AppCore/Sources/AppCore/Explain/FoundationModelsExplainer.swift
- [ ] T013 [US2] `ExplainController.supportsImages` false when unavailable or private cloud; `addImages` does nothing then; tests in Packages/AppCore/Tests/AppCoreTests/ExplainTests.swift
- [ ] T014 [US2] The panel shows no strip, no button, no drop target and no paste handler when `supportsImages` is false in App/Views/Explain/ExplainPanel.swift

## Phase 5: User Story 3 - Limits and clear rejections (P2)

- [ ] T015 [US3] `addImages` stops at 3 images, keeps the existing ones and records the first rejection; the strip shows the rejection text; tests in Packages/AppCore/Tests/AppCoreTests/ExplainImageTests.swift

## Phase 6: Polish

- [ ] T016 Translations of all new strings for 28 languages in App/Localizable.xcstrings and Packages/AppCore/Sources/AppCore/Resources/Localizable.xcstrings; `scripts/check-localization.py` reports 0 problems
- [ ] T017 Debug build with `xcodebuild -jobs 3` to /Volumes/SanDisk2Tb/builds/gantry/explain-images/DerivedData and the AppCore tests pass
- [ ] T018 Live check of the Debug build with `scripts/gantry-ctl` and a failed Apple `container` container named `gei-fail` (quickstart.md); remove the container after the check
- [ ] T019 Rebase on `origin/main`, open the pull request "feat: attach screenshots to explain this failure"

## Dependencies

- T002, T003 block all later tasks. T005–T007 block T009–T010. T012 blocks T013–T014.
- US2 and US3 depend on the controller of US1 (T005).

## Parallel Opportunities

- T004 and T008 are test files and can be written while T005–T007 are written.

## Implementation Strategy

MVP: Phases 1–4 (US1 and US2 together, because the gate is part of a safe release). US3 adds the limit messages.
