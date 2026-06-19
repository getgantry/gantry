# Changelog

All notable changes to Gantry are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add new entries under **[Unreleased]** as you work; `scripts/release.sh` stamps
that section with the version and date when a release is cut.

## [Unreleased]

## [0.18.2] - 2026-06-19


### Added
- Cloudflare Tunnel sharing now works on apple/container hosts: the Share to the internet control appears in the container's Address section (apple/container exposes ports via the container IP rather than a published-ports list, so the Ports-section button never applied).

## [0.18.1] - 2026-06-19


### Fixed
- Sharing a port via Cloudflare Tunnel no longer fails with a 502 Bad Gateway: cloudflared is now pointed at 127.0.0.1 instead of localhost, which could resolve to IPv6 while the published port only listened on IPv4.

## [0.18.0] - 2026-06-19


### Added
- Share a container's published port to the internet over a Cloudflare Tunnel: a cloud button on each published port opens a sheet that installs `cloudflared` via Homebrew if needed, then starts a quick tunnel (no account, an ephemeral `*.trycloudflare.com` URL) or a named tunnel on your own hostname (after `cloudflared tunnel login`). The public URL appears under the port with open/copy/stop; SSH-host ports are forwarded locally first. Tunnels are torn down on disconnect.

## [0.17.2] - 2026-06-16


### Fixed
- Reclaim Space now shows the actually-reclaimable size/count per category instead of misleading disk-usage totals, and a slow build-cache prune no longer spins forever.
- Host overview disk usage no longer briefly shows the previous host's data when switching hosts.

## [0.17.1] - 2026-06-16


### Changed
- Compose project actions (Stack Logs, Start/Stop/Restart All) are now inline buttons on the group header instead of a dropdown menu.

## [0.17.0] - 2026-06-16


### Added
- Logs on steroids: regex or literal log search, a minimum-level filter (Error/Warn/Info/Debug/Trace), ANSI color rendering, and a much larger 50,000-line buffer.
- Merged Compose stack logs: a Stack Logs action on each Compose project shows every service's output in one feed, each line tagged with its colored service name, with per-service show/hide.
- Run Docker Compose on any host: Compose is no longer apple/container-only — bring a compose file up on local Docker or a remote SSH host too, with an inline YAML editor; the runner adapts per engine (restart policies and multi-network on Docker, remote bind-path warnings over SSH).
- Smart Cleanup: a Reclaim Space panel on the host overview that shows dangling images, stopped containers, unused volumes and build cache with sizes and prunes each — or all — reporting how much was freed.
- Touch ID for destructive actions: an optional Settings toggle that requires Touch ID (or your login password) before removing a container or deleting a host.
- Import Docker contexts: the Add Host sheet can now one-click import ssh:// hosts from `docker context ls`, alongside the existing ~/.ssh/config import.
- Terminal color themes: pick System, Solarized Dark, Dracula or Nord for the embedded shell in Settings.

## [0.16.0] - 2026-06-16


### Added
- Get a macOS notification the moment a container crashes, runs out of memory, or goes unhealthy on any host — click it to jump straight to the container. Manual stops and restarts stay quiet. Toggle it in Settings > General.

## [0.15.0] - 2026-06-15


### Added
- Private registry pulls now work everywhere — create, quick run and compose read your docker login credentials from ~/.docker/config.json, not just the Pull Image window.

## [0.14.5] - 2026-06-15


### Changed
- The menu bar icon is now a monochrome template that matches the rest of the macOS menu bar and adapts to light and dark menu bars.

## [0.14.4] - 2026-06-14


### Fixed
- **A "Docker Error" alert could pop up unprompted during background refreshes** (most often on Apple Container hosts). Automatic refreshes now fail quietly and keep the last good data; the error modal is only shown for actions you initiate.

## [0.14.3] - 2026-06-13


### Fixed
- **Detail panes no longer drift to the middle of the window on empty states.** Tabs that display a placeholder (Terminal on a stopped machine or container, Files in an error state, Inspect with no data) previously caused the entire detail view to shrink and float vertically, leaving a large gap above the header. The placeholders now fill their available space so the header stays pinned to the top.

## [0.14.2] - 2026-06-13


### Fixed
- **Container list could freeze on remote (SSH) hosts after a silent connection drop.** The live `/events` stream can go half-open over SSH with no error reported, leaving the container list, running/stopped state, and counts frozen — a manual Refresh also failed silently. Gantry now runs a periodic reconcile loop and reconnects automatically when the stream stalls.

