import SwiftUI
import AppCore
import DockerKit

/// Merged log feed for a whole Compose project: every service's output in one
/// stream, each line tagged with its colored service name (à la
/// `docker compose logs -f`). Reuses the same ANSI/level/search machinery as the
/// single-container view.
struct StackLogsView: View {
    let session: HostSession
    let project: String
    let containers: [ContainerSummary]

    @Environment(\.dismiss) private var dismiss

    private static let maxLines = 50_000

    @State private var lines: [StackLine] = []
    @State private var paused = false
    /// Lines that arrive while paused; Resume appends them.
    @State private var held = PauseBuffer<StackLine>(capacity: StackLogsView.maxLines)
    @State private var autoScroll = true
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var regexSearch = false
    @State private var minLevel: LogLevel?
    @State private var hiddenServices: Set<String> = []
    @State private var showTimestamps = false
    @State private var timeRange: LogTimeRange = .all
    @State private var exporting = false
    @State private var exportError: String?

    private struct StackLine: Identifiable, Sendable {
        var id: UInt64
        let service: String
        let timestamp: Date?
        let plain: String
        let level: LogLevel?
        let spans: [ANSISpan]

        var exportLine: LogExportLine {
            LogExportLine(text: plain, timestamp: timestamp, level: level, source: service)
        }
    }

    /// Distinct service names in stable (sorted) order, for the legend, the
    /// per-service toggle menu and color assignment.
    private var services: [String] {
        Array(Set(containers.map(serviceName))).sorted()
    }

    private func serviceName(_ container: ContainerSummary) -> String {
        container.composeService ?? container.displayName
    }

    private func color(for service: String) -> Color {
        guard let index = services.firstIndex(of: service) else { return .secondary }
        return LogRendering.servicePalette[index % LogRendering.servicePalette.count]
    }

    private var isSearching: Bool { !search.isEmpty }

    /// The stack view always narrows to matches; Copy Visible Lines and
    /// Export Logs use the same filter.
    private var filter: LogLineFilter {
        LogLineFilter(
            minLevel: minLevel,
            query: search,
            regex: regexSearch,
            matchesOnly: true,
            hiddenSources: hiddenServices,
            timeRange: hasTimestamps ? timeRange : .all
        )
    }

    private var visibleLines: [StackLine] {
        filter.apply(lines, now: .now) { $0.exportLine }
    }

    private var hasTimestamps: Bool { lines.contains { $0.timestamp != nil } }

