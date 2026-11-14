<!-- STE deviation: JSON field names stay verbatim. -->
# Contract: MCP tool fleet_activity

Read-only. Input (all optional):

| Argument | Type | Default | Note |
|----------|------|---------|------|
| host_id | string (UUID) | all hosts | |
| sort | string | `cpu` | one of `host`, `name`, `image`, `cpu`, `memory`, `network`, `disk`, `uptime` |
| ascending | bool | false for metrics, true for text columns | |
| limit | int | 50 | clamped to 1...500 |

Output: JSON object.

```json
{
  "sampledSeconds": 1.0,
  "containers": [
    {
      "hostID": "…", "hostName": "Local", "containerID": "…", "name": "web",
      "image": "nginx:1.27", "cpuPercent": 3.2, "memoryBytes": 52428800,
      "networkInBytesPerSecond": 120.0, "networkOutBytesPerSecond": 80.0,
      "diskReadBytesPerSecond": 0.0, "diskWriteBytesPerSecond": 4096.0,
      "uptimeSeconds": 10800
    }
  ],
  "errors": [ { "hostID": "…", "hostName": "Remote", "error": "…" } ]
}
```

- `uptimeSeconds` is absent when the status has no duration.
- A container whose stats fail in one of the two samples has no metric fields.
- Errors: an unknown `host_id` or `sort` value gives a tool error.
