import SwiftUI
import AppCore

/// `kubectl logs` of a pod container, with follow, tail and copy.
struct KubeLogsView: View {
    let pod: KubeResource
    let client: KubectlClient

    @State private var stream = KubeLogStream()
    @State private var container: String?
    @State private var follow = true
    @State private var previous = false
    @State private var tail = 500

    init(pod: KubeResource, client: KubectlClient) {
        self.pod = pod
        self.client = client
        _container = State(initialValue: pod.containers.first)
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            output
        }
        .task(id: "\(container ?? "")|\(follow)|\(previous)|\(tail)") { restart() }
        .onDisappear { stream.stop() }
    }

    private func restart() {
        stream.start(client, pod: pod, container: container ?? pod.containers.first, follow: follow, tail: tail, previous: previous)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if pod.containers.count > 1 {
                Picker("Container", selection: $container) {
                    ForEach(pod.containers, id: \.self) { Text(verbatim: $0).tag(Optional($0)) }
                }
                .frame(maxWidth: 220)
            }
            Picker("Lines", selection: $tail) {
                ForEach([100, 500, 2000], id: \.self) { Text(verbatim: String($0)).tag($0) }
            }
            .frame(maxWidth: 140)
            Toggle("Follow", isOn: $follow)
            Toggle("Previous Container", isOn: $previous)
                .help("Show the logs of the last run that stopped")
            Spacer()
            if stream.isRunning && follow {
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Button { copyToPasteboard(stream.text) } label: { Label("Copy Logs", systemImage: "doc.on.doc") }
                .labelStyle(.iconOnly)
                .help("Copy the logs to the clipboard")
            Button { stream.clear() } label: { Label("Clear", systemImage: "trash") }
                .labelStyle(.iconOnly)
                .help("Clear the shown lines")
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var output: some View {
        if let failure = stream.failure, stream.lines.isEmpty {
            ContentUnavailableView("No Logs", systemImage: "doc.text.magnifyingglass", description: Text(failure))
        } else if stream.lines.isEmpty {
            ContentUnavailableView(
                stream.isRunning ? "Waiting for Logs" : "No Logs",
                systemImage: "doc.text.magnifyingglass"
            )
        } else {
            KubeLogLines(lines: stream.lines, follow: follow)
        }
    }
}

/// The log lines; with follow on, the view stays at the newest line.
struct KubeLogLines: View {
    let lines: [String]
    let follow: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(verbatim: line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lines.count) { _, count in
                if follow, count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }
}

/// An interactive shell in a pod container (`kubectl exec -it`).
struct KubeTerminalView: View {
    let pod: KubeResource
    let client: KubectlClient
    @State private var container: String?

    init(pod: KubeResource, client: KubectlClient) {
        self.pod = pod
        self.client = client
        _container = State(initialValue: pod.containers.first)
    }

    var body: some View {
        VStack(spacing: 0) {
            if pod.containers.count > 1 {
                Picker("Container", selection: $container) {
                    ForEach(pod.containers, id: \.self) { Text(verbatim: $0).tag(Optional($0)) }
                }
                .frame(maxWidth: 260)
                .padding(8)
            }
            if pod.health == .ok || pod.status == "Running" {
                terminal
            } else {
                ContentUnavailableView(
                    "Pod Is Not Running",
                    systemImage: "pause.circle",
                    description: Text("A shell needs a running container.")
                )
            }
        }
    }

    private var terminal: some View {
        let target = container ?? pod.containers.first
        return TerminalPane(
            title: pod.name,
            subtitle: target ?? "shell",
            connectionID: "\(pod.id)#\(target ?? "")",
            connect: {
                MachineShellSession(
                    executable: client.executable,
                    args: client.execArguments(pod: pod, container: target),
                    extraEnvironment: client.environmentEntries
                )
            }
        )
    }
}

/// The keys of a Secret. A value shows only after Reveal.
struct KubeSecretDataView: View {
    let resource: KubeResource
    let client: KubectlClient

    @State private var entries: [KubeSecretEntry] = []
    @State private var revealed: Set<String> = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Cannot Load Secret", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView("No Keys", systemImage: "key")
            } else {
                List(entries) { entry in
                    KubeSecretRow(entry: entry, isRevealed: revealed.contains(entry.key)) {
                        if revealed.contains(entry.key) { revealed.remove(entry.key) } else { revealed.insert(entry.key) }
                    }
                }
            }
        }
        .task(id: resource.id) { await load() }
    }

    private func load() async {
        do {
            entries = try KubeSecretData.entries(fromJSON: try await client.json(for: resource))
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loaded = true
    }
}

struct KubeSecretRow: View {
    let entry: KubeSecretEntry
    let isRevealed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: entry.key)
                .font(.callout.weight(.medium))
                .frame(minWidth: 120, alignment: .leading)
            value
            Spacer()
            Button(isRevealed ? "Hide" : "Reveal", action: toggle)
                .help(isRevealed ? "Hide the value" : "Show the decoded value")
            Button { copyToPasteboard(entry.text ?? entry.encoded) } label: { Label("Copy Value", systemImage: "doc.on.doc") }
                .labelStyle(.iconOnly)
                .help("Copy the decoded value")
        }
    }

    @ViewBuilder
    private var value: some View {
        if !isRevealed {
            Text(verbatim: KubeSecretData.mask).foregroundStyle(.secondary)
                .accessibilityLabel(Text("Hidden"))
        } else if let text = entry.text {
            Text(verbatim: text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(6)
        } else {
            Text("Binary data, \(entry.byteCount) bytes").foregroundStyle(.secondary)
        }
    }
}
