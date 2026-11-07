---

description: "Task list for the native Kubernetes client"
---

<!-- STE deviation: spec-kit template headings, task format, product names, Kubernetes protocol names and paths stay verbatim. -->
# Tasks: Native Kubernetes Client With No kubectl

**Input**: Design documents from `/specs/002-kubernetes-native/`

**Prerequisites**: plan.md, spec.md

**Tests**: Required. Constitution principle II and the brief ask for unit tests for all logic and a gated live test.

**Organization**: Tasks are grouped by user story.

**Status note**: The implementation started before this list. All tasks are open, because nobody checked the code against this list yet. Tick a task only after you check its code on branch `feat/kubernetes-native`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: The user story of the task (US1 to US5)

## Phase 1: Setup (Shared Infrastructure)

- [ ] T001 Add the AsyncHTTPClient, NIOSSL, NIOWebSocket and NIOPosix products to the AppCore target in Packages/AppCore/Package.swift
- [ ] T002 [P] Write the live test script and the test manifest in /Volumes/SanDisk2Tb/builds/gantry-027/k8snative/ (namespace `gantry-test` only)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Kubeconfig, credentials and the HTTP client. All stories need them.

### Tests

- [ ] T003 [P] Kubeconfig tests for `~/.kube/config`, a `$KUBECONFIG` list, duplicate context names and ClusterKubeconfigStore files in Packages/AppCore/Tests/AppCoreTests/KubeConfigAuthTests.swift
- [ ] T004 [P] Credential tests for certificate file and data (RSA and EC), token, token file, basic, `insecure-skip-tls-verify` and custom CA in Packages/AppCore/Tests/AppCoreTests/KubeConfigAuthTests.swift
- [ ] T005 [P] ExecCredential tests (success, missing plugin, failure, expiry) in Packages/AppCore/Tests/AppCoreTests/KubeConfigAuthTests.swift
- [ ] T006 [P] Request building tests (paths, query, headers, no secret in descriptions) in Packages/AppCore/Tests/AppCoreTests/KubeAPIClientTests.swift

### Implementation

- [ ] T007 Extend the kubeconfig model (clusters, users, contexts, file merge) in Packages/AppCore/Sources/AppCore/Kubernetes/KubeConfig.swift
- [ ] T008 Implement credential resolution and the ExecCredential runner behind a process protocol in Packages/AppCore/Sources/AppCore/Kubernetes/KubeCredentials.swift
- [ ] T009 Implement the HTTP client with NIOSSL client certificates and kubeconfig CA trust in Packages/AppCore/Sources/AppCore/Kubernetes/KubeAPIClient.swift
- [ ] T010 Add the fixed resource paths for core/v1, apps/v1, networking.k8s.io/v1 and events in Packages/AppCore/Sources/AppCore/Kubernetes/KubeResourcePaths.swift
- [ ] T011 Redact tokens, keys and passwords from all errors and log lines in Packages/AppCore/Sources/AppCore/Kubernetes/KubeAPIClient.swift
- [ ] T012 Decide the behaviour for `auth-provider` and `proxy-url`, then implement it in Packages/AppCore/Sources/AppCore/Kubernetes/KubeCredentials.swift

**Checkpoint**: Gantry can connect to a cluster with every supported credential.

---

## Phase 3: User Story 1 - Browse a new cluster with no other tool (Priority: P1) (MVP)

**Goal**: Lists of all kinds through the native client, with live updates.

**Independent Test**: With `env PATH=/usr/bin:/bin`, open the `gtest` context and compare the lists with the cluster.

- [ ] T013 [P] [US1] List and get JSON tests with the existing fixtures in Packages/AppCore/Tests/AppCoreTests/KubernetesTests.swift
- [ ] T014 [P] [US1] Watch tests (event decoding, resource version, reconnect after "too old") in Packages/AppCore/Tests/AppCoreTests/KubeAPIClientTests.swift
- [ ] T015 [US1] Implement list, get and namespaces in Packages/AppCore/Sources/AppCore/Kubernetes/KubeAPIClient.swift
- [ ] T016 [US1] Implement the watch stream with polling fallback in Packages/AppCore/Sources/AppCore/Kubernetes/KubeWatch.swift
- [ ] T017 [US1] Switch the browser from `KubectlClient` to the native client in Packages/AppCore/Sources/AppCore/Kubernetes/KubernetesBrowser.swift
- [ ] T018 [US1] Remove Packages/AppCore/Sources/AppCore/Kubernetes/KubectlClient.swift and Packages/AppCore/Sources/AppCore/Kubernetes/KubectlTooling.swift
- [ ] T019 [US1] Remove the kubectl lookup, the "install kubectl" empty state and the brew install operation in App/Views/Kubernetes/KubernetesView.swift, App/Views/ContentView.swift, App/GantryApp.swift and App/Views/Clusters/ClusterListView.swift
- [ ] T020 [US1] Remove the kubectl strings from App/Localizable.xcstrings and Packages/AppCore/Sources/AppCore/Resources/Localizable.xcstrings

**Checkpoint**: The browser works with no kubectl.

---

## Phase 4: User Story 2 - Logs and YAML (Priority: P1)

**Goal**: Streamed logs and YAML with masked secrets.

