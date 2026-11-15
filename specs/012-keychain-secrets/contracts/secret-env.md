<!-- STE deviation: code, flags and JSON stay verbatim. -->
# Contract: Secret References

## Recipe JSON

```json
{"key": "POSTGRES_PASSWORD", "value": "", "secret": "db-password"}
```

## Command text (formatter and parser)

```text
docker run -e POSTGRES_PASSWORD=keychain:db-password postgres
```

## apple/container create

```text
argv: container create ... --env POSTGRES_PASSWORD ... postgres
env:  POSTGRES_PASSWORD=<value>      (child process only)
```

## Docker Engine API

`POST /containers/create` body: `"Env": ["POSTGRES_PASSWORD=<value>"]`, `"Labels": {"com.gantry.secret-env": "POSTGRES_PASSWORD:db-password"}`.

## MCP `inspect_container`

Every string `POSTGRES_PASSWORD=<anything>` in the inspect JSON becomes `POSTGRES_PASSWORD=[REDACTED]` when the label lists the key.
