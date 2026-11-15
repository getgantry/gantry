<!-- STE deviation: spec-kit template headings, task format, product names, CLI flags and paths stay verbatim. -->
# Feature Specification: Image Archives With a Platform

**Feature Branch**: `fix/image-archive-platform`
**Created**: 2026-11-15
**Status**: Implemented

## User Scenarios and Testing

### User Story 1 - Save a multi-platform image on an Apple host (Priority: P1)

A user selects "Save to Archive…" for `alpine:3.22` on an Apple `container` host. Gantry writes the tar file.

**Why this priority**: The 1.7.1 release of Apple `container` has this defect. `container image save` with no `--platform` fails for an image with more than one platform. The error is "Error: content with digest sha256:…". Most images from Docker Hub have more than one platform.

**Independent Test**: Save `alpine:3.22` on an Apple host. The tar file is on the disk, and `container image load` reads it.

**Acceptance Scenarios**:

1. **Given** an Apple host and an image with a known platform, **When** the user saves the image, **Then** Gantry adds `--platform os/arch` of the image to `container image save`.
2. **Given** an Apple host and an image with no known platform, **When** the user saves the image, **Then** Gantry uses `linux/` and the architecture of the host.
3. **Given** a Docker host, **When** the user saves an image, **Then** the save does not change.

## Requirements

- **FR-001**: On an Apple host, `HostSession.saveImages` MUST give `--platform` to `container image save` when Gantry knows a platform.
- **FR-002**: The platform MUST come from the image. When the images of one save have different platforms or no platform, it MUST come from the host architecture.
- **FR-003**: The Docker path MUST not change.

## Success Criteria

- **SC-001**: On apple/container 1.7.1, "Save to Archive…" writes a tar file for `alpine:3.22`.
