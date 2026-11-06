import SwiftUI
import AppCore

/// `container system logs`: the unified-log output of the apple/container
/// services (API server, runtime, network and plugin helpers), live with
/// `--follow`. Uses the same rendering and search as container logs.
struct AppleSystemLogsPane: View {
    let session: HostSession

    private static let maxLines = 20_000
    private static let periods = ["5m", "15m", "1h", "6h", "1d"]

    private struct Line: Identifiable {
        let id: Int
        let parsed: AppleSystemLogLine
        let level: LogLevel?
    }

    @State private var lines: [Line] = []
    @State private var nextID = 0
    @State private var period = "5m"
    @State private var follow = true
    @State private var paused = false
    /// Raw lines that arrive while paused; Resume appends them.
    @State private var held = PauseBuffer<String>(capacity: AppleSystemLogsPane.maxLines)
    @State private var autoScroll = true
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var minLevel: LogLevel?
    @State private var process: String?
    @State private var streamError: String?
    @State private var loading = false
    @State private var generation = 0

    private var visibleLines: [Line] {
        lines.filter { line in
            if let minLevel, (line.level?.severity ?? -1) < minLevel.severity { return false }
            if let process, line.parsed.process != process { return false }
            if !search.isEmpty, !LogSearch.matches(line.parsed.raw, query: search, regex: false) { return false }
            return true
        }
    }

    private var processes: [String] {
        Array(Set(lines.compactMap(\.parsed.process))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppleSystemPaneHeader(pane: .logs, badge: liveBadge) {
                EmptyView()
            }
            toolbar
            Divider()
            if let streamError {
                AppleSystemErrorBanner(message: streamError)
                    .padding(8)
                Divider()
            }
            content
        }
        .navigationTitle(AppleSystemPane.logs.title)
        .task(id: "\(period)|\(follow)|\(generation)") { await consume() }
    }

    /// "Live" only while new lines show; "Paused" while they are held.
    private var liveBadge: (text: String, tint: Color)? {
        guard follow else { return nil }
        return paused ? (String(localized: "Paused"), .orange) : (String(localized: "Live"), .green)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker(String(localized: "Period"), selection: $period) {
                ForEach(Self.periods, id: \.self) { value in
                    Text(periodLabel(value)).tag(value)
                }
            }
            .fixedSize()
            .help(String(localized: "Show logs from this period"))

            Toggle(isOn: $follow) {
                Label(String(localized: "Follow"), systemImage: "dot.radiowaves.left.and.right")
            }
            .toggleStyle(.button)
            .help(String(localized: "Keep showing new log lines"))

            Toggle(isOn: $autoScroll) {
                Image(systemName: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .help(String(localized: "Scroll to new lines"))
            .accessibilityLabel(String(localized: "Scroll to new lines"))

            Button {
                setPaused(!paused)
            } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
            }
            .help(paused ? String(localized: "Resume") : String(localized: "Pause"))
            .accessibilityLabel(paused ? String(localized: "Resume") : String(localized: "Pause"))

            HeldLinesLabel(count: paused ? held.count : 0)

            Button {
                generation += 1
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(String(localized: "Reload"))
            .accessibilityLabel(String(localized: "Reload"))

            Button {
                copyToPasteboard(visibleLines.map(\.parsed.raw).joined(separator: "\n"))
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help(String(localized: "Copy all"))
            .accessibilityLabel(String(localized: "Copy all"))

            Menu {
                Button(String(localized: "All levels")) { minLevel = nil }
                Divider()
                ForEach([LogLevel.error, .info, .debug], id: \.self) { level in
                    Button(level.displayName) { minLevel = level }
                }
            } label: {
                Image(systemName: minLevel == nil
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(String(localized: "Filter by level"))
            .accessibilityLabel(String(localized: "Filter by level"))

            Menu {
                Button(String(localized: "All services")) { process = nil }
                Divider()
                ForEach(processes, id: \.self) { name in
                    Button(name) { process = name }
                }
            } label: {
                Text(process ?? String(localized: "All services"))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if loading { ProgressView().controlSize(.small) }
            Text(String(localized: "\(visibleLines.count) lines"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(String(localized: "Search"), text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .findShortcut($searchFocused)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.quaternary, in: .rect(cornerRadius: 6))
            .frame(minWidth: 120, maxWidth: 220)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if lines.isEmpty {
            ContentUnavailableView(
                loading ? String(localized: "Loading logs…") : String(localized: "No log lines in this period"),
                systemImage: "text.alignleft"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleLines.isEmpty {
            noMatches
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleLines) { line in
                            row(line).id(line.id)
                        }
                        Color.clear.frame(height: 1).id(bottomAnchor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .onChange(of: lines.count) {
                    guard autoScroll, search.isEmpty else { return }
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
                .onChange(of: autoScroll) {
                    if autoScroll { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private var noMatches: some View {
        if search.isEmpty {
            ContentUnavailableView(
                String(localized: "No Matching Lines"),
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("No line matches the level and process filters.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView.search(text: search)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private let bottomAnchor = "system-logs.bottom"

    private func row(_ line: Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let timestamp = line.parsed.timestamp {
                Text(shortTime(timestamp))
                    .foregroundStyle(.secondary)
            }
            if let name = line.parsed.process {
                Text(name.replacingOccurrences(of: "container-", with: ""))
                    .foregroundStyle(.tint)
                    .frame(width: 120, alignment: .leading)
                    .lineLimit(1)
            }
            Text(LogRendering.attributed(
                spans: [ANSISpan(text: line.parsed.message)],
                plain: line.parsed.message,
                errorTint: line.level == .error,
                search: search,
                regex: false,
                strong: false
            ))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .textSelection(.enabled)
    }

    /// `2026-11-03 13:57:00.790179+0100` shown as `13:57:00.790`.
    private func shortTime(_ timestamp: String) -> String {
        let parts = timestamp.split(separator: " ")
        guard parts.count >= 2 else { return timestamp }
        return String(parts[1].prefix(12))
    }

    private func periodLabel(_ value: String) -> String {
        switch value {
        case "5m": String(localized: "Last 5 minutes")
        case "15m": String(localized: "Last 15 minutes")
        case "1h": String(localized: "Last hour")
        case "6h": String(localized: "Last 6 hours")
        case "1d": String(localized: "Last day")
        default: value
        }
    }

    private func append(_ raw: String) {
        let parsed = AppleSystemLogLine(raw: raw)
        guard !parsed.isHeader else { return }
        lines.append(Line(id: nextID, parsed: parsed, level: parsed.level))
        nextID += 1
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
    }

    /// Pause keeps the stream open and holds new lines; Resume shows them.
    private func setPaused(_ value: Bool) {
        paused = value
        if !value {
            for raw in held.drain() { append(raw) }
        }
    }

    private func consume() async {
        lines.removeAll()
        held.reset()
        streamError = nil
        loading = true
        defer { loading = false }
        let cli = session.appleCLIOverride
        do {
            if follow {
                let stream = try AppleContainerControl.followSystemLogs(last: period, cliOverride: cli)
                for try await raw in stream {
                    loading = false
                    if paused {
                        held.hold(raw)
                    } else {
                        append(raw)
                    }
                }
            } else {
                for raw in try await AppleContainerControl.systemLogs(last: period, cliOverride: cli) {
                    append(raw)
                }
            }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { streamError = error.localizedDescription }
        }
    }
}
