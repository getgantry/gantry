import SwiftUI
import AppKit
import AppCore
import DockerKit

struct LogsView: View {
    let session: HostSession
    let container: ContainerSummary

    /// Ring-buffer cap. Large enough to scroll real history, bounded so memory
    /// stays sane; `LazyVStack` only builds the rows actually on screen.
    private static let maxLines = 50_000

    @State private var lines: [DisplayLine] = []
    @State private var paused = false
    @State private var autoScroll = true
    @State private var search = ""
    @State private var regexSearch = false
    @State private var minLevel: LogLevel?
    @State private var streamError: String?

    /// When true, only lines matching the query are shown; otherwise every line
    /// is shown with matches highlighted in place.
    @State private var filterOnly = false

    /// Line ids (within the visible set) that match the current query, in order.
    @State private var matchLineIDs: [UInt64] = []
    /// Position within `matchLineIDs` of the currently focused match.
    @State private var currentMatch = 0

    @FocusState private var searchFocused: Bool

    /// One parsed, classified log line. ANSI parsing and level detection run
    /// once on ingest so rendering and filtering never re-parse.
    private struct DisplayLine: Identifiable {
        let id: UInt64
        let stream: LogStreamType
        let plain: String
        let level: LogLevel?
        let spans: [ANSISpan]
        var hasColor: Bool { spans.contains { $0.color != nil } }

        init(entry: LogEntry) {
            id = entry.id
            stream = entry.stream
            spans = ANSIParser.parse(entry.text)
            plain = spans.map(\.text).joined()
            level = LogLevel.detect(plain)
        }
    }

    /// Lines to render: all lines, narrowed by the level filter, and — in filter
    /// mode — to only those matching the query.
    private var visibleLines: [DisplayLine] {
        var result = lines
        if let minLevel {
            result = result.filter { ($0.level?.severity ?? -1) >= minLevel.severity }
        }
        if filterOnly, isSearching {
            result = result.filter { LogSearch.matches($0.plain, query: search, regex: regexSearch) }
        }
        return result
    }

    private var isSearching: Bool { !search.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            if let streamError {
                errorBanner(streamError)
                Divider()
            }
            content
        }
        .task(id: container.id) {
            await consume()
        }
        .onChange(of: search) { recomputeMatches() }
        .onChange(of: regexSearch) { recomputeMatches() }
        .onChange(of: minLevel) { recomputeMatches() }
        .onChange(of: lines.count) { recomputeMatches() }
        .background {
            // Invisible button gives Cmd+F a target that focuses the field.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $autoScroll) {
                Image(systemName: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .help("Follow output")

            Button {
                paused.toggle()
            } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
            }
            .help(paused ? "Resume" : "Pause")

            Button {
                lines.removeAll()
            } label: {
                Image(systemName: "trash")
            }
            .help("Clear")

            Button {
                copyAll()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy all")

            levelMenu

            Text("\(visibleLines.count) lines")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            searchBar
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var levelMenu: some View {
        Menu {
            Button {
                minLevel = nil
            } label: {
                Label("All levels", systemImage: minLevel == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(LogLevel.allCases.sorted(by: >), id: \.self) { level in
                Button {
                    minLevel = level
                } label: {
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
        .help(minLevel == nil ? "Filter by level" : "Showing \(minLevel!.displayName) and up")
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(regexSearch ? "Regex" : "Search", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { advance(by: 1) }

                Button {
                    regexSearch.toggle()
                } label: {
                    Text(".*")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(regexSearch ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(regexSearch ? "Regular expression search (on)" : "Regular expression search (off)")

                if isSearching {
                    Text(matchCounterText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()

                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.quaternary, in: .rect(cornerRadius: 6))
            .frame(minWidth: 130, idealWidth: 250, maxWidth: 250)

            Button { advance(by: -1) } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(matchLineIDs.isEmpty)
            .help("Previous match")

            Button { advance(by: 1) } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(matchLineIDs.isEmpty)
            .help("Next match")

            Toggle(isOn: $filterOnly) {
                Image(systemName: "line.3.horizontal.decrease")
            }
            .toggleStyle(.button)
            .help(filterOnly ? "Showing only matching lines" : "Showing all lines with highlights")
        }
    }

    private var matchCounterText: String {
        guard !matchLineIDs.isEmpty else { return "0 of 0" }
        return "\(currentMatch + 1) of \(matchLineIDs.count)"
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if lines.isEmpty {
            ContentUnavailableView(
                "No log output yet",
                systemImage: "text.alignleft"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleLines) { entry in
                            row(for: entry)
                                .id(entry.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .onChange(of: lines.count) {
                    guard autoScroll, !isSearching else { return }
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
                .onChange(of: autoScroll) {
                    guard autoScroll else { return }
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
                .onChange(of: currentMatch) {
                    scrollToCurrentMatch(proxy)
                }
            }
        }
    }

    /// Renders one log line: ANSI colors applied, search matches highlighted.
    /// The line holding the focused match gets a stronger highlight.
    @ViewBuilder
    private func row(for entry: DisplayLine) -> some View {
        Text(attributed(for: entry, strong: currentMatchLineID == entry.id))
            .font(.system(size: 11.5, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Builds the styled line via the shared renderer. stderr is deliberately
    /// NOT colored wholesale: many daemons route routine logging to stderr, so
    /// only lines that look like real errors get tinted.
    private func attributed(for line: DisplayLine, strong: Bool) -> AttributedString {
        LogRendering.attributed(
            spans: line.spans,
            plain: line.plain,
            errorTint: line.level == .error || LogRendering.looksLikeError(line.plain),
            search: search,
            regex: regexSearch,
            strong: strong
        )
    }

    /// The id of the line containing the currently focused match, or nil.
    private var currentMatchLineID: UInt64? {
        guard matchLineIDs.indices.contains(currentMatch) else { return nil }
        return matchLineIDs[currentMatch]
    }

    private let bottomAnchor = "logs.bottom"

    // MARK: - Search

    /// Recomputes the ordered list of matching visible lines and clamps the
    /// focused-match cursor. Runs once per query/regex/level/length change.
    private func recomputeMatches() {
        guard isSearching else {
            matchLineIDs = []
            currentMatch = 0
            return
        }
        matchLineIDs = visibleLines
            .filter { LogSearch.matches($0.plain, query: search, regex: regexSearch) }
            .map(\.id)
        if currentMatch >= matchLineIDs.count {
            currentMatch = max(0, matchLineIDs.count - 1)
        }
    }

    /// Advances the focused match by `delta`, wrapping around the match list.
    private func advance(by delta: Int) {
        guard !matchLineIDs.isEmpty else { return }
        let count = matchLineIDs.count
        currentMatch = ((currentMatch + delta) % count + count) % count
    }

    private func scrollToCurrentMatch(_ proxy: ScrollViewProxy) {
        guard let id = currentMatchLineID else { return }
        withAnimation(.snappy) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    // MARK: - Streaming

    private func consume() async {
        lines.removeAll()
        streamError = nil
        do {
            let stream = try await session.logStream(for: container.id)
            for try await entry in stream {
                if paused { continue }
                lines.append(DisplayLine(entry: entry))
                if lines.count > Self.maxLines {
                    lines.removeFirst(lines.count - Self.maxLines)
                }
            }
        } catch is CancellationError {
            // View went away; nothing to report.
        } catch {
            streamError = error.localizedDescription
        }
    }

    // MARK: - Actions

    private func copyAll() {
        copyToPasteboard(visibleLines.map(\.plain).joined(separator: "\n"))
    }
}
