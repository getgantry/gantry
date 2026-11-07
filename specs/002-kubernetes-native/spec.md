<!-- STE deviation: spec-kit template headings, the quoted user input, Given-When-Then scenarios, product names, Kubernetes terms and paths stay verbatim. -->
# Feature Specification: Native Kubernetes Client With No kubectl

**Feature Branch**: `feat/kubernetes-native`

**Created**: 2026-11-07

**Status**: In Progress (implementation started before spec-kit adoption on 2026-11-07)

**Input**: User description: "Replace kubectl with a native Kubernetes API client. A cluster made by `container cluster create` must be browsable and fully usable right after creation, with no other tool." Source brief: `/Volumes/SanDisk2Tb/builds/gantry-027/k8snative.md`.

## Context

The Kubernetes browser on main runs the `kubectl` program for every read and every action. A user who has only Apple's container tool must install kubectl first. The owner wants Gantry to need no kubectl at all. The product message is "the only GUI for Apple container clusters with zero dependencies".

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Browse a new cluster with no other tool (Priority: P1)

A user creates a cluster with the container tool. The user opens Kubernetes in Gantry and selects the context of the new cluster. Gantry shows the namespaces, nodes, pods, deployments, services and events. The lists update when the cluster changes. kubectl is not installed on the Mac.

**Why this priority**: This is the main promise of the feature. All other stories need the connection and the lists.

**Independent Test**: Remove kubectl from the search path. Open a context of a cluster of the container tool. Check that the lists show the same objects as the cluster has.

**Acceptance Scenarios**:

1. **Given** a Mac without kubectl and a cluster made by `container cluster create`, **When** the user opens Kubernetes, **Then** Gantry lists the contexts and shows the resources of the selected context.
2. **Given** a kubeconfig with a client certificate and key, a token, a token file, a user name and password, or an exec credential plugin, **When** the user selects that context, **Then** Gantry connects with those credentials.
3. **Given** the kubeconfig has a custom certificate authority, **When** Gantry connects, **Then** Gantry trusts only that authority for the cluster.
4. **Given** a pod starts or stops in the cluster, **When** the user looks at the pod list, **Then** the list shows the change in less than 5 seconds.
5. **Given** the connection to the cluster drops, **When** the cluster is available again, **Then** Gantry connects again and the lists continue.
6. **Given** kubectl is not installed, **When** the user opens Kubernetes, **Then** Gantry shows no "install kubectl" message.

---

### User Story 2 - Read logs and the YAML of a resource (Priority: P1)

A user selects a pod and reads its logs. The logs follow live, line by line. The user can select a container, the number of last lines, and the logs of the previous run. The user also opens the YAML of any resource. Gantry masks secret values in the YAML.

**Why this priority**: Logs and YAML are the most frequent reads after the lists.

**Independent Test**: Open the logs of a pod that writes a line each second. Open the YAML of a secret. Make sure that Gantry masks the values.

**Acceptance Scenarios**:

1. **Given** a running pod, **When** the user opens its logs with Follow on, **Then** new lines appear as the pod writes them.
2. **Given** a pod that restarted, **When** the user selects Previous, **Then** Gantry shows the logs of the previous container run.
3. **Given** a secret, **When** the user opens its YAML, **Then** the data values are masked.

---

### User Story 3 - Change resources (Priority: P2)

A user scales a deployment, restarts a rollout, deletes a resource, or applies a YAML file with several objects. Gantry shows the result for each object.

**Why this priority**: Changes make the browser fully usable, but reading comes first.

**Independent Test**: In a test namespace, apply a file with two objects. Scale the deployment. Restart it. Delete it.

**Acceptance Scenarios**:

1. **Given** a deployment, **When** the user scales it to 3, **Then** the deployment has 3 replicas.
2. **Given** a deployment, **When** the user selects Restart, **Then** the cluster replaces its pods.
3. **Given** a resource, **When** the user deletes it and confirms, **Then** the cluster removes it, and its dependents are removed in the background.
4. **Given** a YAML file with several objects, **When** the user applies it, **Then** Gantry shows a result line or an error for each object.
5. **Given** the file holds a kind that Gantry does not know, **When** the user applies it, **Then** Gantry finds the kind on the cluster and applies the object.

---

### User Story 4 - Open a shell in a pod (Priority: P2)

A user opens a shell in a container of a pod. The terminal works like the other terminals in Gantry. A change of the window size goes to the pod.

**Why this priority**: A shell is a frequent debugging step. It needs more work than the reads.

**Independent Test**: Open a shell in a pod. Type `echo ok`. Change the window size and run `stty size`.

**Acceptance Scenarios**:

1. **Given** a running pod, **When** the user opens a shell, **Then** a terminal opens and the commands run in the pod.
2. **Given** an open shell, **When** the user changes the window size, **Then** the pod gets the new size.
3. **Given** the command in the pod ends with an error, **When** the session ends, **Then** Gantry shows the error.

