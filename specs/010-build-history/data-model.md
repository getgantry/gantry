<!-- STE deviation: type names, field names and enum cases stay verbatim. -->
# Data Model: Build History

## BuildStep (DockerKit)

| Field | Type | Note |
|---|---|---|
| number | Int | BuildKit vertex number, or classic step index |
| name | String | `[2/4] RUN echo one > /one`, `RUN echo one > /one` |
| state | BuildStepState | `run`, `cached`, `failed`, `unknown` |
| duration | Double? | seconds, from `#N DONE 0.1s` |
| isInternal | Bool | `[internal]`, `[resolver]`, `exporting …`, `oci-layout://…` |

`BuildStepSummary`: `total`, `cached`, `run`, `failed`. Counts include internal vertices, as buildx counts them.

## BuildxRecord (DockerKit)

`ref` (full, `default/default/<id>`), `id` (last part), `name`, `status` (text), `createdAt`, `completedAt`, `totalSteps`, `completedSteps`, `cachedSteps`.

## BuildxInspect (DockerKit)

`name`, `context`, `dockerfile`, `status`, `startedAt`, `completedAt`, `errorMessage`, `errorStep`.

## BuildRecord (AppCore)

| Field | Type | Note |
|---|---|---|
| id | String | UUID for Gantry records; buildx `ref` for BuildKit records |
| hostID | UUID | |
| source | BuildSource | `gantry`, `buildx` |
| name | String | tag for Gantry records; buildx name |
| dockerfile, contextPath, target | String? | |
| noCache | Bool | |
| buildArgNames | [String] | names only (FR-009) |
| status | BuildStatus | `running`, `succeeded`, `failed`, `cancelled`, `interrupted` |
| startedAt | Date | |
| endedAt | Date? | |
| imageID | String? | |
| errorMessage | String? | |
| log | String | at most 512 KB, the end |
| logTruncated | Bool | |
| steps | [BuildStep] | from the log |
| totalSteps, cachedSteps | Int? | from buildx `ls`; else from `steps` |

State transitions of a Gantry record:

```text
running -> succeeded | failed | cancelled
running -> interrupted   (Gantry started and found a running record)
```

buildx status text: `Running` -> running, `Completed` -> succeeded, `Error` and `failed` -> failed, `Canceled` -> cancelled. Other text -> failed with the text kept in `errorMessage` when no message exists.

## BuildxAvailability (AppCore)

`available(version)`, `notDockerHost`, `noDockerCLI`, `noBuildx`, `tooOld(version)`, `failed(message)`.
