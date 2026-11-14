<!-- STE deviation: spec-kit template headings, the quoted user input, Given-When-Then scenarios, product names, file system names and paths stay verbatim. -->
# Feature Specification: Screenshots in Explain This Failure

**Feature Branch**: `feat/explain-images`

**Created**: 2026-11-14

**Status**: Draft

**Input**: User description: "Extend the existing Explain this failure feature (Foundation Models) so the user can attach images (drag and drop, paste, or pick a file; e.g. a screenshot of a browser error) that go to the on-device model as image input on macOS 27. Gate with #available and on model capability; on macOS 26 or when image input is unavailable, hide the attach control. Keep the existing privacy rules (on-device only, only suggest commands). Limit size/count, downscale before sending."

## Context

Explain this failure (0.26) sends redacted logs and container facts to the Apple Intelligence model. Some failures show only outside the logs. For example, a browser shows "502 Bad Gateway", or a client app shows a stack trace. The user can show this to the model as a screenshot. On macOS 27 the on-device model accepts images when it has the vision capability.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Attach a screenshot and get an explanation that uses it (Priority: P1)

A web container returns errors. The user opens Explain for the container. The user drags a screenshot of the browser error into the Explain window. Gantry shows a thumbnail of the image and runs the analysis again with the image. The cause and the next steps can refer to what the screenshot shows.

**Why this priority**: This is the feature. Without it, nothing else has a use.

**Independent Test**: On a Mac with macOS 27 and Apple Intelligence on, open Explain for a failed container, drop a PNG file into the window. A thumbnail shows, the analysis runs again, and the model receives one image.

**Acceptance Scenarios**:

1. **Given** macOS 27, the on-device model with image input, and an open Explain window, **When** the user drops an image file into the window, **Then** Gantry shows a thumbnail and runs the analysis again with the image.
2. **Given** the same state, **When** the user chooses "Add Image…" and selects two files, **Then** Gantry shows two thumbnails and runs the analysis again with both images.
3. **Given** the same state and an image on the clipboard, **When** the user pastes (Command-V) into the window, **Then** Gantry adds the image as with a drop.
4. **Given** one attached image, **When** the user removes it, **Then** the thumbnail goes away and the analysis runs again without images.
5. **Given** a Docker host, an Apple `container` host, or a failed operation in Activity, **When** the user attaches an image, **Then** the behavior is the same for each.

---

### User Story 2 - No attach control where images cannot be used (Priority: P1)

On macOS 26, on a model without image input, or when the analysis runs on Private Cloud Compute, the Explain window looks as in 0.27. There is no attach control. A drop or a paste does nothing.

**Why this priority**: The constitution requires a working fallback on macOS 26. An image must never leave the Mac.

**Independent Test**: Run with the Private Cloud Compute setting on (or on macOS 26). The Explain window has no "Add Image…" control and no image strip.

**Acceptance Scenarios**:

1. **Given** macOS 26, **When** the user opens Explain, **Then** there is no attach control.
2. **Given** macOS 27 and a model that reports no vision capability, **When** the user opens Explain, **Then** there is no attach control.
3. **Given** the setting "Use Private Cloud Compute" is on and Private Cloud Compute is available, **When** the user opens Explain, **Then** there is no attach control and no image goes to Private Cloud Compute.
4. **Given** Explain is not available (Apple Intelligence off, turned off in Settings), **When** the user opens Explain, **Then** there is no attach control.

---

### User Story 3 - Limits and clear rejections (Priority: P2)

The user tries to add too many images, a very large file, or a file that is not an image. Gantry refuses that item, says why in one line, and keeps the images that are already there. Gantry makes large images smaller before it sends them, so the analysis stays fast.

**Why this priority**: Without limits, a large image fills the context window of the small model or makes the analysis slow.

**Independent Test**: Unit tests feed the preparation logic a 4000×3000 image, a file over the size limit, a text file and a fourth image. The results are a 1024 px image and three rejections with the correct reasons.