## [0.14.1] - 2026-06-11


### Fixed
- **apple/container CLI could hang on verbose commands.** Control commands
  (service status, machine actions) drained the process's stdout and stderr one
  after the other, which could stall once the second stream filled its pipe
  buffer. Both streams are now read concurrently.

## [0.14.0] - 2026-06-10


### Added
- **Machine Terminal and Resources tabs.** The machine detail view now mirrors
  the Containers section's tabs — Overview, Resources, Terminal, and Inspect.
  The editable CPU/memory panel moved into its own Resources tab, and the new
  Terminal tab opens an interactive shell into the machine in-app (instead of
  only launching Terminal.app).

### Fixed
- **Inspect display.** Inspect JSON no longer floats in the middle of the pane
  when it is shorter than the viewport, and escaped forward slashes (`\/`) in
  machine inspect output are now shown as plain slashes.

## [0.13.0] - 2026-06-09


### Added
- **Machine detail view.** Selecting a machine now opens its details — facts, an
  Inspect tab, and an editable CPU/memory panel — consistent with the Containers
  section. Editing CPU or memory applies via `container machine set` and restarts
  a running machine so the change takes effect immediately.
- **Set CPU and memory when creating a machine,** via new steppers in the Create
  Machine sheet.

### Changed
- The menu-bar icon and the menu-bar panel header now use the Gantry app icon
  instead of a generic glyph.

## [0.12.0] - 2026-06-09


### Added
- The **menu-bar panel** now surfaces each running container's reachable address:
  open it straight in the browser, or tap to copy its `dns/ip:port`. The
  container's DNS name (apple/container) and address are also in the row's
  right-click menu, and clicking a container jumps to it in the main window.
- **DNS domain** assignment is now available in the full **New Container** sheet
  (previously only in Quick Run) for apple/container hosts, so a container can be
  launched on a local domain and resolve as `name.domain` across the Mac.
- **Automatic DNS names** (OrbStack-style): star a **default domain** in
  Settings → Apple (the first one you add becomes it) and new containers are
  assigned it automatically, with a unique, image-derived name. Gantry writes the
  default into apple/container's `config.toml` and offers a one-click services
  restart, so `name.domain` actually resolves from the Mac — no manual CLI steps.
- **Assign/Change DNS Name** action on a container's Address section: set or
  change the domain after creation. Since apple/container fixes the domain at
  create time, this recreates the container, preserving its image, command,
  environment, published ports, volume binds, restart policy and labels.

### Fixed
- The menu-bar panel's running-container list could collapse to nothing in the
  self-sizing popover (an unconstrained `ScrollView`); it now always renders.
- Port numbers in the menu bar were localized with a grouping separator (e.g.
  `5.002` for `5002`); they now render verbatim.
- "Open in browser" / the primary address for apple/container now uses the
  container's reachable IP rather than its DNS name, which only resolves once a
  default DNS domain is configured system-wide. The DNS name is still offered as
  a separate copy action.

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

[Unreleased]: https://github.com/getgantry/gantry/compare/v0.18.2...HEAD
[0.18.2]: https://github.com/getgantry/gantry/releases/tag/v0.18.2
[0.18.1]: https://github.com/getgantry/gantry/releases/tag/v0.18.1
[0.18.0]: https://github.com/getgantry/gantry/releases/tag/v0.18.0
[0.17.2]: https://github.com/getgantry/gantry/releases/tag/v0.17.2
[0.17.1]: https://github.com/getgantry/gantry/releases/tag/v0.17.1
[0.17.0]: https://github.com/getgantry/gantry/releases/tag/v0.17.0
[0.16.0]: https://github.com/getgantry/gantry/releases/tag/v0.16.0
[0.15.0]: https://github.com/getgantry/gantry/releases/tag/v0.15.0
[0.14.5]: https://github.com/getgantry/gantry/releases/tag/v0.14.5
[0.14.4]: https://github.com/getgantry/gantry/releases/tag/v0.14.4
[0.14.3]: https://github.com/getgantry/gantry/releases/tag/v0.14.3
[0.14.2]: https://github.com/getgantry/gantry/releases/tag/v0.14.2
[0.14.1]: https://github.com/getgantry/gantry/releases/tag/v0.14.1
[0.14.0]: https://github.com/getgantry/gantry/releases/tag/v0.14.0
[0.13.0]: https://github.com/getgantry/gantry/releases/tag/v0.13.0
[0.12.0]: https://github.com/getgantry/gantry/releases/tag/v0.12.0
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
