# Gantry Constitution

Gantry is a free, open-source native macOS app for Apple's `container` tool, Docker hosts
(local and over SSH) and Kubernetes clusters. These rules
bind every change: features, fixes, refactors and chores.

## Core Principles

### I. Native Mac App, Apple HIG First

- Gantry is SwiftUI for macOS. The minimum is macOS 26. APIs from a newer macOS are
  used only behind `#available` checks with a working fallback.
- Layout, toolbars, sidebars, inspectors, materials (Liquid Glass), typography, SF Symbols
  and empty states follow Apple's Human Interface Guidelines. Liquid Glass is for floating
  controls, not for content.
- Text in a toolbar or a button never gets truncated. The UI must look right in light and
  dark mode, with Reduce Transparency and with Increase Contrast.

Rationale: users choose Gantry because it is a real Mac app, not a web view.

### II. Logic in Packages, Thin Views, Tests for Logic

- Logic lives in the Swift packages: AppCore, DockerKit, SSHKit, GantryMCP and GantryShared.
  SwiftUI views only present state and send actions.
- Every change to logic comes with Swift Testing tests in its package. Parsers of CLI or
  API output have tests with fixtures taken from the real tool.
- Side effects (processes, files, network, disks) are behind protocols so that tests do not
  touch the user's system.
- SwiftUI `body` expressions stay small. The CI runners time out on large type checks.

Rationale: the logic is where the bugs are, and it is the part that tests can reach.

### III. No Required Dependencies, Version-Gated Tool Support

- Gantry works with only Apple's `container` tool. Docker, `kubectl` and other tools are optional.
  A missing tool hides or explains a feature. It never shows the host as broken.
- Support for a feature of the `container` CLI is gated on the CLI version, so older
  supported versions keep working.
- Support for a new CLI release is verified against the real CLI output before the
  release claims it (a live run, or fixtures copied from a live run).

Rationale: "works right after `container system start`" is the product.

### IV. Safety of User Data and Secrets

- Every destructive action uses the shared confirmation (`DestructiveAction`) with
  Touch ID where the user turned it on. Bulk actions confirm once and list the items.
- Gantry deletes or moves user data only after it verifies a copy. Gantry asks before it
  stops the user's services or containers.
- Secrets are registry passwords, kubeconfig keys, tokens and environment values sent to a
  model. Gantry keeps them out of logs and out of plain-text files. Gantry redacts them before
  they leave the Mac.

Rationale: Gantry runs with the user's rights on the user's data.

### V. Every String in Every Language

- Every user-facing string is localizable and is in the String Catalogs.
- A change merges only with translations for all supported UI languages (28 today). Make the
  translations with the reviewed glossaries.
- Counts use plural variations, never "(s)". The CI job `scripts/check-localization.py`
  must pass.

Rationale: Gantry is sold on "28 languages"; one English string breaks that promise.

## Engineering Constraints

- Put builds and caches on the external disk `/Volumes/SanDisk2Tb/builds/gantry/` with
  `xcodebuild -derivedDataPath` and `swift build --scratch-path`. The internal disk is small.
- CI runs on the `xcode-27` runner image. CI signs release builds ad hoc. Only CI signs the
  Sparkle appcast.
- UI checks of a running Debug build use `scripts/gantry-ctl` (see `docs/automation.md`),
  not clicks.
- Accessibility: every icon-only control has a label, and status is never shown by
  color only.

## Development Workflow

- Every change goes through spec-kit: `/speckit-specify`, then `/speckit-plan` and
  `/speckit-tasks`, then `/speckit-implement`. A feature folder `specs/NNN-slug/` holds
  `spec.md`, `plan.md` and `tasks.md`, and `.specify/feature.json` points at the current one.
  A task is ticked only when its code exists and was checked.
- Commits follow Conventional Commits in lowercase imperative English, with no AI
  attribution. Pull requests are squash-merged, and the PR title becomes the changelog line.
- Large changes are split into stacked pull requests. Parallel work happens in Orca
  worktrees, one feature branch each.
- release-please opens the release PR. A release ships only with a green CI on main.
- PR text and docs are in ASD-STE100 Simplified Technical English.

## Governance

This constitution overrides other practice documents. A change to it is a pull request
that updates this file and states the version bump and its reason. The same pull request
updates the templates or docs that depend on it. Versions follow semantic versioning: MAJOR for a removed or
redefined principle, MINOR for a new principle or section, PATCH for wording. Every plan
(`/speckit-plan`) has a constitution check, and every review checks the principles above.

**Version**: 1.0.0 | **Ratified**: 2026-11-07 | **Last Amended**: 2026-11-07
