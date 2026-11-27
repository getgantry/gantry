<!-- STE deviation: spec-kit template headings, product names, Swift names, API paths and file paths stay verbatim. -->
# Implementation Plan: Image Updates for Containers

**Branch**: `feat/image-updates` | **Date**: 2026-11-21 | **Spec**: [spec.md](spec.md)

## Changes

DockerKit gets an image reference parser, the `/distribution` endpoint and a small registry client for the manifest digest. AppCore gets the pure rules: which container to check, the local digest and the status. AppCore also gets a file cache with the 6-hour rule, a shared monitor that runs the checks, and `HostSession.updateContainer`. The app shows a badge, a filter, the menu items and the confirmation. GantryMCP adds `updateAvailable` from the cache file.

## Research

- `container image --help` (1.7.1): delete, inspect, list, load, prune, pull, push, save, tag. `container registry`: login, logout, list. No command reads a remote digest, so Apple hosts use the registry HTTP API.
- `container image list --format json`: `configuration.descriptor.digest` is the OCI index digest. `container list` gives the same digest in `configuration.image.descriptor.digest` (the summary `ImageID`).
- `nettop.local` (Engine API 1.55): `GET /v1.47/distribution/docker.io/library/alpine:3.22/json` gives `Descriptor.digest` `sha256:49340b…`, and `RepoDigests` of the local image is `alpine@sha256:49340b…`.
- Docker Hub: `HEAD /v2/library/alpine/manifests/3.22` with a token from `auth.docker.io` gives `Docker-Content-Digest: sha256:49340b…`. ghcr.io gives `401` with `WWW-Authenticate: Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="…"`.

## Constitution Check

- Principle II: all rules are pure functions or protocols with tests in DockerKit and AppCore. The registry HTTP is behind `RegistryHTTP`.
- Principle III: Apple hosts need no Docker. The feature uses only HTTP for them.
- Principle IV: the update uses `DestructiveAction` with the new kind `updateContainer`. Registry credentials stay in memory. The cache file holds only references, digests and dates.
- Principle V: all new strings go to the catalogs in 28 languages.

## Design

- `DockerKit/Models/ImageReference.swift`: parse, canonical name, registry host for HTTP.
- `DockerKit/Endpoints/Distribution.swift`: `DockerClient.distributionDigest(reference:auth:)`.
- `DockerKit/Registry/RegistryManifestClient.swift`: HEAD manifest, `WWW-Authenticate` parser, token fetch.
- `AppCore/ImageUpdates/ImageUpdatePlan.swift`: target of a container, status, user env and command.
- `AppCore/ImageUpdates/ImageUpdateCache.swift`: Codable cache, freshness, file load and save.
- `AppCore/ImageUpdates/ImageUpdateMonitor.swift`: `@MainActor @Observable` shared monitor. It checks one reference once when several containers use it.
- `AppCore/ImageUpdates/HostSession+ImageUpdates.swift`: `imageUpdateStatus(for:)`, `checkImageUpdates(force:)`, the periodic loop, `updateContainer(_:)`.
- `HostSession.recreate(_:adjust:)` (from spec 021) is the shared recreate step for the volume switch, the limits change and the update. When the new create fails, it makes the old container again.
- App: badge in `ContainerRow` and the detail header, filter case `updates`, context menu item, and "Check for Image Updates" in the More menu and the palette.
- App: `containerUpdateConfirmation` shows the confirmation and the Compose alert.
- GantryMCP: `ContainerDTO.updateAvailable`.
