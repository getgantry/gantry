<!-- STE deviation: Swift identifiers stay verbatim. -->
# Data Model: Screenshots in Explain This Failure

## ExplainImage (AppCore, in memory)

| Field | Type | Rule |
|---|---|---|
| `id` | `UUID` | unique in the window |
| `name` | `String` | file name, or "Pasted Image" |
| `cgImage` | `CGImage` | downscaled, upright, longer side ≤ 1024 px |
| `pixelSize` | `(width: Int, height: Int)` | size of `cgImage` |

## ExplainImageLimits

| Field | Value |
|---|---|
| `maxCount` | 3 |
| `maxBytes` | 20 × 1024 × 1024 |
| `maxPixelSide` | 1024 |

## ExplainImageRejection

`tooMany(limit:)`, `tooLarge(limitMB:)`, `notAnImage`. Each has a localized one-line text in AppCore.

## ExplainController changes

- `images: [ExplainImage]` (observable), `lastRejection: ExplainImageRejection?`.
- `supportsImages: Bool`: true only when availability is `.available(.onDevice)` and the injected `imageSupport(kind)` is true.
- `addImages(_ items: [ExplainImageSource])`: prepares each item, stops at `maxCount`, records the first rejection, restarts the analysis when at least one image was added.
- `removeImage(id:)`: removes it and restarts the analysis.
- `start()` passes `images` to the explainer and the image count to `gather` only when `supportsImages`.

State: images do not change the phase machine (`idle → gathering → thinking → done | failed`). A change of images calls `start()`, which cancels the current run.
