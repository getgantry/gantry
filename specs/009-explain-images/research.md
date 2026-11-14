<!-- STE deviation: product names, Apple API names and paths stay verbatim. -->
# Research: Screenshots in Explain This Failure

## R1. The Foundation Models image API

- Decision: use `Attachment<ImageAttachmentContent>(cgImage)` inside the `@PromptBuilder` closure of `LanguageModelSession.respond(schema:options:prompt:)`. Check `SystemLanguageModel.default.capabilities.contains(.vision)`.
- Source: `MacOSX27.2.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface`. `Attachment`, `ImageAttachmentContent`, `LanguageModelCapabilities` and `.vision` are `@available(macOS 27.0, *)`. `DataAttachmentRepresentable` and `supportsDataAttachmentType(_:)` are macOS 27.2 and are for other data types, not needed here.
- Live probe (2026-11-14, macOS 27.2, this Mac): availability `available`, `vision` true, `toolCalling` true, `tokenCount(for: Attachment(1024×768 image))` = 195.
- Alternatives: `Transcript.ImageAttachment` in a hand-made transcript. More code, no gain.

## R2. Downscaling

- Decision: `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailFromImageAlways`, `kCGImageSourceCreateThumbnailWithTransform` and `kCGImageSourceThumbnailMaxPixelSize = min(1024, longer side)`. It decodes at the reduced size and applies the EXIF orientation.
- Rationale: one call, no full decode of large images, upright output, works in the package without AppKit.
- Alternatives: draw into a `CGContext`. That needs a full decode and manual orientation.

## R3. Which model gets the images

- Decision: only the on-device model. When the availability is `.available(.privateCloud)`, the controller reports no image support and the strip is hidden.
- Rationale: the request and the constitution (principle IV) say images stay on device. Text redaction cannot work on pixels.
- Alternatives: move the run to the on-device model when an image is attached. That changes the user's model choice without a prompt. Rejected for this feature.

## R4. Token budget

- Decision: `FoundationModelsBudget.promptLimit(for:data:imageCount:)` subtracts the measured token count of the prepared images (`tokenCount(for: Attachment)` on macOS 27), with 260 tokens per image as the fallback.
- Rationale: the small on-device window is 4096 tokens. Three images take about 600 tokens, so the logs must shrink.

## R5. Paste and drop in SwiftUI on macOS

- Decision: `.onDrop(of: [.fileURL, .image])` on the panel, `.onPasteCommand(of: [.fileURL, .png, .tiff, .image])` on the panel (the panel is focusable), and `.fileImporter(allowedContentTypes: [.image], allowsMultipleSelection: true)` for "Add Image…". All three paths give `Data` or a file URL to `ExplainImagePreparer`.
- Rationale: standard system behaviors (HIG). The data source does not matter to AppCore.
