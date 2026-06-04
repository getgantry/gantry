# Gantry

A native macOS app for managing and monitoring Docker — local and remote over SSH.

Free, open source, no tiers, no limits.

## Features (in progress)

- Containers, images, volumes, networks — list, inspect, manage
- Live logs and resource stats with charts
- Remote Docker hosts over SSH (key and password auth)
- Exec terminal into containers
- Menu bar quick actions
- Agent-friendly: App Intents (Shortcuts/Siri/Spotlight) and a built-in MCP server

## Requirements

- macOS 26 (Tahoe) or later
- Xcode 26+ to build from source

## Building

```sh
git clone https://github.com/andrewkomkov/gantry.git
cd gantry
open Gantry.xcodeproj
```

Build and run the `Gantry` scheme. No additional setup required.

## Architecture

- `App/` — SwiftUI app target
- `Packages/DockerKit` — Docker Engine API client (unix socket via async-http-client, SSH via `docker system dial-stdio`)
- `Packages/SSHKit` — SSH connections on top of Citadel (swift-nio-ssh)
- `Packages/AppCore` — models, stores, persistence, Keychain

## License

MIT
