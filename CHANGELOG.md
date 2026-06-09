# Changelog

All notable changes to Gantry are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add new entries under **[Unreleased]** as you work; `scripts/release.sh` stamps
that section with the version and date when a release is cut.

## [Unreleased]

## [0.11.0] - 2026-06-09


### Added
- **Machines** section for apple/container hosts: manage `container machine`
  environments (long-lived Linux VMs, comparable to OrbStack machines) — create,
  start, stop, set-default, delete, and open a shell. Requires apple/container
  1.0+ installed from the official signed installer.

### Changed
- Full support for **apple/container 1.0**. 1.0 restructured the CLI's JSON
  output (resources nest under `configuration`, container `status` is now an
  object, image size moved to `variants[]`, dates are RFC 3339, image ids lost
  the `sha256:` scheme); the bridge parses the new shapes while staying
  tolerant of 0.12. The connect path no longer blocks on 1.0's interactive
  kernel-install prompt, and CLI discovery prefers the Homebrew keg path so
  `system start` finds its plugins.
- The setup prompt now recommends the **official signed installer** over
  Homebrew, because the Homebrew bottle omits the machine API server and so
  cannot run `container machine`.

## [0.10.0] - 2026-06-08

### Added
- Drag-and-drop Dockerfile builds across every engine. Drop a Dockerfile on the
  window (or use **Docker → Build Image from Dockerfile…**, or **Open With →
  Gantry**) to pick a target host, tag, context, build args, target stage and
  cache option, then watch the build log stream live.
- Real `/build` tar upload for Docker daemon hosts (local and over SSH): the
  build context is packed honouring `.dockerignore`, and the daemon's progress
  is streamed line by line. apple/container keeps its CLI build path.

### Changed
- The Compose runner now builds images on Docker daemon hosts too, not only
  apple/container.

## [0.9.1] - 2026-06-08

### Changed
- Cache container inspect details per session so reselecting a container no
  longer reloads it.

## [0.9.0] - 2026-06-08

### Added
- Port forwarding to remote hosts.
- Folder upload into containers.
- apple/container convenience flow.

## [0.8.1] - 2026-06-08

### Added
- Compose Up app intent for Shortcuts and Siri.

## [0.8.0] - 2026-06-08

### Added
- Run `docker-compose` files on apple/container straight from Finder.
- Check for and install apple/container at launch.

## [0.7.0] - 2026-06-07

### Added
- apple/container as a first-class host type.

## [0.6.0] - 2026-06-05

### Added
- Copy as Prompt: hand a container's context to an AI agent.

### Fixed
- Close the partial connection chain when a ProxyJump hop fails.
- Invalidate in-flight connects when a host disconnects.
- Clamp the MCP logs tail.

## [0.5.0] - 2026-06-05

### Added
- ProxyJump support for SSH hosts.
- Documentation for the fleet dashboard, health column and auto-reconnect.

## [0.4.5] - 2026-06-05

### Fixed
- Pin forks with `rsa-sha2-256` client authentication.

## [0.4.4] - 2026-06-05

### Added
- Auto-retry transient initial connection failures.

## [0.4.3] - 2026-06-05

### Added
- Auto-reconnect after a lost connection.

## [0.4.2] - 2026-06-05

### Changed
- Try every loadable SSH key during automatic authentication.

## [0.4.1] - 2026-06-05

### Changed
- Move load sampling into `HostSession`.

## [0.4.0] - 2026-06-04

### Added
- Fleet dashboard across all hosts.

### Changed
- Keep the main window wide enough for all three columns.

### Fixed
- Container terminal on images without `bash`.

## [0.3.0] - 2026-06-04

### Added
- Host shell terminal and host file browser for SSH hosts.
- Icon-visibility settings and a richer menu bar panel.
- Test coverage expanded to 403 tests across all packages.

### Fixed
- Detail panel overflow.
- SSH host responsiveness; calmer logs; Files usability.

## [0.2.0] - 2026-06-04

### Added
- Host overview dashboard.
- Import hosts from `ssh_config` when adding a host.
- Host removal affordance and an app-managed key.

### Changed
- RSA keys now sign with `rsa-sha2-256` (RFC 8332).
- Render the container port badge verbatim.
- Review pass: wire resource removal, unify SSH resolution, dedupe helpers.

### Fixed
- `ssh_config` alias resolution.
- Stop surfacing cancellations as errors.

## [0.1.0] - 2026-06-04

Initial public release.

### Added
- Local Docker support: containers, images, volumes and networks.
- Live streaming for logs, stats and events.
- Remote Docker hosts over SSH.
- Container exec terminal.
- Full Docker coverage, a menu bar item, settings, App Intents and an MCP
  server.
- File drag-and-drop, log search, collapsible Compose groups and theme
  selection.
- Sparkle auto-updates.

[Unreleased]: https://github.com/getgantry/gantry/compare/v0.11.0...HEAD
[0.11.0]: https://github.com/getgantry/gantry/releases/tag/v0.11.0
[0.10.0]: https://github.com/getgantry/gantry/releases/tag/v0.10.0
[0.9.1]: https://github.com/getgantry/gantry/releases/tag/v0.9.1
[0.9.0]: https://github.com/getgantry/gantry/releases/tag/v0.9.0
[0.8.1]: https://github.com/getgantry/gantry/releases/tag/v0.8.1
[0.8.0]: https://github.com/getgantry/gantry/releases/tag/v0.8.0
[0.7.0]: https://github.com/getgantry/gantry/releases/tag/v0.7.0
[0.6.0]: https://github.com/getgantry/gantry/releases/tag/v0.6.0
[0.5.0]: https://github.com/getgantry/gantry/releases/tag/v0.5.0
[0.4.5]: https://github.com/getgantry/gantry/releases/tag/v0.4.5
[0.4.4]: https://github.com/getgantry/gantry/releases/tag/v0.4.4
[0.4.3]: https://github.com/getgantry/gantry/releases/tag/v0.4.3
[0.4.2]: https://github.com/getgantry/gantry/releases/tag/v0.4.2
[0.4.1]: https://github.com/getgantry/gantry/releases/tag/v0.4.1
[0.4.0]: https://github.com/getgantry/gantry/releases/tag/v0.4.0
[0.3.0]: https://github.com/getgantry/gantry/releases/tag/v0.3.0
[0.2.0]: https://github.com/getgantry/gantry/releases/tag/v0.2.0
[0.1.0]: https://github.com/getgantry/gantry/releases/tag/v0.1.0
