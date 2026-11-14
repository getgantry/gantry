<!-- STE deviation: spec-kit template headings, the quoted user input, Given-When-Then scenarios, product names, file system names and paths stay verbatim. -->
# Feature Specification: Keychain Secrets for Container Environment

**Feature Branch**: `feat/keychain-secrets`

**Created**: 2026-11-14

**Status**: Implemented

**Input**: User description: "In the create/run flow (and Quick Run / pasted docker run), let an env var value reference a secret stored in the macOS Keychain (Gantry's own items, service prefix for the app) instead of a plain value: add, choose, rename, delete secrets in a Settings pane; values are entered in a SecureField and never shown, logged, written to recipes, compose exports, MCP output or crash logs. At run time the value is resolved and passed to the CLI without putting it on the command line where possible (env file with 0600 in a temp dir, removed after start, or stdin) — research what Docker and Apple container support and choose the safest path. Saved recipes store only references. Optional Touch ID (LocalAuthentication) before use. Constitution principle on secret safety is binding; add tests that values never appear in generated commands or logs. Do NOT use or touch the user's own `secret` CLI or its vault."

## Context

Today an environment variable in the New Container sheet and in Quick Run is plain text. A password typed there goes into saved recipes (`recipes.json`), into "Copy as docker run", and, on an apple/container host, into the arguments of the `container create` process. Any process of any user on the Mac can read process arguments. Constitution principle IV says that environment values are secrets and that Gantry keeps secrets out of plain-text files and logs.

This feature lets the user keep such a value in the macOS Keychain, as a Gantry item, and refer to it by name.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Use a Keychain secret as a variable value (Priority: P1)

The user opens New Container, adds the variable `POSTGRES_PASSWORD` and selects the secret `db-password` from the key menu of the row instead of typing a value. The row shows the name of the secret, not its value. The user clicks Create and Run. The container gets `POSTGRES_PASSWORD` with the value from the Keychain.

**Why this priority**: This is the core of the feature. Without it, nothing else has value.

**Independent Test**: Make a secret, create a container on a Docker host and on an apple/container host with a variable that refers to it, and read the variable inside the container. Check the process arguments of the CLI: the value is not there.

**Acceptance Scenarios**:

1. **Given** the secret `db-password` exists, **When** the user selects it for a variable and creates the container, **Then** the variable in the container has the value of the secret.
2. **Given** an apple/container host, **When** Gantry creates the container, **Then** the value is not in the arguments of the `container` process and not in a file that stays on disk.
3. **Given** a variable refers to a secret that no longer exists, **When** the user clicks Create, **Then** Gantry does not create the container and shows "The Keychain secret “NAME” does not exist." next to the form.
4. **Given** Quick Run, **When** the user selects a secret for a variable, **Then** the same rules apply.

---

### User Story 2 - Manage secrets in Settings (Priority: P1)

The user opens Settings ▸ Secrets. The pane lists the secret names with their dates. The user can add a secret (name and a hidden value field), replace the value, rename a secret and delete a secret. The pane never shows a value.

**Why this priority**: The user must be able to make a secret before they can use it.

**Independent Test**: In Settings ▸ Secrets, add, rename, replace and delete a secret. After each step, the list shows the correct names. The value is never visible on the screen or in the accessibility tree.

**Acceptance Scenarios**:

1. **Given** the pane, **When** the user adds the name `api-token` and a value, **Then** the list shows `api-token`.
2. **Given** a name that is already used or that has characters other than letters, digits, “_”, “.” and “-”, **When** the user tries to save, **Then** the Save button is disabled and the form tells why.
3. **Given** a secret, **When** the user deletes it, **Then** Gantry asks for confirmation with the shared destructive-action confirmation (Touch ID when the user turned it on) and then removes it.
4. **Given** a secret, **When** the user renames it, **Then** the value stays the same and the new name is in the list.

---

### User Story 3 - Recipes and copied commands keep only references (Priority: P1)

The user saves the form as a recipe or copies it as a `docker run` command. The recipe file and the copied text contain the reference `keychain:NAME`, not the value. A pasted command with `-e KEY=keychain:NAME` fills the row with that secret reference.

**Why this priority**: Recipes are plain JSON files on disk. A value there breaks principle IV.

**Independent Test**: Save a recipe with a secret reference and read `recipes.json`. Copy the form as `docker run`. Paste the copied command back.

**Acceptance Scenarios**:

1. **Given** a form with a secret reference, **When** the user saves a recipe, **Then** the recipe file holds the secret name and no value.
2. **Given** the same form, **When** the user copies it as `docker run` or `container run`, **Then** the text holds `KEY=keychain:NAME`.
3. **Given** a pasted command with `-e KEY=keychain:NAME`, **When** Gantry reads it, **Then** the row refers to the secret `NAME`.

---

### User Story 4 - Values stay hidden after the container exists (Priority: P2)

The container that Gantry made with a secret carries a label with the variable names and secret names (never values). Gantry uses it: the container inspector shows `KEY = keychain:NAME` with the value hidden, "Save as recipe" and recreate keep the reference, and the MCP `inspect_container` tool replaces the value with `[REDACTED]`.

**Why this priority**: The value is in the container configuration (the runtime stores it). Gantry must not show it again where Gantry controls the output.

**Independent Test**: Create a container with a secret. Open its inspector, ask the MCP server for `inspect_container`, recreate the container on an apple/container host and check the process arguments.

**Acceptance Scenarios**:

1. **Given** such a container, **When** the user opens its inspector, **Then** the variable shows as hidden with the secret name.
2. **Given** such a container, **When** an MCP client calls `inspect_container`, **Then** the output has `KEY=[REDACTED]`.
3. **Given** such a container on an apple/container host, **When** Gantry recreates it, **Then** the value is not in the process arguments.