**Acceptance Scenarios**:

1. **Given** three attached images, **When** the user adds one more, **Then** Gantry refuses it with "You can attach up to 3 images."
2. **Given** a file of more than 20 MB, **When** the user adds it, **Then** Gantry refuses it with a message that names the limit.
3. **Given** a text file, **When** the user drops it, **Then** Gantry refuses it with "This file is not an image."
4. **Given** an image of 4000×3000 pixels, **When** the user adds it, **Then** the model receives an image of 1024×768 pixels.

### Edge Cases

- The user drops several files at once, and the total is more than the limit: Gantry adds the first files up to the limit and refuses the rest.
- The user adds an image while an analysis runs: the running analysis stops, and a new one starts with all images.
- The model throws a context overflow with images attached: Gantry asks once more with fewer log lines and keeps the images, the same as without images.
- A screenshot can show secrets (tokens in a browser, passwords). Gantry cannot redact text in an image. The image stays on this Mac, and the window says that Gantry does not hide secrets in images.
- "Copy as Prompt" stays text only. It does not include the images.
- The images live only in the open Explain window. Gantry does not save them. When the window closes, they are gone.
- An image with EXIF orientation: Gantry sends it upright.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The Explain window MUST let the user add images in three ways: drop files or images into the window, paste from the clipboard, and choose files with "Add Image…".
- **FR-002**: Gantry MUST show the attach control, accept drops and accept pastes only when all are true: the OS is macOS 27 or later, the analysis runs on the on-device model, and that model reports the vision capability.
- **FR-003**: Gantry MUST never send an image to Private Cloud Compute or to any other service off this Mac.
- **FR-004**: Gantry MUST accept at most 3 images per Explain window and at most 20 MB per source file.
- **FR-005**: Gantry MUST refuse an item that is not a readable image, with a one-line reason, and keep the other images.
- **FR-006**: Gantry MUST make each image smaller before it sends it, so that the longer side is at most 1024 pixels, keep the aspect ratio, and apply the image orientation. Gantry MUST not make small images larger.
- **FR-007**: Each attached image MUST show as a thumbnail with a remove control that has an accessibility label.
- **FR-008**: A change to the attached images MUST start the analysis again with the current images.
- **FR-009**: The prompt MUST tell the model that the images are screenshots from the user, and the instructions MUST keep the rules: base the cause on the facts, logs and images; only suggest commands; nothing runs automatically.
- **FR-010**: The token budget for the logs MUST leave room for the attached images.
- **FR-011**: When images are attached, the window MUST show a note that the images stay on this Mac and that Gantry does not hide secrets in images.
- **FR-012**: Every new user-facing string MUST be in the String Catalogs with all 28 languages.

### Key Entities

- **Explain image**: one prepared image for the model. It has an identifier, a display name, the downscaled pixel data, and its pixel size. It lives only in memory.
- **Image limits**: the maximum count (3), the maximum source size (20 MB), and the maximum pixel side (1024).
- **Rejection**: why an item was refused: too many images, file too large, not an image.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With a supported model, a user attaches a screenshot in one action (drop, paste or file choice) and sees a new explanation without other steps.
- **SC-002**: No image of more than 1024 pixels on the longer side reaches the model (unit tests).
- **SC-003**: On macOS 26, with Private Cloud Compute, or without the vision capability, the Explain window shows no attach control (code gate and live check).
- **SC-004**: `scripts/check-localization.py` reports 0 problems.

## Assumptions

- The on-device model of macOS 27 reports `vision` in its capabilities on supported Macs. If it does not, the feature stays hidden. That is the intended fallback.
- When the user turns on Private Cloud Compute, the user chose the larger model for long logs. In that mode the attach control is hidden. We do not move the run to the on-device model when an image is attached.
- The images are for the current window only. Saving images or sending them to MCP clients is out of scope.
