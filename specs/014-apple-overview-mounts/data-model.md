<!-- STE deviation: JSON keys stay verbatim. -->
# Data Model: Apple Container Mounts in Overview

## Mount (Docker-shaped, `MountPoint`)

| Field | From apple/container | Rule |
|-------|----------------------|------|
| `Type` | key of `type` (or a string `type`) | `virtiofs` → `bind`; `volume`, `tmpfs`, others unchanged |
| `Name` | `type.volume.name`, else `name` | only when not empty |
| `Source` | `source`, else `name` | unchanged |
| `Destination` | `destination`, else `target`, else `path` | unchanged |
| `RW` | `options` contains `ro`, or `readOnly`/`readonly` is true | `RW = !readOnly`, always set |

`displaySource`: `Name` when `Type` is `volume` and `Name` is not empty; else `Source` when
not empty; else `Name`; else "—" (the view's existing fallback).