---

### User Story 5 - Forward a port (Priority: P3)

A user forwards a local port to a pod or to a service. Gantry opens the port on the Mac. For a service, Gantry selects a ready pod and the target port, as kubectl does.

**Why this priority**: Port forward is useful but less frequent than logs and shell.

**Independent Test**: Forward a port to a pod that serves HTTP. Open the local URL. Do the same for a service.

**Acceptance Scenarios**:

1. **Given** a pod with port 80, **When** the user forwards local port 8080 to it, **Then** a request to `http://127.0.0.1:8080` gets the answer of the pod.
2. **Given** a service, **When** the user forwards a port to it, **Then** Gantry uses a ready pod of the service and its target port.
3. **Given** two connections to the local port at the same time, **When** both send data, **Then** both get their own answers.

---

### Edge Cases

- `$KUBECONFIG` holds several files. The same context name is in two files.
- The kubeconfig uses a certificate file path or inline certificate data. The key is RSA or EC.
- The kubeconfig has `insecure-skip-tls-verify`.
- An exec credential plugin is missing, fails, or returns an expired token.
- A watch ends because its resource version is too old.
- The log stream ends while Follow is on.
- A YAML file has an empty document, or a document without `kind`.
- The cluster supports only the older exec protocol.
- A service has no ready pod, or its target port is a name.
- The kubeconfig uses `auth-provider`.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Gantry MUST read the contexts from `~/.kube/config`, from each file in `$KUBECONFIG`, and from the kubeconfig files that Gantry stores for clusters of the container tool.
- **FR-002**: Gantry MUST support these credentials: a client certificate and key (file or inline, RSA or EC), a token, a token file, a user name and password, and exec credential plugins.
- **FR-003**: Gantry MUST trust only the certificate authority of the kubeconfig for a cluster, or skip the check only when the kubeconfig asks for it.
- **FR-004**: Gantry MUST NOT write credentials to logs or to files.
- **FR-005**: Gantry MUST list and get namespaces, nodes, pods, deployments, services and events with no external tool.
- **FR-006**: Gantry MUST update the lists live where the cluster supports watches, reconnect after a break, and keep polling as a fallback.
- **FR-007**: Gantry MUST stream pod logs line by line, with container, last lines, follow and previous options.
- **FR-008**: Gantry MUST show the YAML of a resource and mask secret values.
- **FR-009**: Gantry MUST scale, restart a rollout, and delete with background propagation.
- **FR-010**: Gantry MUST apply a YAML file with several documents, one object at a time, and show a result or an error for each object.
- **FR-011**: Gantry MUST find the resource path of an unknown kind from the API discovery of the cluster.
- **FR-012**: Gantry MUST open a shell in a pod with standard input, output, error and window size, and use the existing terminal view.
- **FR-013**: Gantry MUST forward a local port on 127.0.0.1 to a pod, and to a service through a ready pod and its target port.
- **FR-014**: Gantry MUST NOT look for kubectl, show an "install kubectl" message, or offer to install kubectl.
- **FR-015**: If an operation is not possible without kubectl, the fallback MUST be hidden and documented.
- **FR-016**: Changes to views MUST be limited to the wiring, because a parallel design pass restyles the Kubernetes views.
- **FR-017**: All new user-facing text MUST be localizable.

### Key Entities

- **Kubeconfig**: clusters, users, contexts, the current context, and the files they came from.
- **Credential**: certificate and key, token, user name and password, or an exec plugin with its result and expiry.
- **Resource**: a Kubernetes object with kind, name, namespace and raw JSON.
- **Watch**: a live stream of changes for one kind, with its resource version.
- **Apply plan**: the documents of a YAML file, each with its resource path and its result.
- **Stream session**: a shell or a port forward, with its channels.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user can browse a new cluster of the container tool in less than 1 minute after creation, with no other tool installed.
- **SC-002**: All package tests pass with kubectl absent from the search path.
- **SC-003**: The live test against a real cluster lists nodes and pods, reads logs, runs `echo ok` in a pod, and forwards a port.
- **SC-004**: List changes appear in less than 5 seconds.
- **SC-005**: No credential value appears in any log line during the tests.

## Assumptions

- A real 1.7.1 cluster `gtest` with 2 nodes runs locally for live tests. A deployment `gantry-demo` runs in namespace `default`. Tests do not change them. Tests create their own objects only in namespace `gantry-test`.
- `proxy-url` support is optional.
- For `auth-provider`, Gantry shows a clear message that tells the user to use an exec plugin. Decision (maintainer, 2026-11-07): `auth-provider` was removed from Kubernetes in 1.26. Gantry does not support it and shows this message.
- Kubernetes contexts in the command palette (from the design pass) read the contexts from the native client.
- Translations into the other UI languages are done by the maintainer after the English text is final.
