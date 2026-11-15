<!-- STE deviation: spec-kit headings (Decision, Rationale, Alternatives), product names, CLI output and paths stay verbatim. -->
# Research: Build History

All results come from live runs on 2026-11-14. The fixtures are copies of this output.

## R1. Build history on apple/container 1.7.1

- Decision: Gantry records the builds that it starts.
- Rationale: `container builder --help` lists only `start`, `status`, `stop`, `delete`. `container build --help` has no history or record option. The builder shim exports images to `~/Library/Application Support/com.apple.container/builder/` but keeps no record of builds.
- Alternatives considered: read the BuildKit history API in the builder container through the vsock shim. The shim does not expose it, and it is not a supported interface.

## R2. Output of `container build --progress plain`

- Decision: parse BuildKit plain progress. A step is a vertex `#N <name>`. The state comes from `#N DONE <s>s`, `#N CACHED` or `#N ERROR: <message>`.
- Rationale: three fixtures (first build, all cached, failed `RUN`). One vertex can show two times (`#4 [internal] load build context`), so the parser merges lines by vertex number. Gantry gets the text in the HTTP body (success) or in the error message (failure, from stderr), so a failed build keeps its log.
- Found in the live test: `container build --file` resolves a relative path against the working directory of the process, not against the context. Gantry sent `--file Dockerfile`, so each Build Image sheet build on an Apple host failed with `file does not exist Dockerfile`. Gantry now sends the absolute path.
- Alternatives considered: `--progress rawjson` is not in the 1.7.1 help (only `auto|plain|tty`).

## R3. Docker builds from Gantry

- Decision: parse the classic `/build` stream: `Step i/n : <instruction>`, then ` ---> Using cache` (cached) or ` ---> Running in <id>` (run). An `error` line fails the current step.
- Rationale: Gantry sends `/build` without `version=2`, so Docker 28.5.2 uses the classic builder. The fixture (`daemon-builds.txt`) shows these lines and shows that these builds do not show in `docker buildx history ls`.
- Alternatives considered: change Gantry to BuildKit builds (`version=2`). That needs the BuildKit session protocol over the daemon connection. It is out of scope.

## R4. `docker buildx history`

- Decision: use `ls --format json --no-trunc`, `inspect --format json REF`, `logs REF`. Gate on `docker buildx version` 0.23.0 or later.
- Rationale: buildx 0.29.1 prints one JSON object per line with lowercase keys (`ref`, `name`, `status`, `created_at`, `completed_at`, `total_steps`, `completed_steps`, `cached_steps`). The docs show an array with other key names (`ID`, `CreatedAt`). The parser accepts both. `cached_steps` and `total_steps` count all vertices. The parser of R2 gives the same counts from `logs` (9 and 3 for the cached fixture). The JSON format of `inspect` came in buildx 0.21. We could not find the release of `ls --format json` in the release notes, so the gate is 0.23.0. A failed command gives a note with the error text.
- Alternatives considered: talk to BuildKit over gRPC directly. That is a large dependency for an optional feature.

## R5. Where to run `docker`

- Decision: local hosts run the local CLI with `DOCKER_HOST=unix://<socket>`. SSH hosts run the remote CLI over a new SSH exec channel. Apple hosts do not run it.
- Rationale: Gantry reaches SSH hosts with `docker system dial-stdio` on the remote machine, so a remote `docker` CLI is there. A local `docker -H ssh://` would need the system `ssh` and keys, and Gantry does not need them today.
- Alternatives considered: a local CLI with an SSH `DOCKER_HOST` for SSH hosts. It fails for hosts that use a password or a key in the Keychain.

## R6. Storage

- Decision: one JSON file, `build-history.json`, in `~/Library/Application Support/Gantry/`, mode 0600. At most 100 records per host. At most 512 KB of log per record: Gantry keeps the end and sets `logTruncated`. `GANTRY_BUILD_HISTORY_PATH` overrides the path (test seam, as `GANTRY_HOSTS_PATH`).
- Rationale: same pattern as `FolderVolumeStore` and `hosts.json`. 100 records of 512 KB is at most 50 MB per host. Most logs are a few KB.
- Alternatives considered: SwiftData or one file per record. More code for no user value.
