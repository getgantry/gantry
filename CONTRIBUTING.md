# Contributing to Gantry

Thanks for your interest in contributing. Gantry is a native macOS app for
managing and monitoring Docker, both locally and over SSH. Bug reports, feature
requests, and pull requests are all welcome.

## Getting started

1. Clone the repository:

   ```sh
   git clone https://github.com/getgantry/gantry.git
   cd gantry
   ```

2. Open the project in Xcode 26 or later:

   ```sh
   open Gantry.xcodeproj
   ```

3. Select the `Gantry` scheme and build (Cmd-B) or run (Cmd-R). The local
   Swift packages under `Packages/` are referenced directly by the project and
   resolve automatically; no extra setup is required.

You will need macOS 26 (Tahoe) or later to build and run the app.

## Project layout

The app target lives in `App/`. Most logic is split into local Swift packages
under `Packages/`:

- **DockerKit** — the Docker Engine API client. Talks to the daemon over two
  transports: a Unix domain socket for local engines (Docker Desktop, OrbStack,
  Colima) and `docker system dial-stdio` over SSH for remote hosts. Contains the
  endpoint definitions, request/response models, and the streaming
  (logs, stats, events, exec) machinery.
- **SSHKit** — SSH connectivity built on Citadel (which wraps swift-nio-ssh).
  Provides connection setup, authentication, host key handling, and the
  dial-stdio transport that DockerKit uses for remote engines.
- **AppCore** — application models, observable stores, and persistence,
  including Keychain access. This is the layer the SwiftUI views bind to.
- **GantryMCP** — a standalone stdio MCP (Model Context Protocol) server
  executable that exposes Docker operations to agents.

## Tests

Each package has its own test suite. Run them with `swift test` from inside the
package directory, for example:

```sh
cd Packages/DockerKit && swift test
cd Packages/SSHKit && swift test
```

Some suites include **live integration tests** that exercise a real Docker
daemon or a real SSH host. These are gated and run automatically only when the
required resource is available:

- DockerKit live tests run only when a local Docker socket is discovered
  (Docker Desktop, OrbStack, Colima, the system default, or `DOCKER_HOST`).
- SSHKit live tests run only when `GANTRY_SSH_TEST_HOST` is set to a reachable
  SSH host with Docker installed, and the test key exists. Environment:
  - `GANTRY_SSH_TEST_HOST` — host (or ssh_config alias) to dial.
  - `GANTRY_SSH_TEST_KEY` — passphrase-free private key authorized on that
    host (default `~/.ssh/gantry_test_ed25519`).
  - `GANTRY_SSH_TEST_RSA_KEY` — optional RSA key for the rsa-sha2-256 test
    (default `~/.ssh/id_rsa`).

  Because the live SSH suite opens many concurrent connections to one host,
  run it serially: `GANTRY_SSH_TEST_HOST=<host> swift test --no-parallel`.
- AppCore persistence tests point `hosts.json` at a temp file via
  `GANTRY_HOSTS_PATH`; they never touch your real app data.

When the resource is absent (as on CI, or a machine without Docker), the gated
tests are skipped rather than failed. The non-live unit tests always run.

## Code style

- The project builds under **Swift 6 strict concurrency**. Keep new code clean
  of concurrency warnings; annotate `Sendable`, actors, and isolation
  explicitly rather than silencing diagnostics.
- Write **explicit `CodingKeys`** for `Codable` types that map to the Docker
  Engine API, rather than relying on synthesized keys.
- **No force-unwraps** (`!`) in app code. Handle the absent case explicitly.
- Match the surrounding formatting and naming conventions of the file you are
  editing.

## Commit messages

Write commit messages in plain, imperative English (for example,
"Add container exec terminal"). Keep them concise and factual. Do not add
attribution or co-author trailers.

## Pull requests

Before opening a pull request:

- Confirm the app builds cleanly.
- Run the relevant package tests.
- Make sure there are no new Swift 6 concurrency warnings.
- Include screenshots for any user-facing UI changes.
- Add a bullet under `## [Unreleased]` in [`CHANGELOG.md`](CHANGELOG.md) for any
  user-facing change (the release script stamps it with a version later).

The pull request template includes this checklist. Keep each PR focused on a
single change where practical.

## Releasing

Releases are automated by the [`Release`](.github/workflows/release.yml)
workflow. To cut one:

1. On `main`, bump `MARKETING_VERSION` in the Xcode project and land any
   `## [Unreleased]` changelog notes.
2. Tag and push: `git tag v0.13.0 && git push origin v0.13.0` (the tag must
   match `MARKETING_VERSION`). You can also run the workflow manually from the
   Actions tab with a version input.

The workflow builds and ad-hoc-signs the universal app, embeds `gantry-mcp`,
generates the EdDSA-signed Sparkle appcast, publishes a GitHub release with the
zip, and commits the updated `appcast.xml` and `CHANGELOG.md` back to `main` so
existing installs auto-update.

It needs one repository secret, `SPARKLE_PRIVATE_KEY` — the EdDSA private key
from Sparkle's `generate_keys -x`, pairing with `SUPublicEDKey` in
`Info.plist`. `scripts/release.sh <version>` runs the same steps locally using
the key from your login Keychain.

## Reporting issues

Use the issue templates for bug reports and feature requests. For questions and
open-ended discussion, use
[GitHub Discussions](https://github.com/getgantry/gantry/discussions).
