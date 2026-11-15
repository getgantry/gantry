<!-- STE deviation: type and field names stay verbatim. -->
# Data Model: Keychain Secrets

## SecretInfo (AppCore)

| Field | Type | Rule |
|-------|------|------|
| name | String | 1–64 chars, `[A-Za-z0-9][A-Za-z0-9_.-]*`, unique |
| created | Date? | from Keychain `kSecAttrCreationDate` |
| modified | Date? | from Keychain `kSecAttrModificationDate` |

The value is never a field. It is read with `SecretStore.value(for:)` only during a create.

## ContainerRecipe.EnvVar (AppCore, changed)

| Field | Type | Rule |
|-------|------|------|
| key | String | as before |
| value | String | `""` when `secret` is set; encoded as `""` |
| secret | String? | NEW. The secret name; nil for a plain value. Optional in JSON, so old files load. |

## Container label (DockerKit `SecretEnvLabel`)

`com.gantry.secret-env` = `KEY:NAME` pairs joined with `,`, sorted by key. Keys are portable env names, names follow the SecretInfo rule, so `:` and `,` never occur in them.

## ContainerCreateRequest.AppleOptions (DockerKit, changed)

`secretEnvKeys: [String]` encoded as `SecretEnvKeys`. Read back from the label in `init(labels:)`.

## SecretError (AppCore)

`notFound(name)`, `invalidName(name)`, `duplicateName(name)`, `emptyValue`, `authenticationFailed`, `keychain(status)`, `invalidVariable(key)`, `reservedVariable(key)`. Each description holds names only.
