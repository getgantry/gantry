<!-- STE deviation: JSON keys and CLI output stay verbatim. -->
# Research: Apple Container Mounts in Overview

## R1. The 1.7.1 mount shape

Live capture on 2026-11-14 with `container run -v DIR:/ro:ro -v DIR2:/rw -v gaom-data:/data --tmpfs /scratch alpine:3.22`:

```json
{"destination":"/ro","options":["ro"],"source":"/…/bindro","type":{"virtiofs":{}}}
{"destination":"/rw","options":[],"source":"/…/bindrw","type":{"virtiofs":{}}}
{"destination":"/data","options":[],"source":"/…/volumes/gaom-data/volume.img",
 "type":{"volume":{"cache":{"on":{}},"format":"ext4","name":"gaom-data","sync":{"fsync":{}}}}}
{"destination":"/scratch","options":[],"source":"tmpfs","type":{"tmpfs":{}}}
```

- Decision: read-only comes from `options` containing `ro`; the volume name from
  `type.volume.name`; `virtiofs` maps to Docker `bind`.
- Rationale: this is the real output. PR #68 reads the same keys.
- Alternatives: keep the old `readOnly` key only. Rejected: 1.7.1 does not write it. The old
  keys stay as a fallback.

## R2. Source of a named volume

- Decision: keep `Source` as the `volume.img` path; add `Name`. Overview shows the name for
  volumes through `MountPoint.displaySource`.
- Rationale: Docker also writes the host mountpoint in `Source` and the name in `Name`.
  `DiskPresence.hostSources` uses host paths, and the `volume.img` path can be on an external
  data root (spec 004).
- Alternatives: put the name in `Source`. Rejected: it breaks the disk check and differs from
  Docker.

## R3. A read-only named volume

A second container with `-v gaom-data:/data:ro` failed to start while the first one used the
volume (`VZErrorDomain Code=2 "The storage device attachment is invalid."`). A block volume
cannot attach to two VMs. The parser treats a volume with `options: ["ro"]` the same as a bind,
so a test covers it with a fixture edited from R1.
