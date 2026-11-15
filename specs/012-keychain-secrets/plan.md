<!-- STE deviation: spec-kit template headings, product names, Apple API names, CLI flags and paths stay verbatim. -->
# Implementation Plan: Keychain Secrets for Container Environment

**Branch**: `feat/keychain-secrets` | **Date**: 2026-11-14 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/012-keychain-secrets/spec.md`

## Summary

An environment row can hold a reference to a Gantry Keychain secret instead of a value. The reference is the secret name. Gantry reads the value only at create time, in memory, after an optional Touch ID check. On Docker hosts the value goes only into the Engine API body. On apple/container hosts the value goes into the environment of the `container create` process, and the argument is `--env KEY` (see [research.md](./research.md)). The container gets a label `com.gantry.secret-env` with `KEY:NAME` pairs, which inspect, recreate, the inspector and MCP use to hide values.

## Technical Context

**Language/Version**: Swift 6, Xcode 27 SDK

**Primary Dependencies**: SwiftUI, Security (Keychain generic passwords), LocalAuthentication. No new packages.

**Storage**: Keychain items, service `com.andrewkomkov.Gantry.env-secret`, account = secret name, `kSecAttrAccessibleWhenUnlocked`. Recipes (`recipes.json`) hold names only.

**Testing**: Swift Testing in AppCore (`EnvSecretsTests`, `SecretsLibraryTests`, recipe/parser/formatter additions) and DockerKit (`SecretEnvTests`, transport test with the scripted CLI). Tests use `InMemorySecretStore`, never the real Keychain.

**Target Platform**: macOS 26 or later; apple/container 1.0+; Docker Engine API hosts (local and SSH).

**Project Type**: Desktop app (SwiftUI) with local Swift packages.

**Constraints**: Builds go to `/Volumes/SanDisk2Tb/builds/gantry/keychain-secrets/`, `-jobs 3`. No value in argv, files, logs, errors, recipes or MCP output.

## Constitution Check

- I. HIG: the Secrets pane is a standard Settings tab with a `Form`/`List`, toolbar-less add/remove buttons and a secure field. The row token uses an SF Symbol and text, not color only. Pass.
- II. Logic in packages: validation, reference syntax, resolution, request building, label codec, redaction and the transport change are in AppCore and DockerKit with tests. The Keychain is behind the `SecretStore` protocol. Views only present state. Pass.
- III. No required dependencies: works with only apple/container. `--env KEY` exists since 1.0.0 (the minimum), so no version gate is necessary. Pass.
- IV. Safety: this feature applies the principle. Delete uses `DestructiveAction` confirmation with Touch ID when on. Values stay in memory only. Pass.
- V. Strings: all new strings in the catalogs with 28 languages; `check-localization.py` must report 0. Pass.

Re-check after design: no violation. No complexity tracking necessary.

## Project Structure

### Documentation (this feature)

```text
specs/012-keychain-secrets/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/secret-env.md
├── checklists/requirements.md
└── tasks.md
```

### Source Code (repository root)

```text
Packages/DockerKit/Sources/DockerKit/
├── Models/ContainerCreateRequest.swift        # AppleOptions.secretEnvKeys, label read-back
├── Models/SecretEnv.swift                     # NEW: label codec, inspect redaction, reserved names
└── AppleContainer/
    ├── AppleContainerCLI.swift                # run(_:environment:)
    └── AppleContainerTransport.swift          # --env KEY + process environment
Packages/AppCore/Sources/AppCore/
├── Secrets/SecretStore.swift                  # NEW: protocol, errors, in-memory store
├── Secrets/KeychainSecretStore.swift          # NEW: Keychain implementation
├── Secrets/EnvSecrets.swift                   # NEW: names, references, issues, resolve, apply
├── Secrets/SecretsLibrary.swift               # NEW: @Observable list for the UI
└── Recipes/ (ContainerRecipe, +Request, +Inspect, RunCommandFormatter, RunCommandValues)
Packages/GantryMCP/Sources/gantry-mcp/GantryTools+Containers.swift   # redact inspect output
App/Security/SecretGate.swift                  # NEW: optional Touch ID
App/Views/Settings/SecretsSettingsView.swift   # NEW: Settings ▸ Secrets
App/Views/Containers/EnvSecretField.swift      # NEW: row value field, key menu, new-secret sheet
App/Views/Containers/{CreateContainerSheet,QuickRunSheet,ContainerDetailView}.swift
App/Views/SettingsView.swift                   # new tab
```

**Structure Decision**: Follow the existing split: logic in AppCore/DockerKit, thin SwiftUI views in App.
