<!-- STE deviation: product names, CLI flags and API names stay verbatim. -->
# Research: Keychain Secrets for Container Environment

## R1. How a value gets to a Docker host

- **Decision**: Put the value in the `Env` array of the `POST /containers/create` body only.
- **Rationale**: Gantry speaks the Docker Engine API directly over a Unix socket or an SSH channel (`DockerClient.createContainer`). No `docker` CLI process runs, so there are no process arguments and no env file. The body is not logged (no logger in DockerKit transport).
- **Alternatives**: `docker run --env-file` (not used: Gantry has no CLI path for Docker); Docker secrets (Swarm only).

## R2. How a value gets to an apple/container host

- **Decision**: For each secret variable, put `KEY=value` into the environment of the `container create` child process and pass `--env KEY` (no `=`).
- **Rationale**: The CLI reads `--env VAR` from its own environment ("key=value, or just key to inherit from host"). The 1.0.0 source (`Sources/ContainerClient/Parser.swift`, `Parser.env`) has this rule, and a live run on 1.7.1 (`GKS_TOKEN=... container create --env GKS_TOKEN alpine`) put the value into the container. The value is never in argv (readable by every user through `ps`) and never on disk. A process environment is readable only by the same user and root, and only while the short `create` process runs.
- **Alternatives**: `--env-file` with a 0600 file in a 0700 temp dir: works, but the value is on disk for a moment and a crash can leave the file; the file format cannot hold a newline. stdin: the CLI has no option to read env from stdin.
- **Limit**: The CLI also reads its own variables from the same environment (`PATH`, `HOME`, `TMPDIR`, `USER`, `LOGNAME`, `SHELL`, `NO_COLOR`, `CONTAINER_*`, `DYLD_*`, `LANG`, `LC_*`, `__CF*`, `XPC_*`). A secret variable with such a name is rejected with a message. Plain variables are not changed.
- **Missing key**: the CLI skips `--env KEY` silently when KEY is not in its environment. The transport always sets it, and the AppCore resolver fails before the request when a value is missing.

## R3. Recreate and inspect

- **Decision**: Stamp the label `com.gantry.secret-env` = `KEY:NAME,KEY2:NAME2` (sorted). No `=` in the value, so apple label escaping is not triggered.
- **Rationale**: Inspect shows the resolved `Env`. The label tells Gantry which variables came from secrets: inspect-to-recipe puts the reference back, recreate on apple passes those keys through the environment again (`AppleOptions(labels:)`, as for the kernel labels), the inspector hides the value, MCP output redacts it.

## R4. Keychain store

- **Decision**: Generic password items, service `com.andrewkomkov.Gantry.env-secret`, account = name, label "Gantry secret NAME", `kSecAttrAccessibleWhenUnlocked`. List with `kSecReturnAttributes` only (no data, so no access prompt). Rename with `SecItemUpdate` of the account attribute (the value is not read).
- **Rationale**: Same pattern as `KeychainStore` for SSH passwords, but a separate service so the list shows only environment secrets. The data protection keychain needs a team-signed keychain-access-groups entitlement, which ad-hoc CI builds do not have.
- **Alternatives**: `SecAccessControl` with `.userPresence` (needs the data protection keychain); the user's own `secret` CLI (forbidden by FR-013).

## R5. Touch ID

- **Decision**: An app-level gate (`LAContext.evaluatePolicy(.deviceOwnerAuthentication)`) once per create, before any Keychain read, behind the setting `requireBiometricsForSecrets` (off by default). AppCore takes it as an `authorize` closure.
- **Rationale**: Same pattern as `BiometricGate`; testable in AppCore with a fake closure.

## R6. Reference syntax in commands

- **Decision**: `KEY=keychain:NAME`.
- **Rationale**: Readable, cannot be a real-world value by accident in most cases, and round-trips through `RunCommandParser`. The user's `secret` tool uses `secret:`; Gantry uses its own prefix so the two never mix.