- [ ] T021 [P] [US2] Log request and line splitting tests in Packages/AppCore/Tests/AppCoreTests/KubeAPIClientTests.swift
- [ ] T022 [P] [US2] YAML rendering tests with secret masking in Packages/AppCore/Tests/AppCoreTests/KubernetesTests.swift
- [ ] T023 [US2] Implement the log stream (follow, container, tailLines, previous) in Packages/AppCore/Sources/AppCore/Kubernetes/KubeLogStream.swift and remove the kubectl log process from Packages/AppCore/Sources/AppCore/Kubernetes/KubeProcesses.swift
- [ ] T024 [US2] Render YAML from JSON with Yams and keep the masking in Packages/AppCore/Sources/AppCore/Kubernetes/KubeSecretData.swift
- [ ] T025 [US2] Connect the log and YAML views in App/Views/Kubernetes/KubePodViews.swift and App/Views/Kubernetes/KubeResourceDetailView.swift (wiring only)

---

## Phase 5: User Story 3 - Change resources (Priority: P2)

**Goal**: Scale, restart, delete and apply.

- [ ] T026 [P] [US3] Tests for the scale patch, the restart patch and the delete request in Packages/AppCore/Tests/AppCoreTests/KubeAPIClientTests.swift
- [ ] T027 [P] [US3] Apply planning tests (several documents, empty document, missing kind, unknown kind through discovery) in Packages/AppCore/Tests/AppCoreTests/KubeApplyTests.swift
- [ ] T028 [US3] Implement scale (scale subresource), restart (`kubectl.kubernetes.io/restartedAt` annotation) and delete (`propagationPolicy=Background`) in Packages/AppCore/Sources/AppCore/Kubernetes/KubeAPIClient.swift
- [ ] T029 [US3] Implement discovery of unknown kinds in Packages/AppCore/Sources/AppCore/Kubernetes/KubeResourcePaths.swift
- [ ] T030 [US3] Implement server-side apply per object (`fieldManager=gantry`, `force=false`) in Packages/AppCore/Sources/AppCore/Kubernetes/KubeApply.swift
- [ ] T031 [US3] Show the result for each object in App/Views/Kubernetes/KubeSheets.swift (wiring only)

---

## Phase 6: User Story 4 - Shell in a pod (Priority: P2)

**Goal**: A terminal in a pod over the exec WebSocket.

- [ ] T032 [P] [US4] Channel frame encoding and decoding tests (stdin 0, stdout 1, stderr 2, error 3, resize 4, v5 and v4) in Packages/AppCore/Tests/AppCoreTests/KubeChannelProtocolTests.swift
- [ ] T033 [US4] Implement the channel frames in Packages/AppCore/Sources/AppCore/Kubernetes/KubeChannelProtocol.swift
- [ ] T034 [US4] Implement the exec session with `TerminalSession` in Packages/AppCore/Sources/AppCore/Kubernetes/KubeExecSession.swift
- [ ] T035 [US4] Connect the session to the existing terminal in App/Views/Kubernetes/KubePodViews.swift (wiring only)

---

## Phase 7: User Story 5 - Port forward (Priority: P3)

**Goal**: Local ports to pods and services.

- [ ] T036 [P] [US5] Port forward framing tests (data and error channel per port, port number prefix) in Packages/AppCore/Tests/AppCoreTests/KubeChannelProtocolTests.swift
- [ ] T037 [P] [US5] Service target resolution tests (ready pod, named target port, no ready pod) in Packages/AppCore/Tests/AppCoreTests/KubernetesTests.swift
- [ ] T038 [US5] Implement the 127.0.0.1 listener with one WebSocket per connection in Packages/AppCore/Sources/AppCore/Kubernetes/KubePortForwarder.swift
- [ ] T039 [US5] Implement service resolution and replace the kubectl port forward in Packages/AppCore/Sources/AppCore/Kubernetes/KubeProcesses.swift
- [ ] T040 [US5] Connect the forward sheet in App/Views/Kubernetes/KubeSheets.swift (wiring only)

---

## Phase 8: Polish & Cross-Cutting Concerns

- [ ] T041 Write the live test (list nodes and pods, read logs, exec `echo ok`, port forward) gated on `GANTRY_K8S_LIVE_CONTEXT` in Packages/AppCore/Tests/AppCoreTests/LiveKubernetesTests.swift
- [ ] T042 Run the live test against the context `gtest`. Put test objects only in namespace `gantry-test`. Delete them after the test.
- [ ] T043 Run all package tests with `env PATH=/usr/bin:/bin` and `--scratch-path /Volumes/SanDisk2Tb/builds/gantry-027/k8snative/<Package>`
- [ ] T044 Search the test logs for token, key and password values and make sure that none is there
- [ ] T045 [P] Document any hidden fallback that still needs kubectl in /Volumes/SanDisk2Tb/builds/gantry-027/k8snative/REPORT.md
- [ ] T046 [P] Write the list of new string keys to /Volumes/SanDisk2Tb/builds/gantry-027/k8snative/new-strings.txt
- [ ] T047 Translate the new strings into all supported UI languages and run scripts/check-localization.py
- [ ] T048 Build the Debug app with `-derivedDataPath /Volumes/SanDisk2Tb/builds/gantry-027/k8snative/DerivedData` and check the browser with scripts/gantry-ctl

---

## Dependencies & Execution Order

- Phase 1, then Phase 2. Phase 2 blocks all stories.
- US1 comes before US2 and US3, because they use the browser of US1.
- US4 and US5 share the channel protocol. T033 comes before T036 to T040.
- Phase 8 comes last. T047 blocks the merge (constitution principle V).

## Parallel Example: Phase 2

```bash
Task: "Kubeconfig tests in KubeConfigAuthTests.swift"
Task: "Request building tests in KubeAPIClientTests.swift"
```

## Implementation Strategy

1. MVP: Phases 1 and 2, then User Story 1. Validate with kubectl absent.
2. Add User Story 2, then User Story 3.
3. Add User Stories 4 and 5 together, because they share the channel protocol.
4. Phase 8.