    private var exportFormat: LogExportFormat {
        LogExportFormat(timestamps: showTimestamps && hasTimestamps, sources: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let exportError {
                Label(exportError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            content
        }
        .frame(minWidth: 760, idealWidth: 980, minHeight: 460, idealHeight: 640)
        .task(id: project) { await consumeAll() }
        .logExporter(isPresented: $exporting, item: exportItem, error: $exportError)
        .focusedSceneValue(\.logExportTarget, LogExportTarget(
            visibleCount: visibleLines.count,
            export: startExport,
            copy: copyVisible
        ))
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.tint)
                Text(project)
                    .font(.headline)
                Text("Stack logs · \(CountPhrases.services(services.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // Escape closes; Return stays with the search field.
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 8) {
                Toggle(isOn: $autoScroll) { Image(systemName: "arrow.down.to.line") }
                    .toggleStyle(.button)
                    .help("Follow output")
                    .accessibilityLabel("Follow output")
                Button { setPaused(!paused) } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                }
                .help(paused ? String(localized: "Resume") : String(localized: "Pause"))
                .accessibilityLabel(paused ? String(localized: "Resume") : String(localized: "Pause"))
                Button { lines.removeAll(); held.reset() } label: { Image(systemName: "trash") }
                    .help("Clear")
                    .accessibilityLabel("Clear")
                LogExportButtons(visibleCount: visibleLines.count, copy: copyVisible, export: startExport)

                levelMenu
                servicesMenu
                LogDisplayMenu(showTimestamps: $showTimestamps, timeRange: $timeRange, hasTimestamps: hasTimestamps)

                Text("\(visibleLines.count) lines")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                HeldLinesLabel(count: paused ? held.count : 0)

                Spacer()
                searchBar
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var levelMenu: some View {
        Menu {
            Button { minLevel = nil } label: {
                Label("All levels", systemImage: minLevel == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(LogLevel.allCases.sorted(by: >), id: \.self) { level in
                Button { minLevel = level } label: {
                    Label("\(level.displayName) and up", systemImage: minLevel == level ? "checkmark" : "")
                }
            }
        } label: {
            Image(systemName: minLevel == nil
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter by level")
        .accessibilityLabel("Filter by level")
    }

    private var servicesMenu: some View {
        Menu {
            ForEach(services, id: \.self) { service in
                Button {
                    if hiddenServices.contains(service) { hiddenServices.remove(service) }
                    else { hiddenServices.insert(service) }
                } label: {
                    Label(service, systemImage: hiddenServices.contains(service) ? "" : "checkmark")
                }
            }
        } label: {
            Image(systemName: "square.stack.3d.up.badge.a")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show / hide services")
        .accessibilityLabel("Show / hide services")
    }

    private var searchBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(regexSearch ? String(localized: "Regex") : String(localized: "Search"), text: $search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .findShortcut($searchFocused)
            Button { regexSearch.toggle() } label: {
                Text(verbatim: ".*")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(regexSearch ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Regular expression search")
            .accessibilityLabel("Regular expression search")
            .accessibilityValue(regexSearch ? String(localized: "on") : String(localized: "off"))
            if isSearching {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.quaternary, in: .rect(cornerRadius: 6))
        .frame(minWidth: 140, idealWidth: 240, maxWidth: 240)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if lines.isEmpty {
            ContentUnavailableView("No log output yet", systemImage: "text.alignleft")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleLines) { line in
                            row(for: line).id(line.id)
                        }
                        Color.clear.frame(height: 1).id(bottomAnchor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .onChange(of: lines.count) {
                    guard autoScroll, !isSearching else { return }
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private func row(for line: StackLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if exportFormat.timestamps, let timestamp = line.timestamp {
                Text(LogTimeLabel.text(timestamp))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(line.service)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color(for: line.service))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 104, alignment: .leading)
            Text(LogRendering.attributed(
                spans: line.spans,
                plain: line.plain,
                errorTint: line.level == .error || LogRendering.looksLikeError(line.plain),
                search: search,
                regex: regexSearch,
                strong: false
            ))
            .font(.system(size: 11.5, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private let bottomAnchor = "stacklogs.bottom"

    // MARK: - Streaming

    /// Fans out one log stream per service into a merged feed. Each pump only
    /// touches Sendable values and the stream continuation, so nothing crosses
    /// actor boundaries unsafely; line ids are assigned here in arrival order.
    /// Pause keeps the streams open and holds new lines; Resume shows them.
    private func setPaused(_ value: Bool) {
        paused = value
        if !value { append(held.drain()) }
    }

    private func append(_ newLines: [StackLine]) {
        lines.append(contentsOf: newLines)
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
        }
    }

    private func consumeAll() async {
        lines.removeAll()
        held.reset()
        let members = containers.map { ($0.id, serviceName($0)) }
        let session = self.session
        let (merged, continuation) = AsyncStream<StackLine>.makeStream()

        let producer = Task {
            await withTaskGroup(of: Void.self) { group in
                for (id, service) in members {
                    group.addTask {
                        await Self.pump(session: session, id: id, service: service, into: continuation)
                    }
                }
            }
            continuation.finish()
        }

        var nextID: UInt64 = 0
        for await line in merged {
            nextID += 1
            var stamped = line
            stamped.id = nextID
            if paused {
                held.hold(stamped)
            } else {
                append([stamped])
            }
        }
        producer.cancel()
    }

    private static func pump(
        session: HostSession,
        id: String,
        service: String,
        into continuation: AsyncStream<StackLine>.Continuation
    ) async {
        do {
            let stream = try await session.logStream(for: id)
            for try await entry in stream {
                let spans = ANSIParser.parse(entry.text)
                let plain = spans.map(\.text).joined()
                continuation.yield(StackLine(
                    id: 0,
                    service: service,
                    timestamp: entry.timestamp,
                    plain: plain,
                    level: LogLevel.detect(plain),
                    spans: spans
                ))
            }
        } catch {
            // A single service's stream failing must not tear down the others.
        }
    }

    private func copyVisible() {
        copyToPasteboard(exportFormat.text(visibleLines.map(\.exportLine)))
    }

    private func startExport() {
        exportError = nil
        exporting = true
    }

    /// Reads the visible lines when the save panel asks for the file.
    private var exportItem: LogExportItem {
        LogExportItem(
            fileName: LogExportFileName.make(base: project, date: .now),
            snapshot: { [self] in
                LogExportSnapshot(lines: visibleLines.map(\.exportLine), format: exportFormat)
            }
        )
    }
}
