<!-- STE deviation: CLI commands and output stay verbatim. -->
# Contract: commands that Gantry runs

All commands are read-only. Gantry never runs `history rm`, `export`, `import` or `open`.

| Command | When | Output that Gantry reads |
|---|---|---|
| `docker buildx version` | open Builds on a Docker host (cached per session) | `github.com/docker/buildx v0.29.1 <commit>` |
| `docker buildx history ls --format json --no-trunc` | open and refresh | one JSON object per line, or a JSON array |
| `docker buildx history inspect --format json <id>` | select a record | one JSON object |
| `docker buildx history logs <id>` | select a record | BuildKit plain progress on stderr (buildx 0.29.1 and 0.35.0) |

`<id>` is the last part of `ref`. Gantry accepts only `[A-Za-z0-9]` in it before it puts it in a command.

Environment: the local CLI gets `DOCKER_HOST=unix://<socket>` for the host. The SSH command is `docker buildx …` in the login shell of the remote user.

Exit status not 0: the stderr text becomes `BuildxAvailability.failed(message)` (for `ls`) or a note in the detail (for `inspect` and `logs`).
