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
    @State private var autoScroll = true
    @State private var search = ""
    @State private var regexSearch = false
    @State private var minLevel: LogLevel?
    @State private var hiddenServices: Set<String> = []

    private struct StackLine: Identifiable, Sendable {
        var id: UInt64
        let service: String
        let plain: String
        let level: LogLevel?
        let spans: [ANSISpan]
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

    private var visibleLines: [StackLine] {
        lines.filter { line in
            if hiddenServices.contains(line.service) { return false }
            if let minLevel, (line.level?.severity ?? -1) < minLevel.severity { return false }
            if isSearching, !LogSearch.matches(line.plain, query: search, regex: regexSearch) { return false }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 760, idealWidth: 980, minHeight: 460, idealHeight: 640)
        .task(id: project) { await consumeAll() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.tint)
                Text(project)
                    .font(.headline)
                Text("Stack logs · \(containers.count) services")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            HStack(spacing: 8) {
                Toggle(isOn: $autoScroll) { Image(systemName: "arrow.down.to.line") }
                    .toggleStyle(.button)
                    .help("Follow output")
                Button { paused.toggle() } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                }
                .help(paused ? "Resume" : "Pause")
                Button { lines.removeAll() } label: { Image(systemName: "trash") }
                    .help("Clear")
                Button { copyAll() } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy all")

                levelMenu
                servicesMenu

                Text("\(visibleLines.count) lines")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

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
    }

    private var searchBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(regexSearch ? "Regex" : "Search", text: $search)
                .textFieldStyle(.plain)
            Button { regexSearch.toggle() } label: {
                Text(".*")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(regexSearch ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Regular expression search")
            if isSearching {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
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
    private func consumeAll() async {
        lines.removeAll()
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
            if paused { continue }
            nextID += 1
            var stamped = line
            stamped.id = nextID
            lines.append(stamped)
            if lines.count > Self.maxLines {
                lines.removeFirst(lines.count - Self.maxLines)
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
                    plain: plain,
                    level: LogLevel.detect(plain),
                    spans: spans
                ))
            }
        } catch {
            // A single service's stream failing must not tear down the others.
        }
    }

    private func copyAll() {
        let text = visibleLines.map { "\($0.service)  \($0.plain)" }.joined(separator: "\n")
        copyToPasteboard(text)
    }
}