---

### User Story 5 - Touch ID before use (Priority: P3)

The user turns on "Require Touch ID to use secrets" in Settings ▸ Secrets. When a create or run needs one or more secrets, Gantry asks once for Touch ID (or the login password). When the user cancels, Gantry does not create the container.

**Why this priority**: Optional extra protection. The feature is complete without it.

**Independent Test**: Turn on the setting, create a container with a secret, cancel the prompt: no container. Confirm: the container is created.

**Acceptance Scenarios**:

1. **Given** the setting is on, **When** a create needs secrets, **Then** Gantry asks once for all of them.
2. **Given** the prompt, **When** the user cancels, **Then** Gantry shows "Gantry could not read the Keychain secrets: authentication was cancelled." and creates nothing.
3. **Given** the setting is off, **When** a create needs secrets, **Then** Gantry does not ask.

### Edge Cases

- A secret is renamed or deleted after a recipe refers to it: the recipe keeps the old name; the create fails with the "does not exist" message; the row shows the name with a warning icon.
- On an apple/container host, a variable with a secret uses a name that the `container` tool itself reads from its environment (for example `PATH`, `HOME`, names that start with `CONTAINER_` or `DYLD_`): Gantry rejects it with a message, because the value must go through the environment of the tool process.
- A secret variable name that is not a portable environment name (`[A-Za-z_][A-Za-z0-9_]*`): Gantry rejects it with a message.
- The Keychain is locked or the user denies access: the create fails with a clear message and no partial container.
- An empty value: the pane does not save a secret with an empty value.
- A plain value in a pasted command looks like a password: Gantry does not guess; the user can move it to the Keychain with "Save Value in Keychain…" on the row.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Gantry MUST store each secret as a Keychain generic password item under its own service `com.andrewkomkov.Gantry.env-secret`, with the secret name as the account. Gantry MUST NOT use other Keychain services or other tools' stores for this feature.
- **FR-002**: Settings MUST have a Secrets pane that lists names and modification dates, and lets the user add, replace the value of, rename and delete a secret. Values MUST be typed in a secure (hidden) field and MUST never be shown.
- **FR-003**: Secret names MUST be 1–64 characters of letters, digits, “_”, “.” and “-”, starting with a letter or digit, and unique.
- **FR-004**: In New Container and Quick Run, each environment row MUST let the user choose a secret, make a new secret, move the typed value into a new secret, and go back to a plain value.
- **FR-005**: A recipe MUST store a secret reference as the secret name only. Older recipe files MUST still load.
- **FR-006**: "Copy as docker run"/"container run" MUST print a secret reference as `KEY=keychain:NAME`. The pasted-command reader MUST read `KEY=keychain:NAME` as a reference.
- **FR-007**: Gantry MUST resolve the values only when the user creates or runs the container, MUST keep them in memory only, and MUST fail the whole create with the secret name (never the value) when a secret is missing or unreadable.
- **FR-008**: On a Docker host, the value MUST go only in the create request body to the Engine API. On an apple/container host, the value MUST go in the environment of the `container create` process and the argument MUST be the variable name only (`--env KEY`). No value may be in process arguments or in a file on disk.
- **FR-009**: A container created with secrets MUST carry the label `com.gantry.secret-env` with `KEY:NAME` pairs (no values). Inspect-to-recipe, the inspector, recreate and the MCP `inspect_container` output MUST use it to hide the values.
- **FR-010**: An optional setting MUST require device-owner authentication (Touch ID or password) once per create that needs secrets. It is off by default.
- **FR-011**: Error messages, logs and thrown errors of this feature MUST contain secret names only, never values.
- **FR-012**: Every new user-facing string MUST be in the String Catalogs with all 28 languages.
- **FR-013**: Gantry MUST NOT call or read the user's own `secret` command or its vault.

### Key Entities

- **Secret**: a name, a value (only in the Keychain), a creation date and a modification date.
- **Secret reference**: an environment variable whose value is "the secret NAME". In a recipe it is the name; in a command it is `keychain:NAME`; on a container it is a `KEY:NAME` pair in the `com.gantry.secret-env` label.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In automatic tests, a known secret value is in none of: the recipe JSON, the copied command, the apple/container CLI arguments, the error text for a missing secret, and the MCP inspect output.
- **SC-002**: A user can make a secret and use it in a new container in under one minute, with no typing of the value outside a hidden field.
- **SC-003**: Containers made with secrets work the same on Docker hosts and on apple/container hosts 1.0 or later.
- **SC-004**: `scripts/check-localization.py` reports 0 problems.

## Assumptions

- The runtime stores the resolved value in the container configuration; `docker inspect` and `container inspect` outside Gantry can show it. This is the same as for every container environment variable and is out of scope.
- Compose export (spec 008): for a variable that Gantry filled from a Keychain secret, the file holds `keychain:NAME`, never the value. Such a variable is not offered as a secret to include. Compose up keeps its current behaviour. Compose itself does not resolve `keychain:NAME`, so the user sets the value before a run.
- The Docker Engine API takes the body over a local socket or an SSH channel. No `docker` CLI process is used, so no argument or env-file path applies there.
- apple/container reads `--env KEY` (no `=`) from its own environment since 1.0.0 (checked in the 1.0.0 source and live on 1.7.1). An env file is not necessary.
- The Keychain items use the login keychain with "accessible when unlocked". After an update of an ad-hoc signed build, macOS can ask once to allow access, as it does for SSH passwords today.
- The MCP `create_container` tool keeps plain values; it does not get secret references in this feature.
