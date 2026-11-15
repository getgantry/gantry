<!-- STE deviation: commands and paths stay verbatim. -->
# Quickstart: Validate Keychain Secrets

## Prerequisites

- Debug build at `/Volumes/SanDisk2Tb/builds/gantry/keychain-secrets/DerivedData`.
- apple/container running (`container system status`).

## Automatic checks

```sh
swift test --package-path Packages/DockerKit --scratch-path /Volumes/SanDisk2Tb/builds/gantry/keychain-secrets/DockerKit --filter SecretEnv
swift test --package-path Packages/AppCore --scratch-path /Volumes/SanDisk2Tb/builds/gantry/keychain-secrets/AppCore --filter "EnvSecrets|SecretsLibrary|ContainerRecipe|RunCommand"
python3 scripts/check-localization.py
```

Expected: all pass, 0 localization problems.

## Live check

1. Start the Debug build with `GANTRY_APP` set; open Settings ▸ Secrets (`scripts/gantry-ctl`), add `gks-token`.
2. New Container on the apple host: image `alpine:3.22`, name `gks-live`, command `sh -c 'echo len=${#GKS_TOKEN}; sleep 30'`, variable `GKS_TOKEN` → secret `gks-token`. Create and Run.
3. While it starts: `ps -axww -o args | grep 'container create'` shows `--env GKS_TOKEN` and no value.
4. `container logs gks-live` shows the right length. The inspector shows the variable as hidden.
5. Remove `gks-live` and the secret.
