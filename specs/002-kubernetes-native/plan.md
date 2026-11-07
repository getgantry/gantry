<!-- STE deviation: spec-kit template headings, product names, Kubernetes protocol names and paths stay verbatim. -->
# Implementation Plan: Native Kubernetes Client With No kubectl

**Branch**: `feat/kubernetes-native` | **Date**: 2026-11-07 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/002-kubernetes-native/spec.md`

**Note**: The implementation started before this plan. The plan describes the approach of the brief.

## Summary <!-- slop: spec-kit template heading -->

Replace the `kubectl` process calls in AppCore with a native Kubernetes API client. A kubeconfig loader reads all files with Yams and resolves the credentials. Exec plugins are part of this. An HTTP client on AsyncHTTPClient and NIOSSL sends the requests. It uses PEM client certificates and the custom CA of the kubeconfig.

Fixed paths cover the core/v1, apps/v1, networking.k8s.io/v1 and events APIs. Watches replace the 5 s polling where that is simple. Logs stream line by line. Shell and port forward use WebSockets with the Kubernetes channel protocols.

The kubectl lookup, the install empty state and the Homebrew install operation are removed. The views get only the new wiring.

## Technical Context

**Language/Version**: Swift 6 (Swift tools 6.1), Xcode 27 SDK

**Primary Dependencies**: SwiftUI, AppCore, Yams, AsyncHTTPClient, NIOSSL, NIOWebSocket and NIOPosix from swift-nio (already resolved through DockerKit). Add explicit products to `Packages/AppCore/Package.swift`.

**Storage**: Read-only kubeconfig files. `ClusterKubeconfigStore` files for clusters of the container tool. No credential is persisted.

**Testing**: Swift Testing in `Packages/AppCore/Tests/AppCoreTests`. Fixtures are the existing JSON fixtures of `KubernetesTests.swift`. A live integration test runs only when `GANTRY_K8S_LIVE_CONTEXT` is set. All tests also run with `env PATH=/usr/bin:/bin`.

**Target Platform**: macOS 26 or later

**Project Type**: Desktop app (SwiftUI) with local Swift packages

**Performance Goals**: List changes visible in less than 5 s. Log lines appear as the pod writes them.

**Constraints**: No kubectl. No keychain for client certificates. Credentials never in logs. The live cluster `gtest` and the deployment `gantry-demo` stay as they are. Builds go to `/Volumes/SanDisk2Tb/builds/gantry-027/k8snative/`.

**Scale/Scope**: About 10 new AppCore files. Changes to 8 Kubernetes files. New wiring in 6 view files.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Check | Result |
|---|---|---|
| I. Native Mac App, HIG First | Views keep their layout. The shell uses the existing `TerminalPane`. The HIG pass does the restyle. | Pass |
| II. Logic in Packages, Thin Views, Tests | Kubeconfig parsing, request building, JSON parsing, apply planning, frame encoding and ExecCredential parsing are in AppCore with tests. Network and processes are behind protocols, so unit tests do not touch a cluster. | Pass |
| III. No Required Dependencies | The feature removes the kubectl dependency. A missing cluster shows a reason, not a broken host. | Pass |
| IV. Safety of User Data and Secrets | Delete uses `DestructiveAction`. Tokens, keys and passwords stay in memory only and are redacted from errors. Secret values in YAML stay masked. | Pass |
| V. Every String in Every Language | New strings in English in the String Catalogs. Removed kubectl strings leave the catalogs. The merge needs translations for all 28 languages and a green `scripts/check-localization.py`. | Pass with a condition: translations are still to do |

Post-design re-check: no change.

## Project Structure

### Documentation (this feature)

```text
specs/002-kubernetes-native/
├── spec.md
├── plan.md
└── tasks.md
```

### Source Code (repository root)

```text
Packages/AppCore/Package.swift                        # add AsyncHTTPClient, NIOSSL, NIOWebSocket products
Packages/AppCore/Sources/AppCore/Kubernetes/
├── KubeConfig.swift              # full kubeconfig model: clusters, users, contexts, merge of files
├── KubeCredentials.swift         # new: certificate, token, basic, ExecCredential plugin
├── KubeAPIClient.swift           # new: HTTP client, TLS setup, request building
├── KubeResourcePaths.swift       # new: fixed paths and discovery for unknown kinds
├── KubeWatch.swift               # new: watch stream with resource version and reconnect
├── KubeLogStream.swift           # new or moved from KubeProcesses.swift: streamed logs
├── KubeApply.swift               # new: multi-document plan and server-side apply
├── KubeChannelProtocol.swift     # new: v5 and v4 channel frames for exec and port forward
├── KubeExecSession.swift         # new: TerminalSession over WebSocket
├── KubePortForwarder.swift       # new: 127.0.0.1 listener and one WebSocket per connection
├── KubernetesBrowser.swift       # switch from KubectlClient to KubeAPIClient
├── KubeResource.swift
├── KubeResourceParser.swift
├── KubeSecretData.swift
├── KubeProcesses.swift           # kubectl processes removed
├── KubectlClient.swift           # removed
└── KubectlTooling.swift          # removed
Packages/AppCore/Sources/AppCore/TerminalSession.swift      # session protocol for the shell
Packages/AppCore/Tests/AppCoreTests/
├── KubernetesTests.swift
├── KubeConfigAuthTests.swift     # new
├── KubeAPIClientTests.swift      # new
├── KubeApplyTests.swift          # new
├── KubeChannelProtocolTests.swift # new
└── LiveKubernetesTests.swift     # new, gated on GANTRY_K8S_LIVE_CONTEXT
App/Views/Kubernetes/{KubernetesView,KubernetesBrowserView,KubePodViews,KubeResourceDetailView,KubeSheets}.swift   # wiring only
App/Views/Clusters/ClusterListView.swift      # remove kubectl hints
App/Views/ContentView.swift, App/GantryApp.swift   # remove kubectl lookup
App/Localizable.xcstrings, Packages/AppCore/Sources/AppCore/Resources/Localizable.xcstrings
```

**Structure Decision**: The client lives in the existing `Kubernetes` folder of AppCore. The views stay where they are.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| New direct dependency products of swift-nio and AsyncHTTPClient in AppCore | PEM client certificates and WebSocket channel protocols need NIO and NIOSSL | URLSession needs the keychain for client certificates. kubectl is the dependency that the feature removes. |
