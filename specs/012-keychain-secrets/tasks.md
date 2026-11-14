<!-- STE deviation: task IDs, file paths, type names and flags stay verbatim. -->
# Tasks: Keychain Secrets for Container Environment

**Input**: Design documents from `/specs/012-keychain-secrets/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/secret-env.md

**Tests**: Required by the spec (SC-001) and by constitution principle II.

## Phase 1: Setup

- [x] T001 Create `specs/012-keychain-secrets/` documents and point `.specify/feature.json` at it

## Phase 2: Foundational (DockerKit and AppCore core)

- [x] T002 [P] Add `SecretEnvLabel` (label key `com.gantry.secret-env`, `KEY:NAME` pairs joined with `,`, sorted), `SecretEnvRedaction.redactInspectJSON` and `SecretEnvRedaction.isReservedForCLI` in `Packages/DockerKit/Sources/DockerKit/Models/SecretEnv.swift`
- [x] T003 Add `secretEnvKeys` (`SecretEnvKeys`) to `ContainerCreateRequest.AppleOptions` and read it back from the label in `init(labels:)` in `Packages/DockerKit/Sources/DockerKit/Models/ContainerCreateRequest.swift`
- [x] T004 Add `run(_:environment:)` to `AppleContainerCLIRunning` (default throws for a non-empty environment) and implement it in `AppleContainerProcessRunner` in `Packages/DockerKit/Sources/DockerKit/AppleContainer/AppleContainerCLI.swift`
- [x] T005 In `createContainer` of `Packages/DockerKit/Sources/DockerKit/AppleContainer/AppleContainerTransport.swift`, pass secret keys as `--env KEY` with the value in the process environment; reject reserved names with a 400 that holds the key only
- [x] T006 [P] DockerKit tests: label codec, redaction, `AppleOptions(labels:)`, transport argv holds no value and the environment holds it, in `Packages/DockerKit/Tests/DockerKitTests/SecretEnvTests.swift` and `AppleContainerTransportTests.swift`
- [x] T007 [P] Add `SecretStore` protocol, `SecretInfo`, `SecretError` (names only in descriptions) and `InMemorySecretStore` in `Packages/AppCore/Sources/AppCore/Secrets/SecretStore.swift`
- [x] T008 [P] Add `KeychainSecretStore` (service `com.andrewkomkov.Gantry.env-secret`, account = name, `kSecAttrAccessibleWhenUnlocked`, list without data, rename with `SecItemUpdate`) in `Packages/AppCore/Sources/AppCore/Secrets/KeychainSecretStore.swift`
- [x] T009 Add `EnvSecrets`: name rule "1–64 chars, `[A-Za-z0-9][A-Za-z0-9_.-]*`, unique", `keychain:NAME` reference parse/format, variable issues (portable name, reserved on apple), `resolve(_:store:authorize:)`, `apply(_:values:to:isAppleHost:)` in `Packages/AppCore/Sources/AppCore/Secrets/EnvSecrets.swift`
- [x] T010 Add optional `secret` to `ContainerRecipe.EnvVar` (value encoded as `""` when set; old files load) in `Packages/AppCore/Sources/AppCore/Recipes/ContainerRecipe.swift`

## Phase 3: User Story 1 - Use a secret as a variable value (P1)

**Goal**: A row refers to a secret; create/run resolves it safely on both host kinds.

**Independent Test**: create a container with a secret on the apple host; argv holds `--env KEY` only; the container sees the value.

- [x] T011 [US1] Use `EnvSecrets.apply` in `createRequest(...secretValues:)` and add async `resolvedCreateRequest(...)` in `Packages/AppCore/Sources/AppCore/Recipes/ContainerRecipe+Request.swift`
- [x] T012 [P] [US1] AppCore tests: resolve, missing secret error text holds no value, authorize false, apply sets label/keys, reserved and invalid keys, in `Packages/AppCore/Tests/AppCoreTests/EnvSecretsTests.swift`
- [x] T013 [US1] Add `SecretGate` (optional Touch ID, key `requireBiometricsForSecrets`) in `App/Security/SecretGate.swift`
- [x] T014 [US1] Add `EnvSecretField` (value field or secret token, key menu: choose, new, save value in Keychain, use plain value) and `NewSecretSheet` in `App/Views/Containers/EnvSecretField.swift`
- [x] T015 [US1] Wire secret rows, inline issues and async resolve into `App/Views/Containers/CreateContainerSheet.swift`
- [x] T016 [US1] Wire secret rows and async resolve into `App/Views/Containers/QuickRunSheet.swift`

## Phase 4: User Story 2 - Manage secrets in Settings (P1)

- [x] T017 [US2] Add `SecretsLibrary` (@Observable list, add, replace, rename, delete, lastError) in `Packages/AppCore/Sources/AppCore/Secrets/SecretsLibrary.swift`
- [x] T018 [P] [US2] Tests for `SecretsLibrary` with `InMemorySecretStore` in `Packages/AppCore/Tests/AppCoreTests/SecretsLibraryTests.swift`
- [x] T019 [US2] Add Settings ▸ Secrets (`SecretsSettingsView`: list, add, replace, rename, delete with `DestructiveAction` confirmation, Touch ID toggle) in `App/Views/Settings/SecretsSettingsView.swift` and the tab in `App/Views/SettingsView.swift`

## Phase 5: User Story 3 - Recipes and commands keep references (P1)

- [x] T020 [US3] Print `KEY=keychain:NAME` in `Packages/AppCore/Sources/AppCore/Recipes/RunCommandFormatter.swift` and read it in `Packages/AppCore/Sources/AppCore/Recipes/RunCommandValues.swift`
- [x] T021 [P] [US3] Tests: recipe JSON and copied command hold no value; paste round trip; old recipe JSON decodes, in `Packages/AppCore/Tests/AppCoreTests/EnvSecretsTests.swift`

## Phase 6: User Story 4 - Values stay hidden after create (P2)

- [x] T022 [US4] Inspect-to-recipe restores references from the label and drops the label in `Packages/AppCore/Sources/AppCore/Recipes/ContainerRecipe+Inspect.swift`
- [x] T023 [US4] The inspector hides values of secret variables in `App/Views/Containers/ContainerDetailView.swift`
- [x] T024 [US4] MCP `inspect_container` redacts with `SecretEnvRedaction` in `Packages/GantryMCP/Sources/gantry-mcp/GantryTools+Containers.swift`
- [x] T025 [P] [US4] Tests: inspect-to-recipe and recreate request keep keys, in `Packages/AppCore/Tests/AppCoreTests/EnvSecretsTests.swift`

## Phase 7: User Story 5 - Touch ID before use (P3)

- [x] T026 [US5] Pass `SecretGate.authorize` from both sheets; show the cancelled message; toggle in the Secrets pane (`App/Views/Settings/SecretsSettingsView.swift`)

## Phase 8: Polish

- [x] T027 Translations for every new string in all 28 languages in `App/Localizable.xcstrings` and `Packages/AppCore/Sources/AppCore/Resources/Localizable.xcstrings`; `scripts/check-localization.py` reports 0 problems
- [x] T028 Run DockerKit, AppCore and GantryMCP tests; build the app with `xcodebuild -jobs 3`
- [x] T029 Live check of the apple/container path without the GUI: a create through `AppleContainerTransport` and the real CLI 1.7.1 had `--env GKS_TOKEN` only in argv, the container got the exact value and the `com.gantry.secret-env` label; `gks-live` removed
- [x] T031 Live check of the Docker path without the GUI: Docker 29.6.2 on an SSH host, through an SSH socket tunnel and `UnixSocketTransport`. A recipe with a secret row went through `resolvedCreateRequest`. The value was only in the create body, and in none of the path, the query, the recipe JSON or the copied command. The container saw the exact value. Inspect-to-recipe gave a secret row with an empty value. `redactInspectJSON` printed `GKS_TOKEN=[REDACTED]`. `gks-docker` removed
- [ ] T030 GUI live check per `quickstart.md` (Settings ▸ Secrets, key menu in New Container and Quick Run, inspector, Touch ID prompt) with the Debug build and `scripts/gantry-ctl`. Open: the shared GUI was not handed to this agent

## Dependencies

- Phase 2 blocks all stories. US1 needs T002–T011. US2 needs T007, T008. US3 needs T010. US4 needs T002, T003. US5 needs US1 and US2.

## Parallel Examples

- T002, T007, T008 touch different files and can run together. T006, T012, T018 and T021 are test files.

## Implementation Strategy

MVP is US1 + US2 (make a secret and use it). US3 and US4 close the leaks named in principle IV and ship in the same pull request. US5 is small and ships too.
