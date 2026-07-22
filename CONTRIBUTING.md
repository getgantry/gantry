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

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) —
`<type>[optional scope]: <description>` — because
[release-please](https://github.com/googleapis/release-please) derives the next
version number and the changelog from them:

```
feat(machines): create machines with nested virtualization
fix(logs): keep follow mode after a reconnect
docs(readme): note volume sizes and sorting
```

Use `feat`, `fix`, `build`, `chore`, `ci`, `docs`, `style`, `refactor`, `perf`
or `test`. A `!` after the type/scope (or a `BREAKING CHANGE:` footer) marks a
breaking change. Keep the description in plain, imperative, lowercase English
with no trailing period. Do not add attribution or co-author trailers.

Which type you pick decides the version bump: `feat` moves the minor version,
`fix` the patch, a breaking change the major. `feat` and `fix` (plus `perf`,
`refactor` and `docs`) appear in the changelog; the rest stay hidden.

## Pull requests

Before opening a pull request:

- Confirm the app builds cleanly.
- Run the relevant package tests.
- Make sure there are no new Swift 6 concurrency warnings.
- Include screenshots for any user-facing UI changes.
- Write the commit message as a Conventional Commit — it becomes the changelog
  entry, so make the description read the way you want it to appear there.

The pull request template includes this checklist. Keep each PR focused on a
single change where practical.

## Releasing

Releases are driven by
[release-please](https://github.com/googleapis/release-please) and finished by
the [`Release`](.github/workflows/release.yml) workflow. Nobody picks a version
by hand:

1. Land Conventional Commits on `main`. The
   [`Release Please`](.github/workflows/release-please.yml) workflow keeps a
   release PR open with the next version and the changelog entries it derived
   from those commits, and syncs `MARKETING_VERSION` (and the build number)
   into the Xcode project on the PR branch.
2. Review that PR — it is the release. Merging it tags `vX.Y.Z`, publishes the
   GitHub release with the changelog notes, and dispatches the `Release`
   workflow.

`Release` then builds and ad-hoc-signs the universal app, embeds `gantry-mcp`,
generates the EdDSA-signed Sparkle appcast, uploads the zip to the release, and
commits the updated `appcast.xml` back to `main` so existing installs
auto-update.

The release PR itself gets no CI run — anything pushed with `GITHUB_TOKEN`
cannot start another workflow, and CI already built the same commits on `main`.
Set a `RELEASE_PLEASE_TOKEN` secret (a PAT) if you want CI on the release PR too.

The version release-please owns lives in `version.txt` and
`.release-please-manifest.json`; `scripts/sync-version.sh` is what copies it
into `Gantry.xcodeproj`. To release without release-please (a hotfix, say), bump
the project version, push a matching `vX.Y.Z` tag, and `Release` will create the
release itself.

`Release` needs one repository secret, `SPARKLE_PRIVATE_KEY` — the EdDSA private
key from Sparkle's `generate_keys -x`, pairing with `SUPublicEDKey` in
`Info.plist`. `scripts/release.sh <version>` runs the same steps locally using
the key from your login Keychain.

## Tracking apple/container

Gantry drives the `container` CLI, so upstream releases matter. The
[`Watch apple/container`](.github/workflows/upstream-container-watch.yml)
workflow checks [apple/container](https://github.com/apple/container) weekly
and opens a PR whenever a release appears that Gantry has not looked at yet. The PR
mirrors the upstream notes into `docs/upstream/` and carries a review checklist
(new flags, changed JSON shapes, workarounds that can go, version gates to
move).

The last reviewed version is recorded in
`.github/upstream/apple-container-version.txt`; merging the PR is what stops the
next run from re-opening it. Run the workflow by hand from the Actions tab to
check immediately, optionally passing a tag to re-open a PR for an older
release.

## Reporting issues

Use the issue templates for bug reports and feature requests. For questions and
open-ended discussion, use
[GitHub Discussions](https://github.com/getgantry/gantry/discussions).
